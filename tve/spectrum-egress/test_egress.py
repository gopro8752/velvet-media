import base64
import importlib.util
import io
import json
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location("egress", Path(__file__).with_name("egress.py"))
egress = importlib.util.module_from_spec(spec)
spec.loader.exec_module(egress)
KEY = base64.b64encode(bytes(range(32))).decode()
PROFILE = f"""[Interface]
PrivateKey = {KEY}
Address = 10.123.1.2/32, fd00::2/128
DNS = 1.1.1.1
[Peer]
PublicKey = {KEY}
PresharedKey = {KEY}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = vpn.example.test:51820
PersistentKeepalive = 25
"""
AUTH = egress.parse_auth({"username": "fixture", "password": "local-test-password"})


def request(authority="apis.spectrum.net:443", auth=AUTH, extras=b""):
    return b"CONNECT " + authority.encode() + b" HTTP/1.1\r\nProxy-Authorization: " + auth + b"\r\n" + extras + b"\r\n"


class ProfileTests(unittest.TestCase):
    def test_valid_profile_keeps_only_supported_values(self):
        result = egress.parse_profile(PROFILE)
        self.assertEqual(result["endpoint"], ("vpn.example.test", 51820))
        self.assertEqual(result["mtu"], 1420)
        self.assertEqual(result["keepalive"], 25)
        self.assertEqual(len(result["addresses"]), 2)

    def test_rejects_hooks_duplicate_keys_and_additional_peers(self):
        for change in [
            PROFILE.replace("DNS = 1.1.1.1", "PostUp = curl https://example.test"),
            PROFILE.replace("DNS = 1.1.1.1", "SaveConfig = true"),
            PROFILE.replace("DNS = 1.1.1.1", "Table = off"),
            PROFILE.replace("DNS = 1.1.1.1", f"PrivateKey = {KEY}"),
            PROFILE + f"\n[Peer]\nPublicKey = {KEY}\n",
            PROFILE + "\0",
        ]:
            with self.subTest(profile=change.replace(KEY, "<fixture>")):
                with self.assertRaises(egress.ConfigError):
                    egress.parse_profile(change)

    def test_requires_ipv4_and_full_ipv4_peer_route(self):
        for change in [
            PROFILE.replace("10.123.1.2/32, ", ""),
            PROFILE.replace("0.0.0.0/0", "10.0.0.0/8"),
            PROFILE.replace("vpn.example.test:51820", "[2001:db8::1]:51820"),
            PROFILE.replace("vpn.example.test:51820", "vpn.example.test:0"),
            PROFILE.replace("PersistentKeepalive = 25", "PersistentKeepalive = -1"),
            PROFILE.replace(KEY, "not-a-key"),
        ]:
            with self.assertRaises(egress.ConfigError):
                egress.parse_profile(change)

    def test_auth_is_required_and_control_characters_are_rejected(self):
        token = AUTH.split(b" ")[1].decode()
        self.assertEqual(egress.parse_auth({"basicToken": token}), AUTH)
        for value in [{}, None, {"username": "x", "password": ""}, {"username": "x:y", "password": "z"}, {"username": "x", "password": "a\nb"}, {"basicToken": "bad"}, {"basicToken": token, "extra": True}]:
            with self.assertRaises(egress.ConfigError):
                egress.parse_auth(value)

    def test_validate_reads_runtime_files_without_configuring_network(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "wg.conf").write_text(PROFILE)
            Path(directory, "proxy.json").write_text(json.dumps({"username": "fixture", "password": "local-test-password"}))
            with patch("sys.argv", ["egress.py", "--config-dir", directory, "--validate"]), patch.object(egress, "configure_wireguard") as configure, patch("sys.stdout", new_callable=io.StringIO) as output:
                self.assertEqual(egress.main(), 0)
                configure.assert_not_called()
                self.assertEqual(output.getvalue(), '{"valid":true}\n')

    def test_bootstrap_never_changes_default_or_host_routes(self):
        calls = []
        profile = egress.parse_profile(PROFILE)
        with tempfile.TemporaryDirectory() as directory:
            real_temporary = tempfile.NamedTemporaryFile
            def temporary(**kwargs):
                kwargs["dir"] = directory
                return real_temporary(**kwargs)
            def command(args):
                calls.append(args)
                if args[:2] == ["wg", "setconf"]:
                    path = Path(args[3])
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                    config = path.read_text()
                    self.assertNotIn("Address", config)
                    self.assertNotIn("DNS", config)
                    self.assertIn("Endpoint = 198.51.100.1:51820", config)
            with patch.object(egress, "command", side_effect=command), patch.object(egress.socket, "getaddrinfo", return_value=[(None, None, None, None, ("198.51.100.1", 51820))]), patch.object(egress.tempfile, "NamedTemporaryFile", side_effect=temporary):
                egress.configure_wireguard(profile)
            self.assertFalse(list(Path(directory).iterdir()))
        self.assertIn(["ip", "route", "add", "default", "dev", "wg0", "table", "51820"], calls)
        self.assertIn(["ip", "rule", "add", "priority", "10000", "oif", "wg0", "lookup", "51820"], calls)
        self.assertIn(["ip", "rule", "add", "priority", "10001", "oif", "wg0", "prohibit"], calls)
        self.assertTrue(all(KEY not in " ".join(call) for call in calls))
        self.assertFalse(any("eth0" in call or "main" in call or "sysctl" in call for call in calls))
        self.assertFalse(any("fd00::2/128" in call for call in calls))


