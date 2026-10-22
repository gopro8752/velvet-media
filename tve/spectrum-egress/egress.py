#!/usr/bin/env python3
"""Private, authenticated Spectrum control-plane egress through one WireGuard peer."""
import argparse
import base64
import binascii
import hashlib
import hmac
import ipaddress
import json
import os
import queue
import re
import select
import signal
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
from pathlib import Path

HOSTS = frozenset({"apis.spectrum.net", "apis-vid.spectrum.net", "apis-drm.spectrum.net", "pi-lite.spectrum.net"})
HEADER_LIMIT = 8192
HEADER_SECONDS = 5
CONNECT_SECONDS = 8
IDLE_SECONDS = 45
TUNNEL_SECONDS = 120
ACTIVE_LIMIT = 32
BUFFER_LIMIT = 256 * 1024
INTERFACE = "wg0"
DNS_LIMIT = 8
DNS_SLOTS = threading.BoundedSemaphore(DNS_LIMIT)


class ConfigError(ValueError):
    pass


def valid_key(value):
    try:
        return len(base64.b64decode(value, validate=True)) == 32
    except (ValueError, binascii.Error):
        return False


def parse_profile(text):
    if len(text.encode()) > 32768 or "\0" in text:
        raise ConfigError("Invalid WireGuard profile")
    sections = []
    current = None
    allowed = {
        "Interface": {"PrivateKey", "Address", "DNS", "MTU", "ListenPort"},
        "Peer": {"PublicKey", "PresharedKey", "AllowedIPs", "Endpoint", "PersistentKeepalive"},
    }
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line in ("[Interface]", "[Peer]"):
            current = (line[1:-1], {})
            sections.append(current)
            continue
        if current is None or "=" not in line:
            raise ConfigError("Invalid WireGuard profile")
        key, value = (part.strip() for part in line.split("=", 1))
        if key not in allowed[current[0]] or key in current[1] or not value or any(ord(c) < 32 for c in value):
            raise ConfigError("Unsupported WireGuard profile setting")
        current[1][key] = value
    if [name for name, _ in sections] != ["Interface", "Peer"]:
        raise ConfigError("Exactly one interface and peer are required")
    interface, peer = sections[0][1], sections[1][1]
    if not valid_key(interface.get("PrivateKey", "")) or not valid_key(peer.get("PublicKey", "")):
        raise ConfigError("Invalid WireGuard key")
    if "PresharedKey" in peer and not valid_key(peer["PresharedKey"]):
        raise ConfigError("Invalid WireGuard key")
    try:
        addresses = [ipaddress.ip_interface(v.strip()) for v in interface["Address"].split(",")]
        networks = [ipaddress.ip_network(v.strip(), strict=True) for v in peer["AllowedIPs"].split(",")]
        mtu = int(interface.get("MTU", "1420"))
        keepalive = int(peer.get("PersistentKeepalive", "25"))
        if keepalive == 0:
            keepalive = 25
        listen = int(interface.get("ListenPort", "0"))
        if not any(v.version == 4 for v in addresses) or ipaddress.ip_network("0.0.0.0/0") not in networks:
            raise ValueError()
        if not 1280 <= mtu <= 9000 or not 1 <= keepalive <= 60 or not 0 <= listen <= 65535:
            raise ValueError()
        if "DNS" in interface:
            for dns in interface["DNS"].split(","):
                ipaddress.ip_address(dns.strip())
        host, port = peer["Endpoint"].rsplit(":", 1)
        if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?", host) or not 1 <= int(port) <= 65535:
            raise ValueError()
    except (KeyError, ValueError):
        raise ConfigError("Invalid WireGuard network settings") from None
    return {"interface": interface, "peer": peer, "addresses": addresses, "mtu": mtu,
            "keepalive": keepalive, "endpoint": (host, int(port)), "listen": listen}


