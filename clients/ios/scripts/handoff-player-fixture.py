#!/usr/bin/env python3
"""Local generated-video fixture for TVHandoffPlayerTests; no provider/network data."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re

MEDIA = Path(__file__).resolve().parents[1] / "Tests/VelvetTests/handoff-fixture.mp4"
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok"); return
        if self.path != "/stream/0123456789abcdef":
            self.send_response(404); self.end_headers(); return
        data = MEDIA.read_bytes(); start = 0; end = len(data)-1
        match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        if match:
            start = int(match[1]); end = min(int(match[2]) if match[2] else end, end)
        self.send_response(206 if match else 200)
        self.send_header("Content-Type", "video/mp4"); self.send_header("Accept-Ranges", "bytes")
        if match: self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.send_header("Content-Length", str(end-start+1)); self.end_headers()
        try: self.wfile.write(data[start:end+1])
        except (BrokenPipeError, ConnectionResetError): pass

if __name__ == "__main__":
    print("Handoff fixture listening on 127.0.0.1:18882", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 18882), Handler).serve_forever()