class DnsTests(unittest.TestCase):
    def setUp(self):
        route = patch.object(egress, "routing_ready", return_value=True)
        route.start()
        self.addCleanup(route.stop)

    def test_stalled_dns_has_bounded_daemon_workers_and_keeps_slots_until_finished(self):
        released = threading.Event()
        workers = []
        result = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("1.1.1.1", 443))]

        def stalled(*_):
            workers.append(threading.current_thread())
            released.wait(2)
            return result

        with patch.object(egress, "DNS_SLOTS", threading.BoundedSemaphore(2)), patch.object(egress.socket, "getaddrinfo", side_effect=stalled) as resolver:
            try:
                for _ in range(2):
                    started = time.monotonic()
                    with self.assertRaises(OSError):
                        egress.resolve_ipv4("apis.spectrum.net", 443, socket.SOCK_STREAM, started + 0.05)
                    self.assertLess(time.monotonic() - started, 0.5)
                for _ in range(20):
                    with self.assertRaises(OSError):
                        egress.resolve_ipv4("apis.spectrum.net", 443, socket.SOCK_STREAM, time.monotonic() + 1)
                self.assertEqual(resolver.call_count, 2)
                self.assertEqual(len(workers), 2)
                self.assertTrue(all(worker.daemon for worker in workers))
            finally:
                released.set()
                for worker in workers:
                    worker.join(1)
            resolver.side_effect = None
            resolver.return_value = result
            self.assertEqual(egress.resolve_ipv4("apis.spectrum.net", 443, socket.SOCK_STREAM, time.monotonic() + 1), result)

    def test_dns_failure_or_expired_budget_never_opens_a_direct_socket(self):
        with patch.object(egress.socket, "getaddrinfo", side_effect=socket.gaierror("private resolver detail")), patch.object(egress.socket, "socket") as create:
            with self.assertRaisesRegex(OSError, "^DNS resolution unavailable$"):
                egress.connect_upstream("apis.spectrum.net")
            create.assert_not_called()
        with patch.object(egress.socket, "getaddrinfo") as resolver:
            with self.assertRaises(OSError):
                egress.resolve_ipv4("apis.spectrum.net", 443, socket.SOCK_STREAM, time.monotonic() - 1)
            resolver.assert_not_called()

    def test_connect_deadline_includes_stalled_dns_and_endpoint_bootstrap_uses_same_resolver(self):
        released, finished = threading.Event(), threading.Event()

        def stalled(*_):
            try:
                released.wait(2)
                return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("1.1.1.1", 443))]
            finally:
                finished.set()

        with patch.object(egress, "CONNECT_SECONDS", 0.03), patch.object(egress.socket, "getaddrinfo", side_effect=stalled), patch.object(egress.socket, "socket") as create:
            try:
                started = time.monotonic()
                with self.assertRaises(OSError):
                    egress.connect_upstream("apis.spectrum.net")
                self.assertLess(time.monotonic() - started, 0.5)
                create.assert_not_called()
            finally:
                released.set()
                self.assertTrue(finished.wait(1))
        with patch.object(egress, "resolve_ipv4", side_effect=OSError("DNS resolution unavailable")) as resolver, patch.object(egress, "command") as command:
            with self.assertRaises(OSError):
                egress.configure_wireguard(egress.parse_profile(PROFILE))
            self.assertEqual(resolver.call_args.args[:3], ("vpn.example.test", 51820, socket.SOCK_DGRAM))
            command.assert_not_called()


