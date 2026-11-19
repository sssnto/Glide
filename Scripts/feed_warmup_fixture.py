#!/usr/bin/env python3
"""Authored loopback-only Jellyfin/4K fixture with repeatable startup latency."""
import argparse,json,re,subprocess,threading,time,uuid
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from urllib.parse import urlsplit

def prepare(root):
    root.mkdir(parents=True,exist_ok=True)
    for name,size,rate in [('direct','1280x720','2500k'),('segmented','3840x2160','14000k')]:
        target=root/(name+'.mp4')
        if not target.exists():
            subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i',f'testsrc2=size={size}:rate=24','-t','18','-c:v','libx264','-threads','2','-preset','ultrafast','-b:v',rate,'-g','48','-keyint_min','48','-sc_threshold','0','-pix_fmt','yuv420p','-movflags','+faststart',str(target)],check=True)
    hls=root/'hls';hls.mkdir(exist_ok=True)
    if not (hls/'media.m3u8').exists():
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(root/'segmented.mp4'),'-c','copy','-hls_time','2','-hls_list_size','0','-hls_playlist_type','vod','-hls_segment_filename',str(hls/'segment%03d.ts'),str(hls/'media.m3u8')],check=True)

def serve(root):
    lock=threading.Lock();metrics={};run_id=uuid.uuid4().hex[:12]
    def count(key,value=1):
        with lock:metrics[key]=metrics.get(key,0)+value
    class Handler(BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'
        def log_message(self,*args):pass
        def send(self,status,data=b'',mime='application/json',headers=None,delay=0):
            if delay:time.sleep(delay)
            self.send_response(status);self.send_header('Content-Length',str(len(data)));self.send_header('Content-Type',mime);self.send_header('Cache-Control','no-store')
            for k,v in (headers or {}).items():self.send_header(k,v)
            self.end_headers()
            if self.command!='HEAD':
                try:self.wfile.write(data)
                except (BrokenPipeError,ConnectionResetError):pass
        def do_HEAD(self):self.do_GET()
        def do_DELETE(self):
            count('unused_copy_stopped');self.send(204)
        def do_POST(self):
            raw=self.rfile.read(int(self.headers.get('Content-Length','0')))
            path=urlsplit(self.path).path;count(path)
            if path.endswith('/PlaybackInfo'):
                item=path.split('/')[-2];is4k=item.startswith('segmented')
                source={'Id':item+'-'+run_id+'-source','Container':'mp4','SupportsDirectPlay':not is4k,'SupportsDirectStream':True,'Bitrate':14_000_000 if is4k else 2_500_000,'MediaStreams':[{'Type':'Video','Index':0,'Codec':'h264','CodecTag':'avc1','Width':3840 if is4k else 1280,'Height':2160 if is4k else 720,'BitRate':14_000_000 if is4k else 2_500_000,'AverageFrameRate':24}], 'TranscodingUrl':'/hls/'+item+'-'+run_id+'/master.m3u8?VideoCodec=copy&AllowVideoStreamCopy=true&PlaySessionId='+uuid.uuid4().hex}
                self.send(200,json.dumps({'PlaySessionId':uuid.uuid4().hex,'MediaSources':[source]}).encode(),delay=.4)
            elif path.startswith('/Sessions'):self.send(204)
            else:self.send(404)
        def do_GET(self):
            path=urlsplit(self.path).path;count(path)
            if path=='/debug/metrics':return self.send(200,json.dumps(metrics).encode())
            if '/Items/' in path:
                item=path.rsplit('/',1)[1];is4k=item.startswith('segmented')
                source={'Id':item+'-'+run_id+'-source','Container':'mp4','MediaStreams':[{'Type':'Video','Index':0,'Codec':'h264','Width':3840 if is4k else 1280,'Height':2160 if is4k else 720}]}
                return self.send(200,json.dumps({'Id':item,'Name':item,'Type':'Video','MediaType':'Video','RunTimeTicks':180000000,'MediaSources':[source]}).encode())

            if path.startswith('/MediaSegments'):return self.send(200,b'{"Items":[]}')
            if path.startswith('/hls/') and path.endswith('/master.m3u8'):return self.send(200,b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=14000000,RESOLUTION=3840x2160\nmedia.m3u8\n','application/vnd.apple.mpegurl',delay=.25)
            if path.startswith('/hls/'):
                file=root/'hls'/Path(path).name
                if file.is_file():return self.send(200,file.read_bytes(),'application/vnd.apple.mpegurl' if file.suffix=='.m3u8' else 'video/mp2t',delay=.25)
                return self.send(404)
            if path.startswith('/Videos/') and path.endswith('/stream'):
                file=root/('segmented.mp4' if path.split('/')[2].startswith('segmented') else 'direct.mp4')
                data=file.read_bytes();request=self.headers.get('Range')
                headers={'Accept-Ranges':'bytes','ETag':'"'+file.stem+'-authored-v1"'}
                if not request:return self.send(200,data,'video/mp4',headers,delay=.7)
                m=re.fullmatch(r'bytes=(\d+)-(\d*)',request)
                if not m:return self.send(416)
                start=int(m[1]);end=min(int(m[2]) if m[2] else len(data)-1,len(data)-1)
                if start>=len(data):return self.send(416)
                headers['Content-Range']=f'bytes {start}-{end}/{len(data)}'
                count('range_bytes',end-start+1)
                return self.send(206,data[start:end+1],'video/mp4',headers,delay=.7)
            if path=='/ignore-range':return self.send(200,b'x'*1024,'video/mp4')
            return self.send(404)
    print(json.dumps({'ready':True,'port':8797,'authored':True}),flush=True)
    ThreadingHTTPServer(('127.0.0.1',8797),Handler).serve_forever()

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--root',type=Path,default=Path('.build/FeedWarmupFixture'));args=parser.parse_args()
    prepare(args.root);serve(args.root)
