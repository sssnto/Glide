#!/usr/bin/env python3
"""Original video only; authenticated Jellyfin/Emby contract, pagination and failure fixture."""
import argparse, json, time, threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
p=argparse.ArgumentParser();p.add_argument('--bind',default='127.0.0.1');p.add_argument('--port',type=int,default=8813);a=p.parse_args()
root=Path(__file__).resolve().parents[1]
clips=[root/f'Glide/Resources/demo{i}.mp4' for i in range(3)]
lock=threading.Lock();metrics={'searches':0,'playback':[],'streams':[],'frozen':False,'afterFreeze':0,'removedV2':False}
def source(identifier,name,clip=0):
    return dict(Id=identifier,Name=name,Container='mp4',Size=clips[clip].stat().st_size,SupportsDirectPlay=True,SupportsDirectStream=True,MediaStreams=[dict(Index=0,Type='Video',Codec='h264',Width=480,Height=854,BitDepth=8)])
def item(identifier):
    value=dict(Id=identifier,Name='原创海岸',Type='Movie',MediaType='Video',IsFolder=False,ProductionYear=2026,Overview='Glide 原创动态风景，验证跨来源聚合和实际文件选择。',ProviderIds={'Tmdb':'113001'},RunTimeTicks=120000000,MediaSources=[source('v1','山野版',0),source('v2','海岸版',1)])
    if identifier=='emby-film':value.update(MediaSources=[source('e1','另一来源 · 夜色版',2)])
    elif identifier=='remake':value.update(ProductionYear=2025,ProviderIds={'Tmdb':'113002'},MediaSources=[source('v1','同名另一作品')])
    elif identifier in ['unknown','emby-unknown']:value.update(Name='无标识同名',ProviderIds={},MediaSources=[source('v1','原文件')])
    elif identifier=='show':value.update(Name='原创旅程',Type='Series',IsFolder=True,ProviderIds={'Tmdb':'113010'},MediaSources=[])
    elif identifier=='season1':value.update(Name='第 1 季',Type='Season',IsFolder=True,IndexNumber=1,ProviderIds={},MediaSources=[])
    elif identifier in ['episode1','episode2']:
        value.update(Name='原创旅程 · 第 '+identifier[-1]+' 集',Type='Episode',SeriesId='show',SeriesName='原创旅程',IndexNumber=int(identifier[-1]),ParentIndexNumber=1,ProviderIds={'Tmdb':'11302'+identifier[-1]},MediaSources=[source('v1','原文件')])
    elif identifier.startswith('page-'):value.update(Name='分页样例 '+identifier[5:],ProviderIds={'Tmdb':str(120000+int(identifier[5:]))},MediaSources=[source('v1','原文件')])
    if metrics['removedV2']:value['MediaSources']=[s for s in value['MediaSources'] if s['Id']!='v2']
    return value
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*_):pass
    def send(self,status,data=b'',mime='application/json'):
        self.send_response(status);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(len(data)));self.end_headers()
        try:
            if self.command!='HEAD':self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError):pass
    def auth(self,q):return 'unified1130-token' in self.headers.get('Authorization','') or q.get('api_key')==['unified1130-token']
    def do_HEAD(self):self.do_GET()
    def do_GET(self):
        u=urlsplit(self.path);q=parse_qs(u.query);path=u.path;parts=path.strip('/').split('/')
        if path=='/metrics':return self.send(200,json.dumps(metrics).encode())
        if path=='/control/reset':
            with lock:metrics.update(searches=0,playback=[],streams=[],frozen=False,afterFreeze=0,removedV2=False)
            return self.send(200,b'{}')
        if path=='/control/remove-v2':
            with lock:metrics['removedV2']=True
            return self.send(200,b'{}')
        if path=='/control/freeze':
            with lock:metrics['frozen']=True;metrics['afterFreeze']=0
            return self.send(200,b'{}')
        if metrics['frozen']:
            with lock:metrics['afterFreeze']+=1
            return self.send(503)
        if not self.auth(q):return self.send(401)
        if parts[0]=='slow':time.sleep(3);return self.send(503)
        if 'Images' in parts:return self.send(200,(root/'Glide/Assets.xcassets/AppIcon.appiconset/AppIcon.png').read_bytes(),'image/png')
        if parts[-1]=='MediaSegments':return self.send(200,b'{"Items":[]}')
        if parts[-1]=='Items':
            with lock:metrics['searches']+=1
            parent=q.get('ParentId',[''])[0];types=q.get('IncludeItemTypes',[''])[0]
            if parent=='show':names=['episode1','episode2'] if 'Episode' in types or q.get('MediaTypes')==['Video'] else ['season1']
            elif parent=='season1':names=['episode1','episode2']
            elif q.get('SearchTerm')==['分页']:names=[f'page-{i:03}' for i in range(75)]
            else:names=['shared','remake','unknown','show'] if parts[0]=='jellyfin' else ['emby-film','emby-unknown','show']
            values=[item(n) for n in names]
            term=q.get('SearchTerm',[''])[0].casefold()
            values=[x for x in values if term in x['Name'].casefold()]
            cursor=int(q.get('StartIndex',['0'])[0]);limit=20 if term=='分页' else int(q.get('Limit',['60'])[0])
            return self.send(200,json.dumps(dict(Items=values[cursor:cursor+limit],TotalRecordCount=len(values)),ensure_ascii=False).encode())
        if 'Download' in parts:
            identifier=parts[parts.index('Items')+1];clip=2 if identifier=='emby-film' else 0
            return self.media(clips[clip])
        if 'Videos' in parts and parts[-1].lower().startswith('stream'):
            selected=q.get('MediaSourceId',q.get('mediaSourceId',['v1']))[0]
            with lock:metrics['streams'].append(selected)
            return self.media(clips[1 if selected=='v2' else 2 if selected=='e1' else 0])
        if 'Items' in parts and parts.index('Items')+1<len(parts):return self.send(200,json.dumps(item(parts[parts.index('Items')+1]),ensure_ascii=False).encode())
        return self.send(404)
    def do_POST(self):
        u=urlsplit(self.path);q=parse_qs(u.query)
        raw=self.rfile.read(int(self.headers.get('Content-Length','0')));body=json.loads(raw or b'{}')
        if not self.auth(q):return self.send(401)
        if u.path.endswith('/PlaybackInfo'):
            identifier=u.path.split('/')[-2];detail=item(identifier);selected=body.get('MediaSourceId')
            with lock:metrics['playback'].append(selected)
            sources=[s for s in detail['MediaSources'] if selected is None or s['Id']==selected]
            return self.send(200,json.dumps(dict(MediaSources=sources,PlaySessionId='unified1130-session')).encode())
        return self.send(204)
    def do_DELETE(self):return self.send(204)
    def media(self,path):
        data=path.read_bytes();size=len(data);start=0;end=size-1;status=200
        value=self.headers.get('Range','')
        if value.startswith('bytes='):
            try:
                x,y=value[6:].split('-',1);start=int(x or 0);end=min(int(y) if y else size-1,size-1);status=206
            except ValueError:return self.send(416)
        if start>=size or start>end:return self.send(416)
        payload=data[start:end+1];self.send_response(status);self.send_header('Content-Type','video/mp4');self.send_header('Accept-Ranges','bytes');self.send_header('Content-Length',str(len(payload)))
        if status==206:self.send_header('Content-Range',f'bytes {start}-{end}/{size}')
        self.end_headers()
        try:
            if self.command!='HEAD':self.wfile.write(payload)
        except (BrokenPipeError,ConnectionResetError):pass
print(f'Unified library authored fixture on {a.bind}:{a.port}',flush=True)
ThreadingHTTPServer((a.bind,a.port),Handler).serve_forever()
