#!/usr/bin/env python3
"""Populate the isolated 1.7 official Emby container with authored fixtures.

Only targets 127.0.0.1:8772. Start the pinned container from the acceptance
README first. Credentials are fixed fake test values, never real NAS secrets.
"""
import json
from pathlib import Path
import shutil
import subprocess
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path('/tmp/Glide170')
MEDIA = ROOT / 'Media'
SOURCE = Path(__file__).resolve().parents[1] / 'Glide/Resources/demo0.mp4'
BASE = 'http://127.0.0.1:8772/emby/'
AUTH = 'Emby Client="GlideFixture", Device="Mac", DeviceId="glide170-fixture", Version="1.7.0"'


def call(path, body=None, method='GET', authorization=AUTH):
    request = urllib.request.Request(BASE + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={'Authorization': authorization, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read()
        return json.loads(data) if data else None


def ffmpeg(*args):
    subprocess.run(['ffmpeg', '-nostdin', '-y', '-loglevel', 'error', *map(str, args)], check=True)


def mux_audio_subtitle(video, movie):
    subtitle = ROOT / 'authored.srt'
    subtitle.write_text('1\n00:00:00,000 --> 00:00:10,000\nEmby subtitle fixture\n')
    temporary = movie.parent / 'with-audio.mp4'
    ffmpeg('-stream_loop', '-1', '-i', video, '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100',
        '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=44100', '-i', subtitle,
        '-map', '0:v', '-map', '1:a', '-map', '2:a', '-map', '3:s', '-t', '660',
        '-c:v', 'copy', '-c:a', 'aac', '-b:a', '48k', '-threads', '1', '-c:s', 'mov_text',
        '-metadata:s:a:0', 'language=zho', '-metadata:s:a:1', 'language=eng', '-metadata:s:s:0', 'language=eng',
        '-disposition:a:0', 'default', '-disposition:a:1', '0', '-movflags', '+faststart', temporary)
    temporary.replace(movie)
    subtitle.unlink()


def prepare_media():
    targets = [
        ('Movies/Glide Original (2026)', 'Glide Original (2026)', 'movie', 'Glide 原创电影'),
        ('TV/Glide Show/Season 01', 'Glide Show S01E01', 'episode', '原创第一集'),
        ('TV/Glide Show/Season 01', 'Glide Show S01E02', 'episode', '原创第二集'),
        ('Home/家庭 原创 #1/子目录', '家庭片段', 'video', '家庭原创片段')]
    for folder, name, kind, title in targets:
        target = MEDIA / folder
        target.mkdir(parents=True, exist_ok=True)
        movie = target / (name + '.mp4')
        if not movie.exists():
            ffmpeg('-stream_loop', '-1', '-i', SOURCE, '-t', '660', '-c', 'copy', movie)
        tag = 'episodedetails' if kind == 'episode' else 'movie'
        extra = '<season>1</season><episode>' + ('2' if 'E02' in name else '1') + '</episode>' if kind == 'episode' else ''
        (target / (name + '.nfo')).write_text(f'<{tag}><title>{title}</title><plot>Glide 原创验证素材</plot><year>2026</year><genre>原创</genre>{extra}</{tag}>')
        if not (target / 'poster.jpg').exists():
            ffmpeg('-i', SOURCE, '-frames:v', '1', '-vf', 'scale=400:600', target / 'poster.jpg')
    folder = MEDIA / targets[0][0]
    movie = folder / (targets[0][1] + '.mp4')
    streams = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', str(movie)]))['streams']
    marker = ROOT / 'regular-gop-fixture-v2'
    if len([s for s in streams if s['codec_type'] == 'audio']) != 2 or not marker.exists():
        normalized = ROOT / 'authored-2s-gop.mp4'
        ffmpeg('-i', SOURCE, '-an', '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '24',
            '-g', '48', '-keyint_min', '48', '-sc_threshold', '0', '-threads', '1', normalized)
        mux_audio_subtitle(normalized, movie)
        marker.write_text('Authored AVC/AAC/text sample; 24fps, 2s keyframe interval. Long-GOP seek limitation recorded separately.\n')
    diagnostic = MEDIA / 'Movies/ZZZ Long GOP fixture'
    diagnostic.mkdir(exist_ok=True)
    movie = diagnostic / 'ZZZ Long GOP fixture.mp4'
    if not movie.exists():
        mux_audio_subtitle(SOURCE, movie)
    (diagnostic / 'ZZZ Long GOP fixture.nfo').write_text('<movie><title>ZZZ Long GOP fixture</title><plot>Authored seek recovery regression</plot><year>2026</year></movie>')
    show = MEDIA / 'TV/Glide Show'
    (show / 'tvshow.nfo').write_text('<tvshow><title>Glide 原创剧集</title><plot>两集原创验证内容</plot><year>2026</year></tvshow>')
    shutil.copy2(folder / 'poster.jpg', show / 'poster.jpg')
    for index in range(1, 65):
        name = f'ZZ Pagination {index:03d}'
        target = MEDIA / 'Movies' / name
        target.mkdir(exist_ok=True)
        if not (target / (name + '.mp4')).exists():
            shutil.copy2(SOURCE, target / (name + '.mp4'))
        (target / (name + '.nfo')).write_text(f'<movie><title>{name}</title><plot>Authored pagination fixture {index}</plot><year>2026</year></movie>')


def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    prepare_media()
    credentials = {'Username': 'glide-fixture', 'Pw': 'glide170-fixture'}
    try:
        auth = call('Users/AuthenticateByName', credentials, 'POST')
    except urllib.error.HTTPError as error:
        if error.code != 401:
            raise
        call('Startup/User', {'Name': credentials['Username'], 'Password': credentials['Pw']}, 'POST')
        auth = call('Users/AuthenticateByName', credentials, 'POST')
    header = AUTH + ', Token="' + auth['AccessToken'] + '"'
    # Kept in /tmp only for local fixture scripts; never copied into acceptance artifacts.
    (ROOT / 'fixture-auth.json').write_text(json.dumps(auth))
    (ROOT / 'fixture-auth.json').chmod(0o600)
    config = call('System/Configuration', authorization=header)
    config.update(EnableUPnP=False, EnableAutoUpdate=False, EnableExternalContentInSuggestions=False)
    call('System/Configuration', config, 'POST', header)
    if not config.get('IsStartupWizardCompleted'):
        call('Startup/Complete', {}, 'POST', header)
    existing = {item['Name'] for item in call('Library/VirtualFolders', authorization=header)}
    for name, kind, path in [('Glide Movies', 'movies', 'Movies'), ('Glide Shows', 'tvshows', 'TV'), ('Glide Home', 'homevideos', 'Home')]:
        if name in existing:
            continue
        options = {'EnableRealtimeMonitor': False, 'EnableInternetProviders': False, 'SaveLocalMetadata': False,
            'PathInfos': [{'Path': '/media/' + path}], 'MetadataSavers': [],
            'TypeOptions': [{'Type': item, 'MetadataFetchers': [], 'ImageFetchers': []} for item in ['Movie', 'Series', 'Season', 'Episode', 'Video']]}
        query = urllib.parse.urlencode({'name': name, 'collectionType': kind, 'refreshLibrary': 'false'})
        call('Library/VirtualFolders?' + query, {'LibraryOptions': options}, 'POST', header)
    call('Library/Refresh', {}, 'POST', header)
    info = call('System/Info/Public')
    (ROOT / 'fixture-server.json').write_text(json.dumps({'version': info['Version'], 'image': 'emby/embyserver_arm64v8@sha256:22aeef01c017467c3e41d5f735bf93bff5745b54b7366b2df951d99efdf5f9da', 'authoredFiles': len(list(MEDIA.rglob('*.mp4')))}, indent=2))
    print('Fixture refreshed; wait for scanning before running --glide-emby-probe.')


if __name__ == '__main__':
    main()
