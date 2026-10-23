#!/usr/bin/env python3
"""Original 1.6 integration samples; fake credentials only, loopback by default."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import argparse, json, re, subprocess, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument('--bind', default='127.0.0.1')
parser.add_argument('--port', type=int, default=8770)
args = parser.parse_args()
media = Path(__file__).resolve().parents[1] / 'Glide/Resources/demo0.mp4'
temporary = tempfile.TemporaryDirectory(prefix='glide160-hls-')
hls = Path(temporary.name)
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(media), '-c', 'copy', '-hls_time', '4', '-hls_list_size', '0', str(hls/'sample.m3u8')], check=True)
metrics = {'ranges': 0, 'authenticatedRanges': 0, 'segments': 0, 'rejected': 0}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def send(self, status, body=b'', mime='application/json', headers=None):
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        for key,value in (headers or {}).items(): self.send_header(key,value)
        self.end_headers()
        if self.command != 'HEAD':
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass
    def do_HEAD(self): self.do_GET()
    def auth(self): return 'fixture160-token' in self.headers.get('Authorization','') or parse_qs(urlsplit(self.path).query).get('api_key') == ['fixture160-token']
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        path = urlsplit(self.path).path
        if not self.auth(): return self.send(401)
        if path.endswith('/PlaybackInfo'):
            return self.send(200, json.dumps({'PlaySessionId':'fixture-session','MediaSources':[{'Id':'sample','Container':'mp4','SupportsDirectPlay':True,'SupportsDirectStream':False,'MediaStreams':[{'Index':0,'Type':'Video','Codec':'h264','Width':480,'Height':854}]}]}).encode())
        return self.send(204)
    def do_DELETE(self): self.send(204)
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/metrics': return self.send(200,json.dumps(metrics).encode())
        if path.startswith('/jellyfin/MediaSegments/'):
            if not self.auth(): return self.send(401)
            metrics['segments'] += 1
            item = path.split('/')[-1]
            if item == 'missing': return self.send(404)
            if item == 'delayed': time.sleep(1.2)
            return self.send(200,json.dumps({'Items':[{'Id':'intro-'+item,'ItemId':item,'Type':'Intro','StartTicks':0,'EndTicks':40000000},{'Id':'outro-'+item,'ItemId':item,'Type':'Outro','StartTicks':90000000,'EndTicks':120000000}]}).encode())
        if path == '/redirect.mp4': return self.send(302, headers={'Location':f'http://localhost:{args.port}/protected.mp4'})
        if path.startswith('/jellyfin/'):
            if not self.auth(): return self.send(401)
            if '/Videos/' in path: return self.video(media,'video/mp4')
            return self.send(200,b'{}')
        if path in ['/sample.mp4','/protected.mp4']:
            if path == '/protected.mp4' and self.headers.get('Authorization') != 'Bearer fixture160':
                metrics['rejected'] += 1
                return self.send(401)
            return self.video(media,'video/mp4')
        if path.startswith('/hls/'):
            name=Path(path).name
            target=hls/name
            if not target.is_file(): return self.send(404)
            return self.video(target,'application/vnd.apple.mpegurl' if target.suffix == '.m3u8' else 'video/mp2t')
        return self.send(404)
    def video(self, target, mime):
        data=target.read_bytes(); size=len(data)
        match=re.fullmatch(r'bytes=(\d+)-(\d*)',self.headers.get('Range',''))
        if not match: return self.send(200,data,mime,{'Accept-Ranges':'bytes'})
        start=int(match[1]); end=min(int(match[2]) if match[2] else size-1,size-1)
        if start >= size or end < start: return self.send(416,headers={'Content-Range':f'bytes */{size}'})
        metrics['ranges'] += 1
        if self.headers.get('Authorization') == 'Bearer fixture160': metrics['authenticatedRanges'] += 1
        return self.send(206,data[start:end+1],mime,{'Accept-Ranges':'bytes','Content-Range':f'bytes {start}-{end}/{size}'})

print(f'Glide 1.6 fixture http://{args.bind}:{args.port}',flush=True)
try: ThreadingHTTPServer((args.bind,args.port),Handler).serve_forever()
finally: temporary.cleanup()
