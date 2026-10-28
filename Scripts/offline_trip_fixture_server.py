#!/usr/bin/env python3
"""Authored offline-pack contract fixture; no private server accounts or media."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import json
import subprocess
import tempfile
import threading
import time
from generate_pgs_fixture import make_pgs

parser = argparse.ArgumentParser()
parser.add_argument('--bind', default='127.0.0.1')
parser.add_argument('--port', type=int, default=8799)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
temporary = tempfile.TemporaryDirectory(prefix='glide1120-')
folder = Path(temporary.name)
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(root/'Glide/Resources/demo1.mp4'), '-c', 'copy', str(folder/'sample.mkv')], check=True)
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(root/'Glide/Resources/demo0.mp4'), '-frames:v', '1', str(folder/'poster.jpg')], check=True)
font = root/'Glide/Resources/SubtitleFonts/GlideSubtitleFallback.otf'
pgs = make_pgs(font, 480, 854)
media = {'mp4': root/'Glide/Resources/demo0.mp4', 'mkv': folder/'sample.mkv', 'retry': root/'Glide/Resources/demo2.mp4', 'slow': root/'Glide/Resources/demo0.mp4', 'pgs': root/'Glide/Resources/demo2.mp4', 'unavailable': root/'Glide/Resources/demo0.mp4'}
lock = threading.Lock()
metrics = {'requests': 0, 'downloads': 0, 'retries': 0, 'requestsAfterFreeze': 0, 'frozen': False}
ass = '''[Script Info]
ScriptType: v4.00+
PlayResX: 480
PlayResY: 854
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Glide Subtitle Fallback,28,&H0000FFFF,&H0000FFFF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,20,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:11.00,Default,,0,0,0,,{\\fad(200,200)\\1c&H0000FF&}原创离线字幕 Original offline ASS
'''.encode()

def item(identifier):
    path = media[identifier]
    subtitle = {'Index': 2, 'Type': 'Subtitle', 'Codec': 'ass' if identifier == 'mp4' else 'pgssub' if identifier == 'pgs' else 'srt', 'Language': 'zho', 'IsDefault': True, 'DisplayTitle': '原创离线字幕'}
    return {'Id': identifier, 'Name': '行程样例 '+identifier.upper(), 'Type': 'Episode' if identifier in ['mp4', 'mkv'] else 'Movie', 'SeriesId': 'authored-show', 'SeriesName': '原创旅程', 'ParentIndexNumber': 1, 'IndexNumber': 1 if identifier == 'mp4' else 2, 'Overview': '仅使用项目原创视频的离线资料验证。', 'RunTimeTicks': 120000000, 'Chapters': [{'Name': '开始', 'StartPositionTicks': 0}, {'Name': '后半段', 'StartPositionTicks': 60000000}], 'MediaSources': [{'Id': identifier, 'Container': path.suffix[1:], 'Size': path.stat().st_size, 'MediaStreams': [{'Index': 0, 'Type': 'Video', 'Codec': 'h264', 'Width': 480, 'Height': 854}, subtitle], 'MediaAttachments': [{'Index': 0, 'FileName': font.name, 'Codec': 'otf', 'MimeType': 'font/otf'}] if identifier == 'mp4' else []}]}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def send(self, status, data=b'', mime='application/json'):
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/metrics': return self.send(200, json.dumps(metrics).encode())
        if path == '/control/freeze':
            with lock: metrics['frozen'] = True; metrics['requestsAfterFreeze'] = 0
            return self.send(200, b'{}')
        if path == '/control/reset':
            with lock: metrics.update(requests=0, downloads=0, retries=0, requestsAfterFreeze=0, frozen=False)
            return self.send(200, b'{}')
        with lock:
            metrics['requests'] += 1
            if metrics['frozen']: metrics['requestsAfterFreeze'] += 1
        if metrics['frozen']: return self.send(503)
        if 'offline1120-token' not in self.headers.get('Authorization', ''): return self.send(401)
        parts = path.strip('/').split('/')
        if parts[-1] == 'Items' and parts[0] in ['jellyfin', 'emby']:
            blocked = parse_qs(urlsplit(self.path).query).get('ParentId') == ['library-blocked']
            values = [dict(item(name), MediaType='Video', IsFolder=False) for name in (['unavailable', 'mkv'] if blocked else ['mp4', 'mkv'])]
            if blocked:
                values[0].update(Type='Episode', IndexNumber=1)
                values[0]['MediaSources'][0]['Size'] = 0
            return self.send(200, json.dumps({'Items': values, 'TotalRecordCount': len(values)}).encode())
        identifier = next((part for part in parts if part in media), None)
        if not identifier: return self.send(404)
        if 'Download' in parts:
            with lock:
                metrics['downloads'] += 1
                if identifier == 'retry': metrics['retries'] += 1
                attempt = metrics['retries']
            if identifier == 'retry' and attempt == 1: return self.send(503)
            file = media[identifier]
            self.send_response(200)
            self.send_header('Content-Type', 'video/x-matroska' if file.suffix == '.mkv' else 'video/mp4')
            self.send_header('Content-Length', str(file.stat().st_size))
            self.end_headers()
            try:
                with file.open('rb') as handle:
                    while chunk := handle.read(8192):
                        self.wfile.write(chunk); self.wfile.flush()
                        if identifier == 'slow': time.sleep(0.08)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if 'Subtitles' in parts:
            if path.endswith('.pgssub'): return self.send(200, pgs, 'application/octet-stream')
            return self.send(200, ass if path.endswith('.ass') else b'1\n00:00:00,000 --> 00:00:11,000\nOriginal offline subtitle\n', 'text/plain')
        if 'Attachments' in parts: return self.send(200, font.read_bytes(), 'font/otf')
        if 'Images' in parts: return self.send(200, (folder/'poster.jpg').read_bytes(), 'image/jpeg')
        detail = item(identifier)
        if identifier == 'unavailable':
            detail.update(Type='Episode', IndexNumber=1)
            detail['MediaSources'][0]['Size'] = 0
        return self.send(200, json.dumps(detail).encode())

print(f'Offline 1.12 contract fixture: http://{args.bind}:{args.port}', flush=True)
try: ThreadingHTTPServer((args.bind, args.port), Handler).serve_forever()
finally: temporary.cleanup()
