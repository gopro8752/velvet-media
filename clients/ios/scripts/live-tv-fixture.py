#!/usr/bin/env python3
"""Local-only Live TV UI fixture. Requires ffmpeg; never contacts a provider.

Run before LiveTVUITests. It serves a generated, silent HLS test pattern and
tracks live viewer cleanup. API authentication deliberately uses a dummy token.
"""
import json
import pathlib
import subprocess
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from urllib.parse import urlparse, parse_qs
import urllib.request
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHANNELS = [
    {"id": "sports-1", "name": "Test Sports", "number": "101", "logoUrl": None, "group": "Sports"},
    {"id": "news-1", "name": "Test News", "number": "102", "logoUrl": None, "group": "News"},
    {"id": "slow-1", "name": "Slow Channel", "number": "103", "logoUrl": None, "group": "Test"},
]
LOCK = threading.Lock()
SESSIONS = {}
EVENTS = []
ROOT = None
REAL_SPORTS = "--real-sports" in sys.argv
SPORTS_REQUESTS = 0
ESCAPE_REQUESTS = 0


def iso(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc).isoformat().replace("+00:00", "Z")


def sports_events(scope):
    now = time.time()
    if REAL_SPORTS:
        matches = json.load(urllib.request.urlopen("https://streamed.st/api/matches/live", timeout=20))
        return {"enabled": True, "sourceName": "Streamed", "sports": [{"id": "basketball", "name": "Basketball"}, {"id": "american-football", "name": "American Football"}],
                "events": [{"id": match["id"], "title": match["title"], "sportId": match.get("category", "sports"), "sportName": match.get("category", "Sports").title(),
                            "startTime": iso(match["date"] / 1000), "isLive": True, "popular": bool(match.get("popular")), "posterUrl": None,
                            "homeTeam": None, "awayTeam": None, "sourceCount": len(match.get("sources", []))} for match in matches], "message": None}
    def event(id, title, sport, live, start):
        return {"id": id, "title": title, "sportId": sport, "sportName": sport.title(), "startTime": iso(start),
                "isLive": live, "popular": live, "posterUrl": None, "homeTeam": None, "awayTeam": None, "sourceCount": 2}
    events = [event("test-event", "Fixture Tigers vs Bears", "basketball", True, now - 900),
              event("future-event", "Tomorrow United vs City", "football", False, now + 86400)]
    return {"enabled": True, "sourceName": "Streamed", "sports": [{"id": "basketball", "name": "Basketball"}, {"id": "football", "name": "Football"}],
            "events": events if scope == "all" else events[:1], "message": None}


