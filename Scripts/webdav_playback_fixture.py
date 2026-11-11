#!/usr/bin/env python3
"""Authored AVC High 10 / MKV playback fixtures. No user videos or credentials."""
import argparse
import base64
import json
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

AUTH = 'Basic ' + base64.b64encode(b'glide:playback-fixture').decode()

def generate(root):
    root.mkdir(parents=True, exist_ok=True)
    common = ['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=48000', '-t', '32', '-map', '0:v', '-map', '1:a', '-map', '2:a', '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '24', '-c:a', 'aac', '-b:a', '64k', '-metadata:s:a:0', 'language=eng', '-metadata:s:a:1', 'language=zho', '-movflags', '+faststart']
    for name, pixel, profile in [('native.mp4', 'yuv420p', 'high'), ('high10.mp4', 'yuv420p10le', 'high10')]:
        if not (root/name).exists(): subprocess.run(common + ['-pix_fmt', pixel, '-profile:v', profile, str(root/name)], check=True)
    if not (root/'compat.mkv').exists(): subprocess.run(['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', '-i', str(root/'high10.mp4'), '-map', '0', '-c', 'copy', str(root/'compat.mkv')], check=True)

def serve(root, host, port):
    binary = bytes(range(256)) * 8192
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *args): pass
        def reply(self, status, body=b'', **headers):
            self.send_response(status); self.send_header('Content-Length', str(len(body)))
            for key, value in headers.items(): self.send_header(key.replace('_', '-'), str(value))
            self.end_headers()
            if self.command != 'HEAD':
                try: self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError): pass
        def do_HEAD(self): self.do_GET()
        def do_GET(self):
            if self.headers.get('Authorization') != AUTH: return self.reply(401, WWW_Authenticate='Basic realm="Glide authored playback"')
            path = urlsplit(self.path).path
            if path == '/redirect.bin': return self.reply(302, Location=f'http://localhost:{port}/binary.bin')
            if path == '/same-origin.bin': return self.reply(302, Location='/binary.bin')
            if path in ['/binary.bin', '/bad-range.bin', '/ignored-range.bin']: data, mime = binary, 'application/octet-stream'
            elif path.lstrip('/') in ['native.mp4', 'high10.mp4', 'compat.mkv']:
                data = (root/path.lstrip('/')).read_bytes(); mime = 'video/mp4' if path.endswith('mp4') else 'video/x-matroska'
            else: return self.reply(404)
            requested = self.headers.get('Range')
            if not requested or path == '/ignored-range.bin': return self.reply(200, data, Content_Type=mime, Accept_Ranges='bytes')
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', requested)
            if not match: return self.reply(416, Content_Range=f'bytes */{len(data)}')
            a,b = match.groups()
            start, end = (int(a), min(int(b),len(data)-1) if b else len(data)-1) if a else (max(0,len(data)-int(b)),len(data)-1)
            if start >= len(data) or end < start: return self.reply(416, Content_Range=f'bytes */{len(data)}')
            actual_start = start + 1 if path == '/bad-range.bin' else start
            return self.reply(206, data[start:end+1], Content_Type=mime, Content_Range=f'bytes {actual_start}-{end}/{len(data)}', Accept_Ranges='bytes')
    print(json.dumps({'host':host,'port':port,'authoredSamples':3}), flush=True)
    ThreadingHTTPServer((host,port),Handler).serve_forever()

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path('/tmp/GlideWebDAVPlaybackFixtures'))
    parser.add_argument('--host',default='127.0.0.1');parser.add_argument('--port',type=int,default=8827)
    args=parser.parse_args();generate(args.root);serve(args.root,args.host,args.port)