def parse_auth(value):
    if not isinstance(value, dict):
        raise ConfigError("Proxy credentials are required")
    if set(value) == {"username", "password"}:
        username, password = value["username"], value["password"]
        if not all(isinstance(v, str) and 1 <= len(v.encode()) <= 1024 and not any(ord(c) < 32 or ord(c) == 127 for c in v) for v in (username, password)) or ":" in username:
            raise ConfigError("Invalid proxy credentials")
        token = base64.b64encode(f"{username}:{password}".encode()).decode()
    elif set(value) == {"basicToken"} and isinstance(value["basicToken"], str):
        token = value["basicToken"]
        try:
            decoded = base64.b64decode(token, validate=True).decode()
            username, password = decoded.split(":", 1)
            if base64.b64encode(decoded.encode()).decode() != token:
                raise ValueError()
            return parse_auth({"username": username, "password": password})
        except (ValueError, UnicodeError, binascii.Error):
            raise ConfigError("Invalid proxy credentials") from None
    else:
        raise ConfigError("Invalid proxy credentials")
    return ("Basic " + token).encode("ascii")


def load_config(directory):
    directory = Path(directory)
    for name, limit in (("wg.conf", 32768), ("proxy.json", 8192)):
        path = directory / name
        if not path.is_file() or path.stat().st_size > limit:
            raise ConfigError("Private runtime configuration is missing or too large")
    try:
        profile = parse_profile((directory / "wg.conf").read_text())
        credentials = parse_auth(json.loads((directory / "proxy.json").read_text()))
        return profile, credentials
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise ConfigError("Invalid private runtime configuration") from None


def command(args):
    # Commands contain no keys; wg setconf reads them from a private tmpfs file.
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)


def resolve_ipv4(host, port, kind, deadline):
    """Bound caller latency and abandoned resolver threads without a task queue."""
    if deadline <= time.monotonic() or not DNS_SLOTS.acquire(blocking=False):
        raise OSError("DNS resolution unavailable")
    completed = queue.Queue(maxsize=1)
    resolver, slots = socket.getaddrinfo, DNS_SLOTS

    def resolve():
        try:
            result = resolver(host, port, socket.AF_INET, kind)
            completed.put_nowait(result)
        except Exception:
            completed.put_nowait(None)
        finally:
            # A timed-out caller cannot free this slot while libc is still
            # blocked. At most DNS_LIMIT daemon workers can remain abandoned.
            slots.release()

    try:
        threading.Thread(target=resolve, name="spectrum-dns", daemon=True).start()
    except RuntimeError:
        slots.release()
        raise OSError("DNS resolution unavailable") from None
    try:
        result = completed.get(timeout=max(0, deadline - time.monotonic()))
    except queue.Empty:
        raise OSError("DNS resolution unavailable") from None
    if not result or time.monotonic() >= deadline:
        raise OSError("DNS resolution unavailable")
    return result


def configure_wireguard(profile):
    address = resolve_ipv4(profile["endpoint"][0], profile["endpoint"][1], socket.SOCK_DGRAM, time.monotonic() + CONNECT_SECONDS)[0][4][0]
    interface, peer = profile["interface"], profile["peer"]
    lines = ["[Interface]", "PrivateKey = " + interface["PrivateKey"]]
    if profile["listen"]:
        lines.append("ListenPort = " + str(profile["listen"]))
    lines += ["[Peer]", "PublicKey = " + peer["PublicKey"], "AllowedIPs = " + peer["AllowedIPs"],
              f"Endpoint = {address}:{profile['endpoint'][1]}", "PersistentKeepalive = " + str(profile["keepalive"])]
    if "PresharedKey" in peer:
        lines.append("PresharedKey = " + peer["PresharedKey"])
    command(["ip", "link", "add", "dev", INTERFACE, "type", "wireguard"])
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir="/run", prefix="spectrum-wg-", encoding="ascii") as handle:
            os.chmod(handle.name, 0o600)
            handle.write("\n".join(lines) + "\n")
            handle.flush()
            command(["wg", "setconf", INTERFACE, handle.name])
        for address in profile["addresses"]:
            if address.version == 4:
                command(["ip", "address", "add", str(address), "dev", INTERFACE])
        command(["ip", "link", "set", "dev", INTERFACE, "mtu", str(profile["mtu"]), "up"])
        command(["ip", "route", "add", "default", "dev", INTERFACE, "table", "51820"])
        command(["ip", "rule", "add", "priority", "10000", "oif", INTERFACE, "lookup", "51820"])
        # This terminal rule prevents any later lookup from reaching eth0 if the
        # WireGuard route disappears while wg0 remains present.
        command(["ip", "rule", "add", "priority", "10001", "oif", INTERFACE, "prohibit"])
    except Exception:
        try:
            command(["ip", "link", "delete", "dev", INTERFACE])
        except Exception:
            pass
        raise