def sports_streams(event_id):
    if REAL_SPORTS:
        matches = json.load(urllib.request.urlopen("https://streamed.st/api/matches/live", timeout=20))
        match = next(m for m in matches if m["id"] == event_id)
        streams = []
        for source in match.get("sources", []):
            try:
                streams.extend(json.load(urllib.request.urlopen("https://streamed.st/api/stream/" + source["source"] + "/" + source["id"], timeout=20)))
            except Exception:
                pass
        return {"eventId": event_id, "streams": streams, "message": None}
    return {"eventId": event_id, "streams": [
        {"id": "same-id", "source": "fixture", "streamNo": 1, "language": "English", "hd": True, "embedUrl": "http://127.0.0.1:18881/embed/hd"},
        {"id": "same-id", "source": "fixture", "streamNo": 2, "language": "Spanish", "hd": False, "embedUrl": "http://127.0.0.1:18881/embed/sd"}], "message": None}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def response(self, status, body=None, mime="application/json"):
        data = b"" if body is None else (json.dumps(body).encode() if not isinstance(body, bytes) else body)
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def authorized(self):
        if self.headers.get("Authorization") == "Bearer fixture-only":
            return True
        self.response(401, {"error": "Fixture API requires its dummy token."})
        return False

    def do_GET(self):
        global SPORTS_REQUESTS, ESCAPE_REQUESTS
        path = urlparse(self.path).path
        if self.path == "/test/status":
            with LOCK:
                self.response(200, {"activeSessions": len(SESSIONS), "events": list(EVENTS),
                                    "sportsRequests": SPORTS_REQUESTS, "escapeRequests": ESCAPE_REQUESTS, "realSports": REAL_SPORTS})
            return
        if path == "/sports/events":
            if self.authorized():
                self.response(200, sports_events(parse_qs(urlparse(self.path).query).get("scope", ["live"])[0]))
            return
        if path.startswith("/sports/events/") and path.endswith("/streams"):
            if self.authorized():
                self.response(200, sports_streams(path.split("/")[3]))
            return
        if path == "/live/guide":
            if self.authorized():
                now = time.time()
                self.response(200, {"enabled": True, "sourceName": "Spectrum", "updatedAt": iso(now), "message": None, "channels": [
                    {"channelId": "sports-1", "programs": [
                        {"id": "current", "title": "Fixture Championship", "startTime": iso(now - 1200), "endTime": iso(now + 1800), "description": "Live fixture coverage.", "episodeTitle": None},
                        {"id": "next", "title": "Fixture Highlights", "startTime": iso(now + 1800), "endTime": iso(now + 3600), "description": "The best moments.", "episodeTitle": "Final round"},
                        {"id": "later", "title": "Fixture Late Show", "startTime": iso(now + 8100), "endTime": iso(now + 10800), "description": "A future guide entry for timeline navigation.", "episodeTitle": None}]}]})
            return
        if path.startswith("/embed/"):
            variant = "HD" if path.endswith("hd") else "SD"
            body = f'''<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{{margin:0;background:#151523;color:white;font:14px sans-serif}}p{{display:inline-block;margin:8px}}video{{display:block;width:100%;max-height:60vh}}button,a{{color:white;margin:8px;display:inline-block}}</style></head><body>
            <p>Fixture stream {variant}</p><p id="status">Video waiting</p>
            <button onclick="window.open('/escape','_blank')">Open popup</button><a href="/escape" target="_top">Leave player</a><a href="/escape" download="file.txt">Download file</a>
            <form action="/escape" style="display:inline"><button type="submit">Submit form</button></form>
            <video id="video" playsinline muted controls src="/fixture-sports/index.m3u8"></video>
            <button onclick="video.pause()">Pause fixture</button>
            <script>video.onplaying=()=>document.getElementById('status').textContent='Video playing';video.onpause=()=>document.getElementById('status').textContent='Video paused';</script></body></html>'''
            self.response(200, body.encode(), "text/html")
            return
        if path == "/escape":
            with LOCK:
                ESCAPE_REQUESTS += 1
            self.response(200, b"Escaped player", "text/plain")
            return
        if path.startswith("/fixture-sports/"):
            leaf = path.rsplit("/", 1)[-1]
            file = ROOT / leaf
            if file.is_file():
                with LOCK:
                    SPORTS_REQUESTS += 1
                self.response(200, file.read_bytes(), "application/vnd.apple.mpegurl" if leaf.endswith("m3u8") else "video/mp2t")
                return
        if self.path.endswith("/live/channels"):
            if not self.authorized():
                return
            self.response(200, {"enabled": True, "sourceName": "Local test pattern", "channels": CHANNELS, "message": None})
            return
        parts = self.path.split("?")[0].split("/")
        if len(parts) == 5 and parts[1:3] == ["live", "streams"]:
            with LOCK:
                valid = parts[3] in SESSIONS
            if not valid:
                self.response(410, {"error": "Viewer released"})
                return
            leaf = parts[4]
            file = ROOT / leaf
            if "/" not in leaf and file.is_file():
                mime = "application/vnd.apple.mpegurl" if leaf.endswith(".m3u8") else "video/mp2t"
                self.response(200, file.read_bytes(), mime)
                return
        self.response(404, {"error": "Fixture route not found"})

    def do_POST(self):
        if self.path != "/live/tune" or not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        channel = next((c for c in CHANNELS if c["id"] == body.get("channelId")), None)
        if not channel:
            self.response(404, {"error": "Channel missing"})
            return
        if channel["id"] == "slow-1":
            time.sleep(3)
        sid = uuid.uuid4().hex
        with LOCK:
            SESSIONS[sid] = channel["id"]
            EVENTS.append({"event": "tune", "channel": channel["id"], "id": sid})
        self.response(200, {"sessionId": sid, "playbackPath": f"/live/streams/{sid}/index.m3u8",
                            "mimeType": "application/vnd.apple.mpegurl", "channel": channel,
                            "canPause": False, "canSeek": False})

    def do_DELETE(self):
        if not self.path.startswith("/live/sessions/") or not self.authorized():
            return
        sid = self.path.rsplit("/", 1)[-1]
        with LOCK:
            SESSIONS.pop(sid, None)
            EVENTS.append({"event": "delete", "id": sid})
        self.response(204)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="velvet-live-fixture-") as folder:
        ROOT = pathlib.Path(folder)
        encoder = subprocess.Popen([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-re", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24",
            "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-g", "48", "-b:v", "700k",
            "-c:a", "aac", "-b:a", "64k", "-f", "hls", "-hls_time", "2", "-hls_list_size", "8",
            "-hls_flags", "delete_segments", str(ROOT / "index.m3u8")
        ])
        try:
            server = ThreadingHTTPServer(("127.0.0.1", 18881), Handler)
            print("Local Live TV fixture listening on127.0.0.1:18881", flush=True)
            server.serve_forever()
        finally:
            encoder.terminate()
            encoder.wait(timeout=10)
