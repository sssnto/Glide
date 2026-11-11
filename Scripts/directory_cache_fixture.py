#!/usr/bin/env python3
"""Loopback-only listing fixture. No private NAS data or credentials."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, unquote, quote
from xml.sax.saxutils import escape
import threading,time,base64,json

STATE={};GUARD=threading.Lock()
AUTH='Basic '+base64.b64encode(b'glide:directory-fixture').decode()
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def reply(self,status,body=b''):
        self.send_response(status);self.send_header('Content-Length',str(len(body)));self.end_headers()
        try:self.wfile.write(body)
        except (BrokenPipeError,ConnectionResetError):pass
    def do_POST(self):
        path=unquote(urlsplit(self.path).path)
        with GUARD:STATE[path.split('/')[1]]=True
        self.reply(204)
    def do_PROPFIND(self):
        if self.headers.get('Authorization')!=AUTH:return self.reply(401)
        self.rfile.read(int(self.headers.get('Content-Length','0')))
        path=unquote(urlsplit(self.path).path).rstrip('/')+'/'
        parts=path.strip('/').split('/');name=parts[-1];prefix=parts[0]
        if name=='Failed':return self.reply(500)
        if name=='Slow':time.sleep(2)
        rows=[]
        if len(parts)==1:
            rows=[(f'video-{i:04}.mp4',False) for i in range(645)]+[('Child/',True),('Empty/',True)]
            if prefix.startswith('failure'):rows=[('partial.mp4',False),('Failed/',True)]
            elif prefix.startswith('slow'):rows=[('partial.mp4',False),('Slow/',True)]
            elif STATE.get(prefix):rows.append(('new.mp4',False))
        elif name=='Child':rows=[(f'episode-{i}.mp4',False) for i in range(4)]
        xml='<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
        for leaf,isdir in rows:
            xml+='<d:response><d:href>'+escape(quote(path+leaf))+'</d:href><d:propstat><d:prop><d:displayname>'+escape(leaf.rstrip('/'))+'</d:displayname><d:resourcetype>'+('<d:collection/>' if isdir else '')+'</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
        self.reply(207,(xml+'</d:multistatus>').encode())
if __name__=='__main__':
    print('Directory cache fixture: 127.0.0.1:8829',flush=True)
    ThreadingHTTPServer(('127.0.0.1',8829),Handler).serve_forever()
