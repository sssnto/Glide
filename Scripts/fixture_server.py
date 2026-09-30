#!/usr/bin/env python3
"""Local integration fixture, not a Jellyfin replacement. Never uses personal media or credentials."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlsplit, parse_qs
from pathlib import Path
import json, re, base64, subprocess, tempfile, os, time

resources = Path(__file__).resolve().parents[1] / 'Glide/Resources'
hls = Path(tempfile.mkdtemp(prefix='glide-hls-'))
for i in range(3):
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(resources/f'demo{i}.mp4'), '-c', 'copy', '-hls_time', '4', '-hls_list_size', '0', str(hls/f'demo{i}.m3u8')], check=True)
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(resources/'demo0.mp4'), '-frames:v', '1', str(hls/'poster.jpg')], check=True)
black_frame_fixture = os.environ.get('GLIDE_BLACK_FRAME_FIXTURE') == '1'
slow_direct_fixture = os.environ.get('GLIDE_SLOW_DIRECT_FIXTURE') == '1'
hls_master_fixture = os.environ.get('GLIDE_HLS_MASTER_FIXTURE') == '1'
if hls_master_fixture:
    # Model a server whose master advertises SDR/baseline, although the encoded
    # H.264 segments carry PQ/high. AVPlayer rejects the master with -12927;
    # the self-contained media playlist remains decodable.
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-stream_loop', '-1', '-i', str(resources/'demo0.mp4'), '-t', '60',
                    '-c:v', 'libx264', '-profile:v', 'high', '-pix_fmt', 'yuv420p',
                    '-color_trc', 'smpte2084', '-color_primaries', 'bt2020', '-colorspace', 'bt709',
                    '-c:a', 'aac', '-hls_time', '4', '-hls_list_size', '0', str(hls/'demo0.m3u8')], check=True)
if black_frame_fixture:
    # A valid audio clock without a decodable video frame.
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-t', '60', '-c:a', 'aac', str(hls/'broken.mp4')], check=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-stream_loop', '-1', '-i', str(resources/'demo0.mp4'), '-t', '60', '-c', 'copy', '-hls_time', '4', '-hls_list_size', '0', str(hls/'demo0.m3u8')], check=True)
prefix = '/mock/jellyfin'
def catalog_item(id, name, kind, **extra):
    return dict(Id=id, Name=name, Type=kind, Overview='A local fixture story for testing media details.', ProductionYear=2026, Genres=['Adventure'], Tags=['精彩 & 推荐'], CommunityRating=8.4, **extra)
film = catalog_item('demo0', 'Fixture Movie', 'Movie', RunTimeTicks=120000000, MediaSources=[dict(Id='demo0', Name='Original', Container='mp4', Size=(resources/'demo0.mp4').stat().st_size, MediaStreams=[dict(Index=1, Type='Audio', DisplayTitle='English DD_2.0 · Dolby Digital+ · Stereo · Original commentary track'), dict(Index=4, Type='Subtitle', DisplayTitle='中上英下 SUP_YYeTs 字幕 Chinese 默认 强制的 PGS Subtitle Extended Track')])])
download_fixture_id = os.environ.get('GLIDE_DOWNLOAD_FIXTURE_ID')
if download_fixture_id:
    film['Id'] = download_fixture_id
    film['Name'] = 'Offline Download Fixture'
broken = catalog_item('broken', 'Fixture Recovery', 'Movie', CommunityRatingOverride=9.5, RunTimeTicks=120000000, MediaSources=[dict(Id='broken',Container='mp4',Name='Original')])
broken['CommunityRating'] = 9.5
if black_frame_fixture or hls_master_fixture: broken['RunTimeTicks'] = 600000000
series = catalog_item('series', 'Fixture Show', 'Series')
episode_fixture = os.environ.get('GLIDE_EPISODE_FIXTURE') == '1'
seasons = [catalog_item('season2', 'Season 2', 'Season', IndexNumber=2), catalog_item('season1', 'Season 1', 'Season', IndexNumber=1)]
episodes = [catalog_item('demo2', 'Episode Ten', 'Episode', IndexNumber=10, ParentIndexNumber=1, RunTimeTicks=120000000), catalog_item('demo1', 'Episode Two', 'Episode', IndexNumber=2, ParentIndexNumber=1, RunTimeTicks=120000000)]
if episode_fixture:
    episodes += [catalog_item('demo0', 'Season Two Premiere', 'Episode', IndexNumber=1, ParentIndexNumber=2, RunTimeTicks=120000000)]
    for episode in episodes:
        episode.update(SeriesId='series', SeriesName='Fixture Show')
film['People'] = [dict(Id='person-a', Name='Fixture Person', Type='Actor', Role='Lead', PrimaryImageTag='portrait'), dict(Id='person-b', Name='Fixture Person', Type='Director'), dict(Name='Legacy Person', Type='Writer')]
series['People'] = film['People']
catalog = {x['Id']:x for x in [film, broken, series]+seasons+episodes}

metrics = {}
class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Never log query strings, authorization headers, or passwords.
        print(self.command, urlsplit(self.path).path, flush=True)
    def send(self, code, data=b'', mime='application/json', headers=None):
        self.send_response(code)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(data)))
        for key, value in (headers or {}).items(): self.send_header(key, value)
        self.end_headers()
        if self.command != 'HEAD':
            try: self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError): pass
    def jelly_auth(self):
        return 'fixture-token' in self.headers.get('Authorization', '') or parse_qs(urlsplit(self.path).query).get('api_key') == ['fixture-token']
    def dav_auth(self):
        return self.headers.get('Authorization') == 'Basic ' + base64.b64encode(b'demo:demo').decode()
    def do_POST(self):
        path = urlsplit(self.path).path
        data = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or '{}')
        if path == prefix+'/Users/AuthenticateByName':
            if data.get('Username') != 'demo' or data.get('Pw') != 'demo': return self.send(401)
            return self.send(200, json.dumps({'AccessToken':'fixture-token','User':{'Id':'fixture-user'}}).encode())
        if not self.jelly_auth(): return self.send(401)
        if path.endswith('/PlaybackInfo'):
            metrics[path] = metrics.get(path, 0) + 1
            item = path.split('/')[-2]
            assert data.get('DeviceProfile', {}).get('TranscodingProfiles'), 'Missing HLS profile'
            if data.get('AudioStreamIndex') == 1:
                assert data.get('SubtitleStreamIndex') == 4
                assert data.get('MediaSourceId') == 'demo0'
                assert {'Format':'srt','Method':'Encode'} in data['DeviceProfile']['SubtitleProfiles']
            force_transcode = data.get('EnableDirectPlay') is False
            if force_transcode and data.get('MaxStreamingBitrate') == 8000000:
                assert data.get('MaxStreamingBitrate') == 8000000
                assert data.get('AllowVideoStreamCopy') is False
                assert data['DeviceProfile'].get('CodecProfiles')
            source = {'Id': item, 'SupportsDirectPlay': not force_transcode}
            if force_transcode: source['TranscodingUrl'] = prefix+f'/streams/{"demo0" if item == "broken" else item}.m3u8?api_key=fixture-token'
            if hls_master_fixture and item == 'broken':
                source['SupportsDirectPlay'] = False
                source['SupportsDirectStream'] = False
                source['MediaStreams'] = [dict(Index=0, Type='Video', Codec='hevc', Profile='Main 10', BitDepth=10,
                                              Width=3840, Height=2160, VideoRangeType='DOVIWithHDR10', DvProfile=8)]
                source['TranscodingUrl'] = prefix+'/streams/broken/master.m3u8?api_key=fixture-token'
            return self.send(200, json.dumps({'MediaSources':[source], 'PlaySessionId':item+'-session'}).encode())
        if '/Sessions/Playing' in path:
            assert 'PositionTicks' in data
            return self.send(204)
        return self.send(404)
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/debug/metrics': return self.send(200, json.dumps(metrics).encode())
        metrics[path] = metrics.get(path,0)+1
        if hls_master_fixture and path == prefix+'/streams/broken/master.m3u8':
            master = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=8000000,VIDEO-RANGE=SDR,CODECS="avc1.424029,mp4a.40.2",RESOLUTION=480x854\n../demo0.m3u8?api_key=fixture-token\n'
            return self.send(200, master.encode(), 'application/vnd.apple.mpegurl')
        if path.startswith(prefix) and not '/streams/' in path and not self.jelly_auth(): return self.send(401)
        if path == prefix+'/Items/person-b/Images/Primary': return self.send(404)
        if path.endswith('/Images/Primary'):
            return self.send(200, (hls/'poster.jpg').read_bytes(), 'image/jpeg')
        if path == prefix+'/UserViews':
            return self.send(200, json.dumps({'Items':[{'Id':'fixture-library','Name':'Fixture Library','IsFolder':True,'Type':'CollectionFolder','CollectionType':'homevideos'}, {'Id':'fixture-movies','Name':'Fixture Movies','IsFolder':True,'Type':'CollectionFolder','CollectionType':'movies'}, {'Id':'fixture-shows','Name':'Fixture Shows','IsFolder':True,'Type':'CollectionFolder','CollectionType':'tvshows'}], 'TotalRecordCount':3}).encode())
        if path.endswith('/Similar'):
            q = parse_qs(urlsplit(self.path).query)
            assert q.get('UserId') == ['fixture-user']
            return self.send(200, json.dumps({'Items':[film, series], 'TotalRecordCount':2}).encode())
        if path == prefix+f'/Items/{film["Id"]}/Download':
            if download_fixture_id and metrics[path] == 1:
                # A successful HTTP response carrying an incomplete file must fail
                # integrity checks, then allow a clean retry of the complete MP4.
                data = (resources/'demo0.mp4').read_bytes()
                return self.send(200, data[:len(data)//2], 'video/mp4')
            return self.media(resources/'demo0.mp4')
        if path == prefix+'/Items/series':
            return self.send(200, json.dumps(series).encode())
        if path.startswith(prefix+'/Users/fixture-user/Items/'):
            if path.endswith('/series'): return self.send(404)
            item = catalog.get(path.split('/')[-1])
            return self.send(200, json.dumps(item).encode()) if item else self.send(404)
        if path == prefix+'/Items':
            q = parse_qs(urlsplit(self.path).query)
            if 'Tags' in q or 'Genres' in q:
                assert q.get('UserId') == ['fixture-user']
                assert q.get('Tags',q.get('Genres')) in [['精彩 & 推荐'],['Adventure']]
                assert 'Episode' not in q['IncludeItemTypes'][0]
                items = [film,series]; start = int(q.get('StartIndex',['0'])[0])
                return self.send(200,json.dumps({'Items':items[start:start+1], 'TotalRecordCount':2}).encode())
            if 'PersonIds' in q:
                assert q.get('UserId') == ['fixture-user']
                assert 'Episode' not in q.get('IncludeItemTypes',[''])[0]
                assert 'ParentId' not in q and 'SearchTerm' not in q
                assert q.get('Recursive') == ['true']
                if q['PersonIds'] == ['person-a']: items = [film, series]
                elif q['PersonIds'] == ['person-b']: items = []
                else: return self.send(400)
                start = int(q.get('StartIndex',['0'])[0])
                return self.send(200,json.dumps({'Items':items[start:start+1], 'TotalRecordCount':len(items)}).encode())
            parent = q.get('ParentId', [''])[0]
            if parent in ['fixture-movies','fixture-shows','series','season1','season2']:
                items = {'fixture-movies':[film,broken], 'fixture-shows':[series], 'series':seasons, 'season1':episodes, 'season2':[]}[parent]
                if episode_fixture:
                    if parent == 'series' and q.get('IncludeItemTypes') == ['Episode']: items = episodes
                    elif parent == 'season1': items = [e for e in episodes if e['ParentIndexNumber'] == 1]
                    elif parent == 'season2': items = [e for e in episodes if e['ParentIndexNumber'] == 2]
                expected = {'fixture-movies':'Movie','fixture-shows':'Series','series':'Season','season1':'Episode','season2':'Episode'}[parent]
                if episode_fixture and parent == 'series' and q.get('IncludeItemTypes') == ['Episode']: expected = 'Episode'
                if q.get('IncludeItemTypes') and q['IncludeItemTypes'] != [expected]: return self.send(400)
                sort = q.get('SortBy',['SortName'])[0].split(',')[0]
                items = sorted(items, key=lambda x: x.get('Name','') if sort == 'SortName' else x.get(sort,0), reverse=q.get('SortOrder') == ['Descending'])
                term = q.get('SearchTerm',[''])[0].casefold(); items = [x for x in items if term in x['Name'].casefold()]
                start = int(q.get('StartIndex',['0'])[0])
                return self.send(200,json.dumps({'Items':items[start:start+1], 'TotalRecordCount':len(items)}).encode())
            if parent not in ['fixture-library','fixture-parent','fixture-leaf']:
                return self.send(400)  # A global or out-of-scope query must fail this fixture.
            if q.get('MediaTypes') == ['Video'] or parent == 'fixture-leaf':
                items = [{'Id':f'demo{i}', 'Name':name, 'Type':'Video', 'MediaType':'Video', 'IsFolder':False, 'ProductionYear':2026, 'RunTimeTicks':120000000, 'UserData':{'PlaybackPositionTicks':0}} for i,name in enumerate(['Fixture A', 'Fixture B', 'Fixture C'])]
                if q.get('Recursive') != ['true'] and parent != 'fixture-leaf': items = []
                items.sort(key=lambda item: item['Name'], reverse=q.get('SortOrder') == ['Descending'])
                term = q.get('SearchTerm', [''])[0].casefold()
                items = [item for item in items if term in item['Name'].casefold()]
                start = int(q.get('StartIndex', ['0'])[0])
                # Intentionally force two pages, even if the client requests 200 rows.
                return self.send(200,json.dumps({'Items':items[start:start+2],'TotalRecordCount':len(items)}).encode())
            child = 'fixture-parent' if parent == 'fixture-library' else 'fixture-leaf'
            return self.send(200,json.dumps({'Items':[{'Id':child,'Name':'Nested directory','Type':'Folder','IsFolder':True}], 'TotalRecordCount':1}).encode())
        if '/Videos/' in path and path.endswith('/stream'):
            if download_fixture_id and f'/{download_fixture_id}/' in path: return self.media(resources/'demo0.mp4')
            if black_frame_fixture and '/broken/' in path: return self.media(hls/'broken.mp4')
            if slow_direct_fixture and '/broken/' in path:
                # Simulate a valid direct resource that never starts in time.
                time.sleep(18)
            return self.media(resources/(path.split('/')[-2]+'.mp4'))
        if '/streams/' in path:
            return self.media(hls/Path(path).name)
        if path == '/dav/season/demo0.mp4':
            if not self.dav_auth(): return self.send(401)
            return self.media(resources/'demo0.mp4')
        return self.send(404)
    def do_PROPFIND(self):
        if not self.dav_auth(): return self.send(401)
        xml = '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
        path = urlsplit(self.path).path
        entries = [('/dav/', 'Demo NAS', '<d:collection/>'),('/dav/season/', 'Season', '<d:collection/>')] if path == '/dav/' else [('/dav/season/', 'Season', '<d:collection/>'),('/dav/season/demo0.mp4', 'WebDAV 验证.mp4', '')]
        for href, name, kind in entries:
            xml += f'<d:response><d:href>{href}</d:href><d:propstat><d:prop><d:displayname>{name}</d:displayname><d:resourcetype>{kind}</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
        return self.send(207,(xml+'</d:multistatus>').encode(),'application/xml')
    def do_DELETE(self):
        if not self.jelly_auth(): return self.send(401)
        return self.send(204)
    def media(self,path):
        if not path.is_file(): return self.send(404)
        data=path.read_bytes(); size=len(data)
        mime={'.mp4':'video/mp4','.m3u8':'application/vnd.apple.mpegurl','.ts':'video/mp2t'}.get(path.suffix,'application/octet-stream')
        match=re.fullmatch(r'bytes=(\d+)-(\d*)',self.headers.get('Range',''))
        if match:
            start=int(match[1]); end=min(size-1, int(match[2]) if match[2] else size-1)
            if start >= size: return self.send(416)
            return self.send(206,data[start:end+1],mime,{'Content-Range':f'bytes {start}-{end}/{size}','Accept-Ranges':'bytes'})
        return self.send(200,data,mime,{'Accept-Ranges':'bytes'})
print('Fixture running on http://127.0.0.1:8768',flush=True)
try: ThreadingHTTPServer(('127.0.0.1',8768),Handler).serve_forever()
finally:
    import shutil
    shutil.rmtree(hls)
