#!/usr/bin/env python3
"""Generated TrueHD fixtures for AudioCompatibilityTests; no provider media.

Requires ffmpeg/ffprobe. Native tests use localhost:18883. Video is generated,
audio is a six-channel tone (FFmpeg's TrueHD encoder downmixes 7.1 to 5.1).
The missing native TrueHD decoder is the same for either channel layout.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import re
import subprocess
import tempfile
import time

ROOT = Path(tempfile.mkdtemp(prefix="velvet-audio-test-"))
TRUEHD = "0123456789abcdef"
ALTERNATE = "1111111111111111"
AAC = "2222222222222222"
SLOW = "3333333333333333"


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


ffmpeg("-f", "lavfi", "-i", "color=c=navy:s=320x180:r=24:d=30", "-f", "lavfi", "-i",
       "aevalsrc=0.1*sin(2*PI*220*t)|0.1*sin(2*PI*330*t)|0.1*sin(2*PI*440*t)|0.02*sin(2*PI*60*t)|0.1*sin(2*PI*550*t)|0.1*sin(2*PI*660*t):s=48000:d=30:c=5.1",
       "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast", "-g", "24",
       "-c:a", "truehd", "-strict", "-2", "-metadata:s:a:0", "language=eng", str(ROOT / f"{TRUEHD}.mkv"))
ffmpeg("-i", str(ROOT / f"{TRUEHD}.mkv"), "-map", "0", "-c:v", "copy", "-c:a", "aac", "-ac", "2", str(ROOT / f"{AAC}.mkv"))
ffmpeg("-i", str(ROOT / f"{TRUEHD}.mkv"), "-i", str(ROOT / f"{AAC}.mkv"), "-map", "0:v", "-map", "0:a", "-map", "1:a",
       "-c", "copy", "-metadata:s:a:1", "language=fra", str(ROOT / f"{ALTERNATE}.mkv"))
ffmpeg("-i", str(ROOT / f"{TRUEHD}.mkv"), "-map", "0:a:0", "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2", str(ROOT / "compat.wav"))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok"); return
        match = re.fullmatch(r"/stream/([a-f0-9]{16})(/audio(?:/1.wav)?)?", self.path)
        if not match or match[1] not in [TRUEHD, ALTERNATE, AAC, SLOW]:
            self.send_error(404); return
        sid, suffix = match.groups()
        source = ROOT / f"{TRUEHD if sid == SLOW else sid}.mkv"
        if suffix == "/audio":
            time.sleep(5 if sid == SLOW else 2)  # Exercises pause/cancel races during preparation.
            streams = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(source)]))["streams"]
            tracks = [{"index": t["index"], "codec": t["codec_name"], "channels": t["channels"],
                       "language": t.get("tags", {}).get("language")} for t in streams if t["codec_type"] == "audio"]
            data = json.dumps({"durationMs": 30000, "audioTracks": tracks}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers()
            try: self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        path = ROOT / "compat.wav" if suffix else source
        data = path.read_bytes(); start = 0; end = len(data)-1
        requested = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        if requested:
            start = int(requested[1]); end = min(int(requested[2]) if requested[2] else end, end)
        if start > end:
            self.send_response(416); self.end_headers(); return
        self.send_response(206 if requested else 200)
        self.send_header("Content-Type", "audio/wav" if suffix else "video/x-matroska")
        self.send_header("Accept-Ranges", "bytes")
        if requested: self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.send_header("Content-Length", str(end-start+1)); self.end_headers()
        try: self.wfile.write(data[start:end+1])
        except (BrokenPipeError, ConnectionResetError): pass


print("Audio fixtures ready on 127.0.0.1:18883", flush=True)
ThreadingHTTPServer(("127.0.0.1", 18883), Handler).serve_forever()
