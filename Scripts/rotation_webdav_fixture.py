#!/usr/bin/env python3
"""Loopback-only WebDAV writer fixture; all media is the repository's authored demo."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, unquote, quote
from xml.sax.saxutils import escape
import base64
import hashlib
import json
import re
import threading
import uuid

ORIGINAL = (Path(__file__).resolve().parents[1] / 'Glide/Resources/demo0.mp4').read_bytes()
FILES, LOCKS = {}, {}
GUARD = threading.RLock()
AUTH = 'Basic ' + base64.b64encode(b'glide:rotation-fixture').decode()

def tag(data):
    return '"' + hashlib.sha256(data).hexdigest() + '"'

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body=b'', **headers):
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        for key, value in headers.items(): self.send_header(key.replace('_','-'),value)
        self.end_headers()
        if self.command != 'HEAD': self.wfile.write(body)

    def run_method(self):
        if self.headers.get('Authorization') != AUTH:
            return self.reply(401, WWW_Authenticate='Basic realm="Glide fixture"')
        path = unquote(urlsplit(self.path).path)
        mode = path.strip('/').split('/')[0].split('-')[0]
        with GUARD:
            if self.command == 'PROPFIND':
                self.rfile.read(int(self.headers.get('Content-Length','0')))
                folder=path.rstrip('/')+'/'
                presentation='-presentation-' in folder
                nested=presentation and folder.endswith('/Nested/')
                if not nested:FILES.setdefault(folder+'original.mp4',ORIGINAL)
                rows=[(folder,True)]+[(p,False) for p in FILES if p.startswith(folder) and '/' not in p[len(folder):]]
                if presentation and folder.rstrip('/').count('/')==1:rows+=[(folder+'Direct/',True),(folder+'Nested/',True)]
                if nested:rows.append((folder+'Deeper/',True))
                xml='<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
                for p,isdir in rows:
                    xml+='<d:response><d:href>'+escape(quote(p))+'</d:href><d:propstat><d:prop><d:displayname>'+escape(p.rstrip('/').split('/')[-1])+'</d:displayname><d:resourcetype>'+('<d:collection/>' if isdir else '')+'</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
                return self.reply(207,(xml+'</d:multistatus>').encode(),Content_Type='application/xml; charset=utf-8')
            if path.endswith('/original.mp4') and path not in FILES:
                FILES[path] = ORIGINAL
            current = FILES.get(path)
            if self.command == 'GET' and path.endswith('/__state'):
                prefix=path[:-len('__state')]
                return self.reply(200,json.dumps({'files':[x for x in FILES if x.startswith(prefix)],'locks':[x for x in LOCKS if x.startswith(prefix)]}).encode())
            condition = self.headers.get('If-Match')
            if condition and (current is None or condition != tag(current)):
                return self.reply(412)
            if self.command in ('GET','HEAD'):
                if current is None: return self.reply(404)
                if self.headers.get('Range'):
                    match=re.fullmatch(r'bytes=(\d+)-(\d*)',self.headers['Range'])
                    if not match:return self.reply(416)
                    start=int(match.group(1));end=int(match.group(2)) if match.group(2) else len(current)-1
                    if start>=len(current):return self.reply(416)
                    end=min(end,len(current)-1)
                    return self.reply(206,current[start:end+1],ETag=tag(current),Content_Range=f'bytes {start}-{end}/{len(current)}',Content_Type='video/mp4')
                return self.reply(200,current,ETag=tag(current),Content_Type='video/mp4')
            if self.command == 'PUT':
                if self.headers.get('If-None-Match') == '*' and current is not None:return self.reply(412)
                FILES[path]=self.rfile.read(int(self.headers.get('Content-Length','0')))
                return self.reply(201,ETag=tag(FILES[path]))
            if self.command == 'LOCK':
                self.rfile.read(int(self.headers.get('Content-Length','0')))
                if mode not in ('lock','brokenlock','brokenunsafe'):return self.reply(405)
                if path in LOCKS:return self.reply(423)
                token='opaquelocktoken:'+str(uuid.uuid4());LOCKS[path]=token
                return self.reply(200,Lock_Token='<'+token+'>',Timeout='Second-120')
            if self.command == 'UNLOCK':
                if self.headers.get('Lock-Token') == '<'+LOCKS.get(path,'')+'>':LOCKS.pop(path,None);return self.reply(204)
                return self.reply(409)
            if self.command == 'DELETE':
                if path in LOCKS:return self.reply(423)
                FILES.pop(path,None);return self.reply(204)
            if self.command in ('COPY','MOVE'):
                destination=unquote(urlsplit(self.headers.get('Destination','')).path)
                if current is None:return self.reply(404)
                if self.headers.get('Overwrite') == 'F' and destination in FILES:return self.reply(412)
                if self.command == 'MOVE' and mode == 'lock':
                    for locked in (path,destination):
                        if locked in LOCKS and LOCKS[locked] not in self.headers.get('If',''):return self.reply(423)
                if mode not in ('unsafe','brokenunsafe'):
                    for url,etag in re.findall(r'<([^>]+)>\s*\(\[([^]]+)\]\)',self.headers.get('If','')):
                        target=unquote(urlsplit(url).path)
                        if target not in FILES or tag(FILES[target]) != etag:return self.reply(412)
                if self.command == 'COPY' and mode == 'copyfail':return self.reply(507)
                FILES[destination]=current
                if self.command == 'MOVE':FILES.pop(path,None)
                if self.command == 'MOVE' and mode == 'lost' and path.endswith('.part'):return self.reply(500)
                return self.reply(201,ETag=tag(current))
            return self.reply(405)

    do_GET = do_HEAD = do_PUT = do_COPY = do_MOVE = do_LOCK = do_UNLOCK = do_DELETE = do_PROPFIND = run_method

if __name__ == '__main__':
    server=ThreadingHTTPServer(('127.0.0.1',8828),Handler)
    print('Original-media rotation WebDAV fixture listening on 127.0.0.1:8828',flush=True)
    server.serve_forever()
