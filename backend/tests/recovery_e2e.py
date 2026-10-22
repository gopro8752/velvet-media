#!/usr/bin/env python3
"""Black-box beta recovery test using loopback-only HTTP/NNTP and synthetic media.

No real provider, indexer, account, credential or deployed service is contacted.
Supply the built beta binary and a PAR2 executable. Evidence lives outside Git.
"""
import argparse
import concurrent.futures
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import socketserver
import sqlite3
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import xml.sax.saxutils
import zlib

ARTICLE = 128 * 1024


def fnv(data):
    h = 0xcbf29ce484222325
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & 0xffffffffffffffff
    return f'{h:016x}'


def yenc(data, name, part, start, total, corrupt=False):
    lines = []
    encoded = bytearray()
    for value in data:
        value = (value + 42) & 255
        if value in (0, 10, 13, 61):
            encoded.extend((61, (value + 64) & 255))
        else:
            encoded.append(value)
        if len(encoded) >= 128:
            lines.append(bytes(encoded)); encoded.clear()
    if encoded: lines.append(bytes(encoded))
    crc = zlib.crc32(data) ^ (1 if corrupt else 0)
    body = (f'=ybegin part={part} line=128 size={total} name={name}\r\n'
            f'=ypart begin={start+1} end={start+len(data)}\r\n').encode()
    body += b'\r\n'.join(lines) + b'\r\n'
    body += f'=yend size={len(data)} part={part} pcrc32={crc:08x}\r\n'.encode()
    return b'\r\n'.join(b'.'+line if line.startswith(b'.') else line for line in body.split(b'\r\n'))


class NNTP(socketserver.StreamRequestHandler):
    def handle(self):
        self.wfile.write(b'200 isolated synthetic NNTP\r\n')
        while True:
            raw = self.rfile.readline()
            if not raw: return
            command = raw.decode().strip()
            verb = command.split(' ', 1)[0].upper()
            if verb == 'AUTHINFO': response = b'281 accepted fixture account\r\n'
            elif verb == 'GROUP': response = b'211 100 1 100 fixture\r\n'
            elif verb in ('BODY', 'STAT'):
                mid = command.split(' ', 1)[1].strip('<>')
                with self.server.lock:
                    key = f'{verb} {mid}'
                    self.server.calls[key] = self.server.calls.get(key, 0) + 1
                data = self.server.articles.get(mid)
                if data is None: response = b'430 missing fixture article\r\n'
                elif verb == 'STAT': response = f'223 1 <{mid}>\r\n'.encode()
                else: response = f'222 1 <{mid}>\r\n'.encode() + data + b'.\r\n'
            elif verb == 'QUIT':
                self.wfile.write(b'205 closing\r\n'); return
            else: response = b'500 unsupported fixture command\r\n'
            self.wfile.write(response)