class RoutingTests(unittest.TestCase):
    def test_route_gate_requires_one_direct_wireguard_default(self):
        expected = {"dst": "default", "dev": "wg0", "scope": "link", "flags": []}
        for routes, allowed in [([expected], True), ([expected, {"dst": "1.1.1.1", "dev": "wg0"}], True),
                                ([], False), ([expected, expected], False), ({}, False), ([None], False),
                                ([{**expected, "dev": "eth0"}], False), ([{**expected, "gateway": "1.1.1.1"}], False),
                                ([{**expected, "via": "1.1.1.1"}], False), ([{**expected, "type": "blackhole"}], False),
                                ([{**expected, "flags": ["linkdown"]}], False), ([{**expected, "multipath": []}], False)]:
            with self.subTest(routes=routes), patch.object(egress.subprocess, "run", return_value=MagicMock(stdout=json.dumps(routes))) as run:
                self.assertEqual(egress.routing_ready(), allowed)
                self.assertEqual(run.call_args.args[0], ["ip", "-j", "route", "show", "table", "51820"])
                self.assertEqual(run.call_args.kwargs["timeout"], 1)

    def test_bad_route_output_or_command_failure_is_closed(self):
        for stdout in ["not-json", "x" * 32769]:
            with patch.object(egress.subprocess, "run", return_value=MagicMock(stdout=stdout)):
                self.assertFalse(egress.routing_ready())
        with patch.object(egress.subprocess, "run", side_effect=OSError("private command detail")):
            self.assertFalse(egress.routing_ready())

    def test_missing_route_blocks_dns_socket_and_health_checks(self):
        with patch.object(egress, "routing_ready", return_value=False), patch.object(egress, "resolve_ipv4") as resolve, patch.object(egress.socket, "socket") as create, patch.object(egress.subprocess, "run") as run:
            with self.assertRaisesRegex(OSError, "^Control egress unavailable$"):
                egress.connect_upstream("apis.spectrum.net")
            self.assertFalse(egress.healthy())
            resolve.assert_not_called()
            create.assert_not_called()
            run.assert_not_called()


