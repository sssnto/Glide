#!/usr/bin/env python3
"""Local integration fixture, not a Jellyfin replacement. Never uses personal media or credentials."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlsplit, parse_qs
from pathlib import Path
import json, re, base64, subprocess, tempfile, os, time, shutil, threading

resources = Path(__file__).resolve().parents[1] / 'Glide/Resources'
hls = Path(tempfile.mkdtemp(prefix='glide-hls-'))
for i in range(3):
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(resources/f'demo{i}.mp4'), '-c', 'copy', '-hls_time', '4', '-hls_list_size', '0', str(hls/f'demo{i}.m3u8')], check=True)
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(resources/'demo0.mp4'), '-frames:v', '1', str(hls/'poster.jpg')], check=True)
black_frame_fixture = os.environ.get('GLIDE_BLACK_FRAME_FIXTURE') == '1'
slow_direct_fixture = os.environ.get('GLIDE_SLOW_DIRECT_FIXTURE') == '1'
buffering_fixture = os.environ.get('GLIDE_BUFFERING_FIXTURE') == '1'
four_k_file = Path(os.environ['GLIDE_4K_FIXTURE']) if os.environ.get('GLIDE_4K_FIXTURE') else None
four_k_info = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(four_k_file)])) if four_k_file else None
four_k_delays = {}
four_k_lock = threading.Lock()
four_k_transport = os.environ.get('GLIDE_4K_TRANSPORT_FIXTURE') == '1'
transport_menu_fixture = os.environ.get('GLIDE_TRANSPORT_MENU_FIXTURE') == '1'
design_fixture = os.environ.get('GLIDE_DESIGN_FIXTURE') == '1'
subtitle_switch_fixture = os.environ.get('GLIDE_SUBTITLE_SWITCH_FIXTURE') == '1'
if four_k_transport:
    assert four_k_file, 'Transport fixture requires the authored 4K MP4'
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(four_k_file), '-c', 'copy',
                    '-hls_time', '2', '-hls_list_size', '0', '-hls_segment_type', 'fmp4',
                    '-hls_fmp4_init_filename', 'fourk-init.mp4', str(hls/'fourk.m3u8')], check=True)
hls_master_fixture = os.environ.get('GLIDE_HLS_MASTER_FIXTURE') == '1'
if hls_master_fixture:
    sdr = hls/'sdr'
    sdr.mkdir()
    for asset in hls.glob('demo0*'):
        shutil.copy2(asset, sdr/asset.name)
    # Model a server whose master advertises SDR/baseline, although the encoded
    # H.264 segments carry PQ/high. Some native runtimes reject this with
    # -12927; others decode it. The client must inspect the actual output.
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-stream_loop', '-1', '-i', str(resources/'demo0.mp4'), '-t', '60',
                    '-c:v', 'libx264', '-profile:v', 'high', '-pix_fmt', 'yuv420p',
                    '-color_trc', 'smpte2084', '-color_primaries', 'bt2020', '-colorspace', 'bt709',
                    '-c:a', 'aac', '-hls_time', '4', '-hls_list_size', '0', str(hls/'demo0.m3u8')], check=True)
if black_frame_fixture:
    # A valid audio clock without a decodable video frame.
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-t', '60', '-c:a', 'aac', str(hls/'broken.mp4')], check=True)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-stream_loop', '-1', '-i', str(resources/'demo0.mp4'), '-t', '60', '-c', 'copy', '-hls_time', '4', '-hls_list_size', '0', str(hls/'demo0.m3u8')], check=True)
if buffering_fixture:
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-stream_loop', '-1', '-i', str(resources/'demo0.mp4'), '-t', '90',
                    '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-r', '24', '-g', '96',
                    '-force_key_frames', 'expr:gte(t,n_forced*4)', '-c:a', 'aac',
                    '-hls_time', '4', '-hls_list_size', '0', str(hls/'buffered.m3u8')], check=True)
    # Stream-copying the original GOP produced alternating 10.4 / 1.6 second
    # segments, masking most of the intended post-frame stall.
    durations = [float(line.split(':')[1].rstrip(',')) for line in (hls/'buffered.m3u8').read_text().splitlines() if line.startswith('#EXTINF:')]
    assert len(durations) > 4 and all(abs(duration - 4) < 0.05 for duration in durations[:-1]), 'Buffer fixture needs actual four-second segments'
prefix = '/mock/jellyfin'
def catalog_item(id, name, kind, **extra):
    return dict(Id=id, Name=name, Type=kind, Overview='A local fixture story for testing media details.', ProductionYear=2026, Genres=['Adventure'], Tags=['精彩 & 推荐'], CommunityRating=8.4, **extra)
film = catalog_item('demo0', 'Fixture Movie', 'Movie', RunTimeTicks=120000000, MediaSources=[dict(Id='demo0', Name='Original', Container='mp4', Size=(resources/'demo0.mp4').stat().st_size, MediaStreams=[dict(Index=1, Type='Audio', DisplayTitle='English DD_2.0 · Dolby Digital+ · Stereo · Original commentary track'), dict(Index=4, Type='Subtitle', DisplayTitle='中上英下 SUP_YYeTs 字幕 Chinese 默认 强制的 PGS Subtitle Extended Track')])])
switch_pgs = b""
switch_subtitles = {4: '第一路中文字幕', 5: 'English fixture subtitles', 6: '第二路中文字幕'}
if subtitle_switch_fixture:
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-stream_loop', '-1', '-i', str(resources/'demo0.mp4'),
                    '-t', '120', '-c', 'copy', '-hls_time', '4', '-hls_list_size', '0', str(hls/'demo0.m3u8')], check=True)
    for audio_index, frequency in [(1, 440), (2, 880)]:
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-stream_loop', '-1', '-i', str(resources/'demo0.mp4'),
                        '-f', 'lavfi', '-i', f'sine=frequency={frequency}:sample_rate=48000', '-t', '120',
                        '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'copy', '-c:a', 'aac', '-threads', '1',
                        '-hls_time', '4', '-hls_list_size', '0', str(hls/f'audio{audio_index}.m3u8')], check=True)
    film['RunTimeTicks'] = 1_200_000_000
    measured = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', str(resources/'demo0.mp4')]))
    video = next(s for s in measured['streams'] if s['codec_type'] == 'video')
    from generate_pgs_fixture import make_pgs
    switch_pgs = make_pgs(resources/'SubtitleFonts/GlideSubtitleFallback.otf', video['width'], video['height'])
    film['MediaSources'][0]['MediaStreams'] = [dict(Index=0, Type='Video', Codec=video['codec_name'], Width=video['width'], Height=video['height'])] + [dict(Index=i, Type='Audio', Codec='aac', Language='eng' if i == 1 else 'zho', DisplayTitle='English 440 Hz' if i == 1 else '中文 880 Hz', IsDefault=i == 1) for i in [1, 2]] + [
        dict(Index=i, Type='Subtitle', Codec='subrip', Language='eng' if i == 5 else 'zho', DisplayTitle=title, IsDefault=i == 4)
        for i, title in switch_subtitles.items()] + [dict(Index=7, Type='Subtitle', Codec='pgssub', Language='zho', DisplayTitle='图形字幕目录样例')]
download_fixture_id = os.environ.get('GLIDE_DOWNLOAD_FIXTURE_ID')
if download_fixture_id:
    film['Id'] = download_fixture_id
    film['Name'] = 'Offline Download Fixture'
broken = catalog_item('broken', 'Fixture Recovery', 'Movie', CommunityRatingOverride=9.5, RunTimeTicks=120000000, MediaSources=[dict(Id='broken',Container='mp4',Name='Original')])
broken['CommunityRating'] = 9.5
if black_frame_fixture or hls_master_fixture: broken['RunTimeTicks'] = 600000000
if buffering_fixture:
    # A fresh identity avoids learned decoder-recovery routes from other fixtures.
    broken.update(Id='buffered', Name='Fixture Buffering', RunTimeTicks=900000000)
if four_k_file:
    broken.update(Id='buffer4k', Name='Fixture 4K Buffering', RunTimeTicks=int(float(four_k_info['format']['duration']) * 10_000_000))
    broken['MediaSources'][0].update(Id='buffer4k', Size=four_k_file.stat().st_size)
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
design_films = []
if design_fixture:
    # Authored demo video metadata, measured with ffprobe; no fabricated 4K/HDR badges.
    film['MediaSources'][0]['MediaStreams'].insert(0, dict(Index=0, Type='Video', Codec='h264', Profile='High', BitDepth=8, Width=480, Height=854, AverageFrameRate=24, BitRate=36150))
    names = ['山海之间', '雨后的城市', '穿过峡谷的风', '森林深处的一天', '海岸线上的日出', '漫长的夏日午后', '雪山与远方', '旅途中的光影', '无声的夜空', '重返故乡', '沿着河流', '城市的另一面']
    for index in range(36):
        sample = json.loads(json.dumps(film))
        sample.update(Id=f'design-{index:02d}', Name=f'{names[index % len(names)]} · {index + 1:02d}', Overview='Glide 原创合成样例，用于验证片库密度、长片名、元数据分层与海报加载稳定性。')
        design_films.append(sample)
catalog = {x['Id']:x for x in [film, broken, series]+seasons+episodes+design_films}

navigation_fixture = os.environ.get('GLIDE_NAVIGATION_FIXTURE') == '1'
if navigation_fixture:
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(resources/'demo0.mp4'), '-vf', 'fps=1/2,scale=160:90,tile=4x3', '-frames:v', '1', str(hls/'navigation.jpg')], check=True)
    film['MediaSources'][0]['Size'] = (resources/'demo0.mp4').stat().st_size
    film['Chapters'] = [dict(Name='原创开场', StartPositionTicks=0), dict(Name='原创后半段', StartPositionTicks=60000000)]
    film['Trickplay'] = {'demo0': {'160': dict(Width=160, Height=90, TileWidth=4, TileHeight=3, ThumbnailCount=6, Interval=2000)}}

metrics = {'buffering_fixture': int(buffering_fixture), 'four_k_fixture': int(four_k_file is not None), 'design_fixture': int(design_fixture), 'subtitle_switch_fixture': int(subtitle_switch_fixture)}
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
            if subtitle_switch_fixture and item == 'demo0':
                selected = data.get('SubtitleStreamIndex', 4)
                assert selected in [-1, 4, 5, 6, 7]
                audio_index = data.get('AudioStreamIndex', 1)
                assert audio_index in [1, 2]
                metrics['selected_audio_index'] = audio_index
                source = dict(film['MediaSources'][0], SupportsDirectPlay=False, SupportsDirectStream=True,
                    DefaultAudioStreamIndex=audio_index, TranscodingUrl=prefix+f'/streams/audio{audio_index}.m3u8?api_key=fixture-token&VideoCodec=copy&AudioStreamIndex={audio_index}&SubtitleStreamIndex={selected}&SubtitleMethod={"Drop" if selected == -1 else "External"}')
                return self.send(200, json.dumps(dict(MediaSources=[source], PlaySessionId='subtitle-switch-session')).encode())
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
            source = {'Id': item, 'SupportsDirectPlay': not force_transcode, 'Path': f'/fixture/家庭视频/{item}.mp4'}
            if design_fixture and item.startswith('design-'): source['DirectStreamUrl'] = prefix+'/Videos/demo0/stream'
            if force_transcode: source['TranscodingUrl'] = prefix+f'/streams/{"demo0" if item == "broken" else item}.m3u8?api_key=fixture-token'
            if transport_menu_fixture and item == 'demo0':
                source['SupportsDirectStream'] = False
                if force_transcode:
                    assert data.get('EnableTranscoding') is False
                    assert data.get('AllowVideoStreamCopy') is True
                    key = 'menu_copy_negotiations'
                    metrics[key] = metrics.get(key, 0) + 1
                    if metrics[key] == 1: source.pop('TranscodingUrl', None)
                    else: source['TranscodingUrl'] = prefix+'/streams/demo0.m3u8?api_key=fixture-token&VideoCodec=copy&AudioCodec=copy'
            if buffering_fixture and item == 'buffered':
                source.update(Id=broken['MediaSources'][0]['Id'], SupportsDirectPlay=False, SupportsDirectStream=True,
                              TranscodingUrl=prefix+'/streams/buffered.m3u8?api_key=fixture-token&VideoCodec=copy&AudioCodec=copy')
            if four_k_file and item == 'buffer4k':
                video = next(s for s in four_k_info['streams'] if s['codec_type'] == 'video')
                numerator, denominator = map(int, video['avg_frame_rate'].split('/'))
                source.update(Id=data.get('MediaSourceId') or 'buffer4k-' + str(metrics[path]), Container='mp4', SupportsDirectStream=four_k_transport, Bitrate=int(four_k_info['format']['bit_rate']),
                    MediaStreams=[dict(Index=0, Type='Video', Codec='h264', Profile='Main', CodecTag='avc1', BitDepth=8,
                        Width=video['width'], Height=video['height'], Level=52, VideoRangeType='SDR',
                        ColorTransfer='bt709', ColorPrimaries='bt709', ColorSpace='bt709', BitRate=int(video['bit_rate']), AverageFrameRate=numerator/denominator)])
                if four_k_transport and force_transcode:
                    assert data.get('EnableTranscoding') is False, 'Transport recovery must not request video encoding'
                    assert data.get('AllowVideoStreamCopy') is True
                    assert data.get('MaxStreamingBitrate') == 200000000
                    metrics['four_k_copy_negotiations'] = metrics.get('four_k_copy_negotiations', 0) + 1
                    trial_key = 'copy_' + source['Id']
                    metrics[trial_key] = metrics.get(trial_key, 0) + 1
                    source.update(TranscodingUrl=prefix+'/streams/fourk.m3u8?api_key=fixture-token&VideoCodec=copy&AudioCodec=copy')
                    if source['Id'] == 'buffer4k-preferred': source['TranscodingUrl'] = prefix+'/streams/fourk.m3u8?api_key=fixture-token&VideoCodec=h264,hevc&AudioCodec=copy&AllowVideoStreamCopy=true'
                    if source['Id'] == 'buffer4k-reject' and metrics[trial_key] == 1: source.pop('TranscodingUrl')
                    if source['Id'] == 'buffer4k-bad-hls': source.update(TranscodingUrl=prefix+'/streams/missing.m3u8?api_key=fixture-token&VideoCodec=copy&AudioCodec=copy')
                    if source['Id'] == 'buffer4k-encode': source.update(TranscodingUrl=prefix+'/streams/encoded.m3u8?api_key=fixture-token&VideoCodec=h264&AudioCodec=aac&AllowVideoStreamCopy=false')
                if four_k_transport and source['Id'] in ('buffer4k-preferred', 'buffer4k-reject', 'buffer4k-encode'):
                    source['SupportsDirectStream'] = False
                if four_k_transport and not force_transcode:
                    if source['Id'] in ('buffer4k-manual', 'buffer4k-unknown'): source.pop('SupportsDirectStream')
                    # Missing load metadata leaves the manual trial available.
                    if source['Id'] == 'buffer4k-manual':
                        source.pop('MediaStreams'); source.pop('Bitrate')
                if source['Id'] == 'buffer4k-no-remux' or (not four_k_transport and force_transcode):
                    source['SupportsDirectStream'] = False
                    source.pop('TranscodingUrl', None)
            if hls_master_fixture and item == 'broken':
                profiles = data['DeviceProfile']['CodecProfiles']
                avc = next(profile for profile in profiles if profile['Codec'] == 'h264')
                assert any(c['Property'] == 'VideoRangeType' and c['Value'] == 'SDR' for c in avc['Conditions'])
                assert any(c['Property'] == 'VideoBitDepth' and c['Value'] == '8' for c in avc['Conditions'])
                source['SupportsDirectPlay'] = False
                source['SupportsDirectStream'] = False
                source['MediaStreams'] = [dict(Index=0, Type='Video', Codec='hevc', Profile='Main 10', BitDepth=10,
                                              Width=3840, Height=1920, VideoRangeType='HDR10', ColorTransfer='smpte2084', ColorPrimaries='bt2020', ColorSpace='bt2020nc')]
                rendition = 'sdr' if force_transcode else 'broken'
                source['TranscodingUrl'] = prefix+f'/streams/{rendition}/master.m3u8?api_key=fixture-token&VideoCodec=h264'
            return self.send(200, json.dumps({'MediaSources':[source], 'PlaySessionId':item+'-session'}).encode())
        if '/Sessions/Playing' in path:
            assert 'PositionTicks' in data
            return self.send(204)
        return self.send(404)
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/debug/metrics': return self.send(200, json.dumps(metrics).encode())
        metrics[path] = metrics.get(path,0)+1
        if four_k_transport and path == prefix+'/streams/fourk.m3u8':
            query = parse_qs(urlsplit(self.path).query)
            assert query.get('VideoCodec') == ['copy'], 'Native HLS must explicitly request video copy'
            assert query.get('AllowVideoStreamCopy') == ['true']
        if buffering_fixture and path == prefix+'/streams/buffered3.ts':
            # Pause one segment after enough media for a first frame. The
            # native stream should buffer, resume, then retain its quality.
            metrics['buffer_delay_started'] = metrics.get('buffer_delay_started', 0) + 1
            time.sleep(24)
            metrics['buffer_delay_finished'] = metrics.get('buffer_delay_finished', 0) + 1
        if hls_master_fixture and path == prefix+'/streams/broken/master.m3u8':
            q = parse_qs(urlsplit(self.path).query)
            assert q.get('h264-rangetype') == ['SDR']
            assert q.get('AllowVideoStreamCopy') == ['false']
            master = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=8000000,VIDEO-RANGE=SDR,CODECS="avc1.424029,mp4a.40.2",RESOLUTION=480x854\n../demo0.m3u8?api_key=fixture-token\n'
            return self.send(200, master.encode(), 'application/vnd.apple.mpegurl')
        if hls_master_fixture and path.startswith(prefix+'/streams/sdr/'):
            if path.endswith('/master.m3u8'):
                q = parse_qs(urlsplit(self.path).query)
                assert q.get('h264-rangetype') == ['SDR']
                assert q.get('AllowVideoStreamCopy') == ['false']
                master = '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=800000,VIDEO-RANGE=SDR,CODECS="avc1.64001e,mp4a.40.2"\ndemo0.m3u8?api_key=fixture-token\n'
                return self.send(200, master.encode(), 'application/vnd.apple.mpegurl')
            return self.media(sdr/Path(path).name)
        if path.startswith(prefix) and not '/streams/' in path and not self.jelly_auth(): return self.send(401)
        if subtitle_switch_fixture and path == prefix+'/Videos/demo0/demo0/Subtitles/7/Stream.pgssub':
            return self.send(200, switch_pgs, 'application/octet-stream')
        if subtitle_switch_fixture and re.fullmatch(prefix+r'/Videos/demo0/demo0/Subtitles/[456]/Stream.srt', path):
            index = int(path.split('/')[-2])
            return self.send(200, f'1\n00:00:00,000 --> 00:02:00,000\n{switch_subtitles[index]}\n'.encode(), 'application/x-subrip; charset=utf-8')
        if path == prefix+'/Items/person-b/Images/Primary': return self.send(404)
        if path.endswith('/Images/Primary'):
            delayed = design_fixture and path == prefix+'/Items/demo0/Images/Primary' and parse_qs(urlsplit(self.path).query).get('maxWidth') == ['420'] and not metrics.get('design_first_poster_delivered')
            if delayed: time.sleep(1)
            result = self.send(200, (hls/'poster.jpg').read_bytes(), 'image/jpeg')
            if delayed: metrics['design_first_poster_delivered'] = 1
            return result
        if path == prefix+'/UserViews':
            return self.send(200, json.dumps({'Items':[{'Id':'fixture-library','Name':'Fixture Library','IsFolder':True,'Type':'CollectionFolder','CollectionType':'homevideos'}, {'Id':'fixture-movies','Name':'Fixture Movies','IsFolder':True,'Type':'CollectionFolder','CollectionType':'movies'}, {'Id':'fixture-shows','Name':'Fixture Shows','IsFolder':True,'Type':'CollectionFolder','CollectionType':'tvshows'}], 'TotalRecordCount':3}).encode())
        if path.endswith('/Similar'):
            q = parse_qs(urlsplit(self.path).query)
            assert q.get('UserId') == ['fixture-user']
            return self.send(200, json.dumps({'Items':[film, series], 'TotalRecordCount':2}).encode())
        if four_k_file and path == prefix+'/Items/buffer4k/Download': return self.four_k_media(throttled=False)
        if path == prefix+f'/Items/{film["Id"]}/Download':
            if download_fixture_id and metrics[path] == 1:
                # A successful HTTP response carrying an incomplete file must fail
                # integrity checks, then allow a clean retry of the complete MP4.
                data = (resources/'demo0.mp4').read_bytes()
                return self.send(200, data[:len(data)//2], 'video/mp4')
            return self.media(resources/'demo0.mp4')
        if path == prefix+'/Items/series':
            return self.send(200, json.dumps(series).encode())
        if navigation_fixture and path == prefix+'/Videos/demo0/Trickplay/160/0.jpg':
            assert parse_qs(urlsplit(self.path).query).get('MediaSourceId') == ['demo0']
            if not self.jelly_auth(): return self.send(401)
            return self.send(200, (hls/'navigation.jpg').read_bytes(), 'image/jpeg')
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
                items = {'fixture-movies':[film,broken]+design_films, 'fixture-shows':[series], 'series':seasons, 'season1':episodes, 'season2':[]}[parent]
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
                return self.send(200,json.dumps({'Items':items[start:start+(12 if design_fixture else 1)], 'TotalRecordCount':len(items)}).encode())
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
        if design_fixture and '/Items/design-' in path and path.endswith('/Download'): return self.media(resources/'demo0.mp4')
        if '/Videos/' in path and path.endswith('/stream'):
            if design_fixture and '/design-' in path: return self.media(resources/'demo0.mp4')
            if four_k_file and '/buffer4k/' in path: return self.four_k_media()
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
        mime={'.mp4':'video/mp4','.m3u8':'application/vnd.apple.mpegurl','.ts':'video/mp2t','.m4s':'video/iso.segment'}.get(path.suffix,'application/octet-stream')
        match=re.fullmatch(r'bytes=(\d+)-(\d*)',self.headers.get('Range',''))
        if match:
            start=int(match[1]); end=min(size-1, int(match[2]) if match[2] else size-1)
            if start >= size: return self.send(416)
            return self.send(206,data[start:end+1],mime,{'Content-Range':f'bytes {start}-{end}/{size}','Accept-Ranges':'bytes'})
        return self.send(200,data,mime,{'Accept-Ranges':'bytes'})
    def four_k_media(self, throttled=True):
        if throttled: metrics['four_k_direct_requests'] = metrics.get('four_k_direct_requests', 0) + 1
        # A real progressive MP4 with byte ranges. Tiny recurrent delivery gaps
        # reproduce a low usable cache; no HLS/transcode stands in for direct play.
        size = four_k_file.stat().st_size
        match = re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
        start, end = (int(match[1]), min(size-1, int(match[2]) if match[2] else size-1)) if match else (0, size-1)
        if start >= size or end < start: return self.send(416)
        self.send_response(206 if match else 200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Content-Length', str(end-start+1))
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Cache-Control', 'no-store')
        if match: self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        self.end_headers()
        if self.command == 'HEAD': return
        source = parse_qs(urlsplit(self.path).query).get('MediaSourceId', ['default'])[0]
        try:
            with four_k_file.open('rb') as media:
                offset = start
                while offset <= end:
                    block = offset // (2 * 1024 * 1024)
                    with four_k_lock:
                        key = (source, block)
                        if throttled and block > 0 and key not in four_k_delays:
                            gap = (24 if block == 4 or (source == 'buffer4k-no-remux' and block == 32) else 0.4) if four_k_transport else (8 if block == 8 else 3 if block == 1 else float(os.environ.get('GLIDE_4K_BLOCK_DELAY', '0.9')))
                            four_k_delays[key] = time.monotonic() + gap
                            metrics['four_k_gap_count'] = metrics.get('four_k_gap_count', 0) + 1
                        deadline = four_k_delays.get(key, 0) if throttled else 0
                    # Retried/overlapping ranges wait for the same release time;
                    # cancellation must not bypass the artificial network gap.
                    delay = deadline - time.monotonic()
                    if delay > 0: time.sleep(delay)
                    media.seek(offset)
                    data = media.read(min(end-offset+1, (block+1)*2*1024*1024-offset))
                    if not data: break
                    self.wfile.write(data); self.wfile.flush()
                    offset += len(data)
        except (BrokenPipeError, ConnectionResetError): pass
fixture_bind = os.environ.get('GLIDE_FIXTURE_BIND', '127.0.0.1')
fixture_port = int(os.environ.get('GLIDE_FIXTURE_PORT', '8768'))
print(f'Fixture running on http://{fixture_bind}:{fixture_port}',flush=True)
try: ThreadingHTTPServer((fixture_bind,fixture_port),Handler).serve_forever()
finally:
    import shutil
    shutil.rmtree(hls)
