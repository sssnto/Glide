#!/usr/bin/env python3
"""Generate original synthetic playback samples outside the app bundle (requires ffmpeg)."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def generate(root):
    root.mkdir(parents=True, exist_ok=True)
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise SystemExit('ffmpeg is required for fixture generation only')
    commands = []

    def run(name, *args):
        command = [ffmpeg, '-y', '-hide_banner', '-loglevel', 'error', *args, str(root / name)]
        subprocess.run(command, check=True)
        commands.append({'file': name, 'args': list(args)})

    video = ['-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=15']
    audio = ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000']
    run('01-h264-aac.mp4', *video, *audio, '-t', '20', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'ultrafast', '-c:a', 'aac', '-movflags', '+faststart')
    run('02-hevc-aac.mp4', *video, *audio, '-t', '20', '-c:v', 'libx265', '-pix_fmt', 'yuv420p', '-preset', 'ultrafast', '-x265-params', 'log-level=error:pools=1', '-tag:v', 'hvc1', '-c:a', 'aac', '-movflags', '+faststart')
    run('03-h264-aac.mkv', '-i', str(root / '01-h264-aac.mp4'), '-c', 'copy')
    run('04-mpeg4-mp3.avi', *video, *audio, '-t', '20', '-c:v', 'mpeg4', '-q:v', '5', '-c:a', 'libmp3lame')
    shutil.copyfile(root / '03-h264-aac.mkv', root / '05-renamed-mkv.mp4')
    (root / '06-truncated.mp4').write_bytes((root / '01-h264-aac.mp4').read_bytes()[:128])
    run('07-audio-only.mp4', *audio, '-t', '20', '-c:a', 'aac')
    (root / 'captions.srt').write_text('1\n00:00:00,000 --> 00:00:19,000\nGlide synthetic subtitle\n', encoding='utf-8')
    run('08-multi-track.mp4', '-i', str(root / '01-h264-aac.mp4'), '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=48000', '-i', str(root / 'captions.srt'), '-t', '20', '-map', '0:v', '-map', '0:a', '-map', '1:a', '-map', '2:0', '-c:v', 'copy', '-c:a', 'aac', '-c:s', 'mov_text', '-metadata:s:a:0', 'language=eng', '-metadata:s:a:1', 'language=zho', '-metadata:s:s:0', 'language=eng', '-movflags', '+faststart')
    manifest = {'schema': 1, 'source': 'Original FFmpeg testsrc2 and sine sources; no third-party media', 'ffmpeg': subprocess.check_output([ffmpeg, '-version'], text=True).splitlines()[0], 'samples': [{'file': p.name, 'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(root.iterdir()) if p.suffix in ('.mp4', '.mkv', '.avi')], 'commands': commands}
    (root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(f'Generated {len(manifest["samples"])} samples in {root}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    generate(parser.parse_args().output)