class RequestTests(unittest.TestCase):
    def setUp(self):
        route = patch.object(egress, "routing_ready", return_value=True)
        route.start()
        self.addCleanup(route.stop)

    def test_only_named_control_hosts_on_tls_port_are_allowed(self):
        for host in egress.HOSTS:
            self.assertEqual(egress.parse_request(request(host + ":443"), AUTH), (200, host))
        for authority in ["edge-mm.spectrum.net:443", "example.test:443", "apis.spectrum.net:80", "apis.spectrum.net.:443", "127.0.0.1:443", "apis.spectrum.net@evil.test:443", "apis.spectrum.net:443/path"]:
            self.assertEqual(egress.parse_request(request(authority), AUTH)[0], 403)

    def test_unauthenticated_and_ambiguous_requests_are_denied(self):
        self.assertEqual(egress.parse_request(request(auth=b"Basic incorrect"), AUTH)[0], 407)
        self.assertEqual(egress.parse_request(b"CONNECT apis.spectrum.net:443 HTTP/1.1\r\n\r\n", AUTH)[0], 407)
        for value in [request(extras=b"Proxy-Authorization: duplicate\r\n"), request(extras=b"Transfer-Encoding: chunked\r\n"), request(extras=b"Content-Length: 1\r\n"), request() + b"body", b"x" * 8193]:
            self.assertEqual(egress.parse_request(value, AUTH)[0], 400)

    def test_header_read_is_size_bounded_and_uses_one_total_deadline(self):
        client = MagicMock()
        client.recv.return_value = b"x" * 1024
        with self.assertRaises(ValueError):
            egress.read_headers(client)
        self.assertEqual(client.recv.call_count, 8)
        client.reset_mock()
        client.recv.return_value = b"x"
        clock = iter([0, 1, 6])
        with self.assertRaises(ValueError):
            egress.read_headers(client, now=lambda: next(clock))
        self.assertEqual(client.recv.call_count, 1)

    def test_upstream_binds_before_connect_and_never_falls_back(self):
        upstream = MagicMock()
        results = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("1.1.1.1", 443))]
        with patch.object(egress.socket, "SO_BINDTODEVICE", 25, create=True), patch.object(egress.socket, "getaddrinfo", return_value=results), patch.object(egress.socket, "socket", return_value=upstream):
            self.assertIs(egress.connect_upstream("apis.spectrum.net"), upstream)
            methods = [call[0] for call in upstream.method_calls]
            self.assertLess(methods.index("setsockopt"), methods.index("connect"))
            upstream.setsockopt.assert_called_with(socket.SOL_SOCKET, 25, b"wg0\0")
            upstream.reset_mock()
            upstream.setsockopt.side_effect = OSError("No such interface")
            with self.assertRaises(OSError):
                egress.connect_upstream("apis.spectrum.net")
            upstream.connect.assert_not_called()
            upstream.close.assert_called_once()

    def test_private_dns_answers_are_rejected_before_a_socket_is_created(self):
        with patch.object(egress.socket, "getaddrinfo", return_value=[(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", 443))]), patch.object(egress.socket, "socket") as create:
            with self.assertRaises(OSError):
                egress.connect_upstream("apis.spectrum.net")
            create.assert_not_called()

    def test_tunnel_idle_timeout_is_bounded(self):
        client, caller = socket.socketpair()
        upstream, endpoint = socket.socketpair()
        try:
            started = time.monotonic()
            with patch.object(egress, "IDLE_SECONDS", 0.03):
                egress.relay(client, upstream)
            self.assertLess(time.monotonic() - started, 0.5)
        finally:
            for sock in (client, caller, upstream, endpoint):
                sock.close()

    def test_continuous_traffic_still_hits_tunnel_total_deadline(self):
        client, upstream = MagicMock(), MagicMock()
        client.recv.return_value = b"x"
        upstream.recv.return_value = b"x"
        client.send.side_effect = upstream.send.side_effect = len
        stamp = [0]
        def now():
            stamp[0] += 0.01
            return stamp[0]
        def select_ready(reads, writes, _, timeout):
            return reads, writes, []
        with patch.object(egress, "TUNNEL_SECONDS", 0.12), patch.object(egress.select, "select", side_effect=select_ready) as choose:
            egress.relay(client, upstream, now=now)
        self.assertLessEqual(choose.call_count, 4)

    def test_capacity_is_rejected_before_another_worker_is_created(self):
        with egress.ProxyServer(("127.0.0.1", 0), AUTH) as server:
            for _ in range(egress.ACTIVE_LIMIT):
                self.assertTrue(server.slots.acquire(blocking=False))
            client = MagicMock()
            with patch.object(egress.socketserver.ThreadingMixIn, "process_request") as spawn:
                server.process_request(client, ("127.0.0.1", 1))
                spawn.assert_not_called()
            self.assertIn(b"503", client.sendall.call_args[0][0])
            client.close.assert_called_once()

    def test_health_requires_a_recent_nonzero_handshake(self):
        for stamp, expected in [(950, True), (0, False), (700, False), (1001, False)]:
            completed = MagicMock(stdout=f"fixture-public-key\t{stamp}\n")
            with patch.object(egress.subprocess, "run", return_value=completed):
                self.assertEqual(egress.healthy(now=lambda: 1000), expected)

    def test_supervision_exits_after_startup_or_reconnect_grace(self):
        for checks, stamps in [([False], [0, 181]), ([True, False], [0, 30, 271])]:
            stop, fail = MagicMock(), MagicMock()
            stop.wait.return_value = False
            with patch("sys.stdout", new_callable=io.StringIO) as output:
                egress.supervise(stop, check=MagicMock(side_effect=checks), now=MagicMock(side_effect=stamps), fail=fail)
                fail.assert_called_once()
                self.assertEqual(output.getvalue(), '{"event":"control_egress_handshake_expired"}\n')


if __name__ == "__main__":
    unittest.main()