def routing_ready():
    try:
        result = subprocess.run(["ip", "-j", "route", "show", "table", "51820"], check=True,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=1)
        if len(result.stdout) > 32768:
            return False
        routes = json.loads(result.stdout)
        if not isinstance(routes, list) or any(not isinstance(route, dict) for route in routes):
            return False
        defaults = [route for route in routes if route.get("dst") in ("default", "0.0.0.0/0")]
        return (len(defaults) == 1 and defaults[0].get("dev") == INTERFACE
                and defaults[0].get("type", "unicast") == "unicast"
                and not any(key in defaults[0] for key in ("gateway", "via", "multipath", "nexthops"))
                and "linkdown" not in defaults[0].get("flags", []))
    except Exception:
        return False


def healthy(now=time.time):
    if not routing_ready():
        return False
    try:
        subprocess.run(["ip", "link", "show", "dev", INTERFACE], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
        result = subprocess.run(["wg", "show", INTERFACE, "latest-handshakes"], check=True, capture_output=True, text=True, timeout=2)
        stamps = [int(line.split()[1]) for line in result.stdout.splitlines() if len(line.split()) == 2]
        return len(stamps) == 1 and 0 <= now() - stamps[0] <= 180 and stamps[0] != 0
    except Exception:
        return False


def supervise(stop, check=healthy, now=time.monotonic, fail=None):
    last_healthy, connected = now(), False
    while not stop.wait(30):
        if check():
            last_healthy, connected = now(), True
        elif now() - last_healthy > (240 if connected else 180):
            # Exit lets the container restart policy re-resolve the configured
            # endpoint after WAN-address changes. Traffic never bypasses wg0.
            print('{"event":"control_egress_handshake_expired"}', flush=True)
            (fail or (lambda: os._exit(1)))()
            return


def parse_request(data, expected_auth):
    if len(data) > HEADER_LIMIT or not data.endswith(b"\r\n\r\n"):
        return 400, None
    try:
        lines = data[:-4].decode("ascii").split("\r\n")
        method, authority, version = lines[0].split(" ")
        if method != "CONNECT" or version not in ("HTTP/1.0", "HTTP/1.1"):
            return 405, None
        headers = {}
        for line in lines[1:]:
            key, value = line.split(":", 1)
            if not re.fullmatch(r"[A-Za-z0-9-]+", key) or key.lower() in headers or any(ord(c) < 32 and c != "\t" for c in value):
                return 400, None
            headers[key.lower()] = value.strip()
        supplied = headers.get("proxy-authorization", "").encode("ascii")
        if not hmac.compare_digest(hashlib.sha256(supplied).digest(), hashlib.sha256(expected_auth).digest()):
            return 407, None
        if authority.count(":") != 1:
            return 403, None
        host, port = authority.split(":")
        if host.lower() not in HOSTS or port != "443":
            return 403, None
        if headers.get("content-length", "0") != "0" or "transfer-encoding" in headers:
            return 400, None
        return 200, host.lower()
    except (ValueError, UnicodeError):
        return 400, None


def read_headers(client, now=time.monotonic):
    deadline, data = now() + HEADER_SECONDS, bytearray()
    while True:
        remaining = deadline - now()
        if remaining <= 0 or len(data) >= HEADER_LIMIT:
            raise ValueError("Invalid request")
        client.settimeout(remaining)
        part = client.recv(min(1024, HEADER_LIMIT - len(data)))
        if not part:
            raise ValueError("Invalid request")
        data.extend(part)
        if b"\r\n\r\n" in data:
            if not data.endswith(b"\r\n\r\n"):
                raise ValueError("Invalid request")
            return bytes(data)


def connect_upstream(host):
    if host not in HOSTS:
        raise OSError("Destination denied")
    deadline = time.monotonic() + CONNECT_SECONDS
    if not routing_ready():
        raise OSError("Control egress unavailable")
    for result in resolve_ipv4(host, 443, socket.SOCK_STREAM, deadline):
        address = result[4]
        # DNS resolves public hostnames normally, but a private/loopback answer
        # must not turn this allowlist into an internal-network proxy.
        if not ipaddress.ip_address(address[0]).is_global:
            continue
        upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError()
            upstream.settimeout(remaining)
            upstream.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, INTERFACE.encode() + b"\0")
            upstream.connect(address)
            return upstream
        except OSError:
            upstream.close()
    raise OSError("Control egress unavailable")


