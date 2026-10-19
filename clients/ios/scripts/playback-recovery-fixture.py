#!/usr/bin/env python3
"""Local native-player fixture for PlaybackRecoveryPlayerTests (127.0.0.1:18885).

Reuses the generated H.264/AAC handoff clip when it is valid. Otherwise generates
a 90-second clip in a temporary directory with ffmpeg. No provider media, accounts,
or external network. /stream/hang accepts a media request but never supplies bytes;
/stream/dead returns 503; /stream/b and /stream/c support normal HTTP byte ranges.
Per-case /metrics timestamps measure recovery from VLC's first media request.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
import json
import re
import select
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
TEMP_MEDIA = None
EVENTS = []
LOCK = threading.Lock()
MEDIA = b""


def valid_media(path):
    if not path.is_file():
        return False
    result = subprocess.run([
        "ffprobe", "-v", "error", "-show_entries", "format=duration:stream=codec_name,codec_type",
        "-of", "json", str(path),
    ], capture_output=True, text=True, check=False)
    if result.returncode:
        return False
    try:
        info = json.loads(result.stdout)
        codecs = {s.get("codec_name") for s in info.get("streams", [])}
        return float(info["format"]["duration"]) >= 75 and {"h264", "aac"}.issubset(codecs)
    except (ValueError, KeyError, TypeError):
        return False


def load_media():
    global TEMP_MEDIA
    path = ROOT / "Tests/VelvetTests/handoff-fixture.mp4"
    if not valid_media(path):
        TEMP_MEDIA = tempfile.TemporaryDirectory(prefix="velvet-recovery-fixture-")
        path = Path(TEMP_MEDIA.name) / "recovery.mp4"
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=navy:s=320x180:r=24:d=90",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=90",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-g", "24",
            "-c:a", "aac", "-ac", "2", "-movflags", "+faststart", str(path),
        ], check=True)
    return path.read_bytes()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def respond(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        size = min(int(self.headers.get("Content-Length", "0")), 4096)
        if size:
            self.rfile.read(size)
        path = urlsplit(self.path).path
        if re.fullmatch(r"/stream/(hang|dead|b|c)/prepare", path):
            self.respond(200, b'{"status":"idle"}')
        else:
            self.respond(404)

    def do_GET(self):
        parsed = urlsplit(self.path)
        case = parse_qs(parsed.query).get("case", [""])[0][:100]
        if parsed.path == "/health":
            self.respond(200, b'{"fixture":"playback-recovery","version":1,"durationMs":90000}')
            return
        if parsed.path == "/metrics":
            with LOCK:
                events = [e.copy() for e in EVENTS if e["case"] == case]
            self.respond(200, json.dumps({"events": events}).encode())
            return
        status_match = re.fullmatch(r"/stream/(hang|dead|b|c)/health", parsed.path)
        if status_match:
            # No fabricated ready alternate: the startup watchdog/fallback queue
            # must make progress even when the source offers no recovery endpoint.
            self.respond(200, b'{"status":"unverified","recovery":{"status":"idle"}}')
            return
        match = re.fullmatch(r"/stream/(hang|dead|b|c)", parsed.path)
        if not match:
            self.respond(404)
            return
        source = match[1]
        with LOCK:
            EVENTS.append({"case": case, "source": source, "at": time.time(), "method": self.command,
                           "range": self.headers.get("Range", "")[:100]})
            del EVENTS[:-2048]
        if source == "dead":
            self.respond(503, b"Fixture source unavailable", "text/plain")
            return
        if source == "hang":
            # Bound the fixture worker while still exceeding the player's recovery
            # deadline. Return promptly when VLC cancels the old request.
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                try:
                    readable, _, _ = select.select([self.connection], [], [], .25)
                    if readable and not self.connection.recv(1, socket.MSG_PEEK):
                        break
                except (ConnectionError, OSError):
                    break
            self.close_connection = True
            return
        start, end = 0, len(MEDIA) - 1
        header = self.headers.get("Range")
        if header:
            requested = re.fullmatch(r"bytes=(\d*)-(\d*)", header)
            if not requested or not any(requested.groups()):
                self.respond(416)
                return
            first, last = requested.groups()
            if first:
                start = int(first)
                if last:
                    end = min(int(last), end)
            else:
                start = max(0, len(MEDIA) - int(last))
            if start > end or start >= len(MEDIA):
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{len(MEDIA)}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        self.send_response(206 if header else 200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(end - start + 1))
        if header:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(MEDIA)}")
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(MEDIA[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass


if __name__ == "__main__":
    MEDIA = load_media()
    print(f"Playback recovery fixture ready on 127.0.0.1:18885 ({len(MEDIA)} bytes)", flush=True)
    server = ThreadingHTTPServer(("127.0.0.1", 18885), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if TEMP_MEDIA is not None:
            TEMP_MEDIA.cleanup()