class TCP(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class Catalog(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        body = self.server.documents.get(self.path)
        self.send_response(200 if body is not None else 404)
        self.send_header('Content-Length', str(len(body or b'')))
        self.end_headers()
        if body: self.wfile.write(body)


def start_server(server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--par2', default=shutil.which('par2'), type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not args.par2 or not args.par2.is_file(): parser.error('--par2 must name an executable')
    binary = args.binary.resolve(); par2 = args.par2.resolve()
    out = args.output or Path(tempfile.mkdtemp(prefix='velvet-beta-recovery-e2e-'))
    out.mkdir(parents=True, exist_ok=True)
    fixture = out/'fixture'; fixture.mkdir(exist_ok=True)
    ffmpeg = shutil.which('ffmpeg')
    subprocess.run([ffmpeg, '-v','error','-y','-f','lavfi','-i','testsrc2=size=640x360:rate=30',
                    '-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','20',
                    '-c:v','libx264','-preset','veryfast','-b:v','2M','-maxrate','2M','-bufsize','2M',
                    '-x264-params','nal-hrd=cbr:filler=1','-g','60','-c:a','aac','-movflags','+faststart',
                    str(fixture/'clip.mp4')], check=True)
    subprocess.run([str(par2),'c','-s65536','-c8','-n1','clip.par2','clip.mp4'], cwd=fixture,
                   check=True, stdout=subprocess.DEVNULL)
    original = (fixture/'clip.mp4').read_bytes()
    primary, secondary, documents, ids = {}, {}, {}, {}
    file_data = {p.name:p.read_bytes() for p in sorted(fixture.iterdir()) if p.is_file() and (p.suffix=='.par2' or p.name=='clip.mp4')}
    for case in ['repair','ahead','insufficient']:
        entries=[]
        for file_index,(name,data) in enumerate(file_data.items()):
            segments=[]
            for index,start in enumerate(range(0,len(data),ARTICLE)):
                chunk=data[start:start+ARTICLE]; mid=f'{case}-{file_index}-{index}@fixture.invalid'
                body=yenc(chunk,name,index+1,start,len(data))
                is_media=name=='clip.mp4'
                missing=is_media and (12<=index<=17 if case=='insufficient' else index==12)
                if not missing:
                    secondary[mid]=body
                    primary[mid]=yenc(chunk,name,index+1,start,len(data),corrupt=is_media and index==8)
                if is_media and index==8: ids[case+'-corrupt']=mid
                if is_media and index==12: ids[case+'-missing']=mid
                segments.append(f'<segment bytes="{len(body)}" number="{index+1}">{mid}</segment>')
            subject=xml.sax.saxutils.quoteattr('"'+name+'" yEnc')
            entries.append(f'<file subject={subject}><groups><group>fixture</group></groups><segments>'+''.join(segments)+'</segments></file>')
        documents['/'+case+'.nzb']=('<nzb>'+''.join(entries)+'</nzb>').encode()
    servers=[]; proc=None
    try:
        for articles in [primary, secondary]:
            server=TCP(('127.0.0.1',0),NNTP);server.articles=articles;server.calls={};server.lock=threading.Lock();servers.append(start_server(server))
        catalog=http.server.ThreadingHTTPServer(('127.0.0.1',0),Catalog);catalog.documents=documents;servers.append(start_server(catalog))
        sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close()
        cfg=out/'velvet-fixture.toml';db=out/'fixture.db'
        config=f'bind="127.0.0.1"\nport={port}\ndb_path={json.dumps(str(db))}\n'
        # Root/repair-agent API configuration is checked by the real binary.
        config+='\n[repair]\nenabled=true\ncache_dir='+json.dumps(str(out/'cache'))+'\npar2_binary='+json.dumps(str(par2))+'\n'
        config+='\n[stream_buffer]\nenabled=true\nlookahead_seconds=15\nffprobe_binary='+json.dumps(shutil.which('ffprobe'))+'\n'
        for index,server in enumerate(servers[:2]):
            config+=f'\n[[providers]]\nname="fixture-{index}"\nhost="127.0.0.1"\nport={server.server_address[1]}\ntls=false\nusername="fixture"\npassword="fixture"\nmax_connections=8\n'
        cfg.write_text(config);cfg.chmod(0o600)
        env={k:v for k,v in os.environ.items() if not k.startswith(('VELVET_','NNTP_','TMDB_'))}
        env.update(VELVET_CONFIG=str(cfg),VELVET_DB=str(db),RUST_LOG='info')
        with (out/'backend.log').open('wb') as log:
            proc=subprocess.Popen([str(binary),'serve'],env=env,stdout=log,stderr=subprocess.STDOUT)
            base=f'http://127.0.0.1:{port}'
            for attempt in range(100):
                if proc.poll() is not None: raise RuntimeError('Beta backend exited; see isolated backend.log')
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=.1): break
                except OSError:time.sleep(.1)
            else:raise RuntimeError('Beta backend did not bind')
            outcomes={}
            for case in ['repair','ahead','insufficient']:
                nzb=f'http://127.0.0.1:{catalog.server_port}/{case}.nzb';sid=fnv(nzb.encode())
                with sqlite3.connect(db) as connection:
                    connection.execute('INSERT INTO stream_registrations (sid,nzb_url,touched_at) VALUES (?,?,?)',(sid,nzb,int(time.time()*1000)))
                ahead=None
                if case=='ahead':
                    # The player has only opened the beginning. The independent
                    # heartbeat/probe must encounter and repair the later hole.
                    request=urllib.request.Request(base+'/stream/'+sid,headers={'Range':'bytes=0-65535'})
                    with urllib.request.urlopen(request,timeout=30) as response:
                        assert response.read()==original[:65536]
                    heartbeat={'sessionId':'fixture-player','generation':1,'positionMs':0,
                               'durationMs':20000,'bufferedPositionMs':1000,'playing':True}
                    deadline=time.monotonic()+45
                    while time.monotonic()<deadline:
                        request=urllib.request.Request(base+'/stream/'+sid+'/playback',
                            data=json.dumps(heartbeat).encode(),headers={'Content-Type':'application/json'})
                        with urllib.request.urlopen(request,timeout=10) as response: response.read()
                        with urllib.request.urlopen(base+'/stream/'+sid+'/health?sessionId=fixture-player',timeout=10) as response:
                            health=json.load(response)
                        exact_health=health.get('exactRecovery',{})
                        ahead=exact_health.get('verifiedAheadSeconds')
                        if isinstance(ahead,(int,float)) and ahead>5: break
                        time.sleep(.3)
                    (out/'ahead-health.json').write_text(json.dumps(health,indent=2)+'\n')
                    assert isinstance(ahead,(int,float)) and ahead>5,'Packet-indexed ahead buffer was not verified'
                    assert health.get('repair',{}).get('phase')=='ready','Look-ahead did not repair the later hole'
                received=bytearray();err=None;start=time.monotonic()
                try:
                    with urllib.request.urlopen(base+'/stream/'+sid,timeout=120) as response:
                        while True:
                            block=response.read(65536)
                            if not block:break
                            received.extend(block)
                except Exception as exception:err=type(exception).__name__
                exact=bytes(received)==original
                prefix=original.startswith(received)
                outcomes[case]={'exact_file':exact,'verified_original_prefix_only':prefix,'received_bytes':len(received),
                                'expected_bytes':len(original),'request_seconds':time.monotonic()-start,'error':err,
                                'secondary_corrupt_fallback_body_calls':servers[1].calls.get('BODY '+ids[case+'-corrupt'],0),
                                'primary_missing_body_calls':servers[0].calls.get('BODY '+ids[case+'-missing'],0)}
                if ahead is not None: outcomes[case]['verified_ahead_seconds_before_read']=ahead
                if case!='insufficient':
                    (out/'repaired-stream.mp4').write_bytes(received)
                    assert exact,'Original HTTP stream did not heal exactly'
                    assert outcomes[case]['secondary_corrupt_fallback_body_calls']>0,'Corrupt primary was not retried on secondary'
                    subprocess.run([ffmpeg,'-v','error','-xerror','-i',str(out/'repaired-stream.mp4'),'-f','null','-'],check=True)
                else:assert not exact and prefix,'Unrecoverable holes must stop safely, never supply wrong bytes'
            result={'passed':True,'network':'loopback only','original_sha256':hashlib.sha256(original).hexdigest(),'cases':outcomes}
            (out/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
    finally:
        if proc is not None:
            proc.terminate()
            try:proc.wait(timeout=10)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
        for server in servers:server.shutdown();server.server_close()

if __name__=='__main__':main()