def relay(client, upstream, now=time.monotonic):
    sockets = (client, upstream)
    buffers = {client: bytearray(), upstream: bytearray()}
    reading = set(sockets)
    shut = set()
    started = active = now()
    for sock in sockets:
        sock.setblocking(False)
    while reading or any(buffers.values()):
        stamp = now()
        remaining = min(IDLE_SECONDS - (stamp - active), TUNNEL_SECONDS - (stamp - started))
        if remaining <= 0:
            return
        for source, destination in ((client, upstream), (upstream, client)):
            if source not in reading and not buffers[destination] and destination not in shut:
                try:
                    destination.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                shut.add(destination)
        reads = [source for source, destination in ((client, upstream), (upstream, client)) if source in reading and len(buffers[destination]) < BUFFER_LIMIT]
        writes = [sock for sock in sockets if buffers[sock]]
        ready_read, ready_write, _ = select.select(reads, writes, [], remaining)
        for sock in ready_write:
            try:
                sent = sock.send(buffers[sock])
                if not sent:
                    return
                del buffers[sock][:sent]
                active = now()
            except BlockingIOError:
                pass
        for source in ready_read:
            destination = upstream if source is client else client
            try:
                data = source.recv(min(65536, BUFFER_LIMIT - len(buffers[destination])))
                if data:
                    buffers[destination].extend(data)
                    active = now()
                else:
                    reading.discard(source)
            except BlockingIOError:
                pass


def reply(client, status):
    names = {200: "Connection Established", 400: "Bad Request", 403: "Forbidden", 405: "Method Not Allowed", 407: "Proxy Authentication Required", 502: "Bad Gateway", 503: "Service Unavailable"}
    auth = 'Proxy-Authenticate: Basic realm="Velvet Spectrum"\r\n' if status == 407 else ""
    client.settimeout(1)
    client.sendall(f"HTTP/1.1 {status} {names[status]}\r\n{auth}Content-Length: 0\r\n\r\n".encode())


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        upstream = None
        established = False
        try:
            status, host = parse_request(read_headers(self.request), self.server.credentials)
            if status != 200:
                reply(self.request, status)
                return
            upstream = self.server.connector(host)
            reply(self.request, 200)
            established = True
            relay(self.request, upstream)
        except (OSError, ValueError):
            if not established:
                try:
                    reply(self.request, 502)
                except OSError:
                    pass
        finally:
            if upstream is not None:
                upstream.close()


class ProxyServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = ACTIVE_LIMIT

    def __init__(self, address, credentials, connector=connect_upstream):
        self.credentials = credentials
        self.connector = connector
        self.slots = threading.BoundedSemaphore(ACTIVE_LIMIT)
        super().__init__(address, Handler)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                reply(request, 503)
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        # Do not log exceptions, network addresses, headers, or payloads.
        print('{"event":"control_request_failed"}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-dir", default="/config")
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--health", action="store_true")
    args = parser.parse_args()
    if args.health:
        return 0 if healthy() else 1
    try:
        profile, credentials = load_config(args.config_dir)
        if args.validate:
            print('{"valid":true}')
            return 0
        configure_wireguard(profile)
        with ProxyServer(("0.0.0.0", 8888), credentials) as server:
            stopping = threading.Event()
            threading.Thread(target=supervise, args=(stopping,), daemon=True).start()
            def stop(*_):
                raise KeyboardInterrupt()
            signal.signal(signal.SIGTERM, stop)
            print('{"event":"control_egress_ready"}', flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
            finally:
                stopping.set()
        return 0
    except Exception:
        print('{"event":"control_egress_startup_failed"}', flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
