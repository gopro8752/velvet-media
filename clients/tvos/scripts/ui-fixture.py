#!/usr/bin/env python3
"""Loopback-only synthetic catalog and generated media for Apple TV UI tests.
No accounts or provider media are used; playback stays on loopback. Ctrl-C to stop.
"""
import json, re, subprocess, tempfile, time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

PORT = 18886
MEDIA = Path(__file__).resolve().parents[2] / 'ios/Tests/VelvetTests/handoff-fixture.mp4'
HLS = None
OVERVIEW = ('A quiet signal from a distant planet brings a crew of explorers together. '
            'They follow the stars through a universe of impossible discoveries, learning that the greatest adventure is finding their way home. ')

def timestamp(value):
    return datetime.fromtimestamp(value, timezone.utc).isoformat().replace('+00:00','Z')

def channels():
    return [dict(id=f'fixture-{i}',name='Velvet One' if i == 1 else f'Velvet {i}', number=str(i), group='Entertainment') for i in range(1,16)]

def live_session(channel):
    return dict(sessionId='tvosfixture', playbackPath='/live/streams/tvosfixture/index.m3u8',
                mimeType='application/vnd.apple.mpegurl', channel=channel, canPause=False, canSeek=False)

def item(tv=False, ident=None):
    return dict(id=ident or (999002 if tv else 999001), media_type='tv' if tv else 'movie',
                title='Velvet Test Movie', name='Velvet Test Series', overview=OVERVIEW * 4, poster_path='',
                original_language='en', first_air_date='2020-01-01', release_date='2020-01-01',
                vote_average=8.5, vote_count=1500, runtime=90, episode_run_time=[2],
                imdb_id='tt9990001', external_ids={'imdb_id': 'tt9990002' if tv else 'tt9990001'},
                status='Ended', genres=[{'id':878,'name':'Science Fiction'}],
                images={'logos':[]}, credits={'cast':[{'name':'Alex Example','character':'The Explorer'}]},
                seasons=[{'season_number': s, 'name':f'Season {s}', 'episode_count':3} for s in [1,2]])

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def send(self, data, status=200, kind='application/json'):
        if not isinstance(data, bytes): data = json.dumps(data).encode()
        self.send_response(status); self.send_header('Content-Type',kind)
        self.send_header('Content-Length',str(len(data))); self.end_headers()
        if self.command != 'HEAD':
            try: self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError): pass
    def do_HEAD(self): self.do_GET()
    def do_POST(self):
        raw=self.rfile.read(min(int(self.headers.get('Content-Length',0)), 1048576))
        body=json.loads(raw) if raw else {}
        path=urlsplit(self.path).path
        if path == '/live/tune':
            channel=next((c for c in channels() if c['id']==body.get('channelId')),None)
            return self.send(live_session(channel) if channel else {'error':'Unknown fixture channel'},200 if channel else 404)
        if path == '/sports/tune':
            return self.send(live_session(dict(id='fixture-game',name='Comets at Meteors',group='Live Sports')))
        if path in ['/categories/generate','/categories/queue']:
            return self.send(dict(id='fixture-category',title='Your Test Collection',items=[dict(mediaId=999001,type='movie',title='Velvet Test Movie',year='2020')]))
        self.send({})
    def do_DELETE(self): self.send({})
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/health': return self.send({'fixture':'velvet-tvos-ui'})
        if path.startswith('/metadata/tmdb/'):
            endpoint = path.removeprefix('/metadata/tmdb/')
            if re.fullmatch(r'tv/\d+/season/\d+', endpoint):
                season=int(endpoint.rsplit('/',1)[-1])
                return self.send({'episodes':[{'season_number':season,'episode_number':n,'name':f'The Journey {n}', 'runtime':2, 'air_date':'2020-01-01','overview':OVERVIEW} for n in range(1,4)]})
            if re.fullmatch(r'(movie|tv)/\d+',endpoint):
                result=item(endpoint.startswith('tv/'), int(endpoint.split('/')[1]))
                result['similar']={'results':[item(False,999003)]}
                return self.send(result)
            return self.send({'page':1,'total_pages':1,'results':[item('tv' in endpoint),item(True),item(False,999003)]})
        if path.startswith('/stream/') and path.endswith('.json'):
            return self.send({'streams':[{'url':f'http://127.0.0.1:{PORT}/media.mp4','title':'Velvet.Test.1080p.AAC-FIXTURE','name':'Local fixture','behaviorHints':{'bingeGroup':'fixture'}}]})
        if path == '/media.mp4':
            data=MEDIA.read_bytes(); start=0; end=len(data)-1
            match=re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range',''))
            if match:
                start=int(match[1]); end=min(int(match[2]) if match[2] else end,end)
                if start>end: return self.send(b'',416)
            self.send_response(206 if match else 200); self.send_header('Content-Type','video/mp4')
            self.send_header('Accept-Ranges','bytes'); self.send_header('Content-Length',str(end-start+1))
            if match: self.send_header('Content-Range',f'bytes {start}-{end}/{len(data)}')
            self.end_headers()
            if self.command!='HEAD':
                try: self.wfile.write(data[start:end+1])
                except (BrokenPipeError,ConnectionResetError): pass
            return
        if path == '/live/channels': return self.send({'enabled':True,'sourceName':'Local fixture','channels':channels()})
        if path == '/live/guide':
            start=int(time.time()//1800)*1800
            schedules=[]
            for channel in channels():
                programs=[dict(id=f"{channel['id']}-{n}",title=f"{'Now' if n==0 else 'Next' if n==1 else 'Later'} on {channel['name']}",
                               startTime=timestamp(start+(n*1800)),endTime=timestamp(start+((n+1)*1800)),
                               description=OVERVIEW,episodeTitle='The Journey',isLive=n==0)
                          for n in range(12)]
                schedules.append(dict(channelId=channel['id'],programs=programs))
            return self.send(dict(enabled=True,sourceName='Local fixture',updatedAt=timestamp(time.time()),channels=schedules))
        if path.startswith('/live/streams/tvosfixture/'):
            file=HLS / path.rsplit('/',1)[-1] if HLS else None
            if file and file.is_file() and file.suffix in ['.m3u8','.ts']:
                return self.send(file.read_bytes(),kind='application/vnd.apple.mpegurl' if file.suffix=='.m3u8' else 'video/mp2t')
            return self.send({'error':'Fixture media unavailable'},404)
        if path == '/sports/events':
            return self.send(dict(enabled=True,sourceName='Local fixture',sports=[dict(id='basketball',name='Basketball')],events=[dict(
                id='fixture-game',title='Comets at Meteors',sportId='basketball',sportName='Basketball',startTime=timestamp(time.time()-900),
                isLive=True,popular=True,sourceCount=1,homeTeam=dict(name='Meteors'),awayTeam=dict(name='Comets'))]))
        if path == '/sports/events/fixture-game/streams':
            return self.send(dict(eventId='fixture-game',streams=[dict(id='fixture-source',source='streamfree',streamNo=1,
                language='English',hd=True,embedUrl='https://strmfree.st/embed/basketball/fixture1080p')]))
        if 'categor' in path: return self.send({'categories':[]})
        return self.send({},404)

if __name__=='__main__':
    with tempfile.TemporaryDirectory(prefix='velvet-tvos-hls-') as media_directory:
        HLS=Path(media_directory)
        subprocess.run(['ffmpeg','-nostdin','-hide_banner','-loglevel','error','-i',str(MEDIA),'-c','copy',
                        '-f','hls','-hls_time','4','-hls_playlist_type','vod',str(HLS / 'index.m3u8')],check=True)
        print(f'Apple TV UI fixture on http://127.0.0.1:{PORT}',flush=True)
        ThreadingHTTPServer(('127.0.0.1',PORT),Handler).serve_forever()
