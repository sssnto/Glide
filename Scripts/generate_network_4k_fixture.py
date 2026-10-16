#!/usr/bin/env python3
"""Author a portrait 4K AVC Main/5.2 SDR progressive playback fixture."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def generate(root, fps=24, bitrate=20):
    root.mkdir(parents=True, exist_ok=True)
    ffmpeg = shutil.which('ffmpeg') or 'ffmpeg'
    seed, target = root / 'seed-4k.mp4', root / 'network-4k.mp4'
    subprocess.run([ffmpeg, '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', f'testsrc2=size=2160x3840:rate={fps}:duration=12',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=12',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-threads', '2',
        '-profile:v', 'main', '-level:v', '5.2', '-coder', '1', '-bf', '2', '-g', str(fps * 2),
        '-pix_fmt', 'yuv420p', '-b:v', f'{bitrate}M', '-minrate', f'{bitrate}M', '-maxrate', f'{bitrate}M', '-bufsize', f'{bitrate * 2}M',
        '-x264-params', 'nal-hrd=cbr:force-cfr=1', '-color_trc', 'bt709', '-color_primaries', 'bt709', '-colorspace', 'bt709',
        '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', str(seed)], check=True)
    subprocess.run([ffmpeg, '-y', '-hide_banner', '-loglevel', 'error', '-stream_loop', '4', '-i', str(seed),
        '-t', '60', '-c', 'copy', '-movflags', '+faststart', str(target)], check=True)
    info = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(target)]))
    video = next(s for s in info['streams'] if s['codec_type'] == 'video')
    assert video['width'] == 2160 and video['height'] == 3840 and video['codec_name'] == 'h264'
    (root / 'network-4k-manifest.json').write_text(json.dumps({'originalSyntheticMedia': True,
        'file': target.name, 'sha256': hashlib.sha256(target.read_bytes()).hexdigest(), 'ffprobe': info}, indent=2) + '\n')
    print(target)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--fps', type=int, choices=[24, 50], default=24)
    parser.add_argument('--bitrate', type=int, choices=range(20, 41), default=20)
    args = parser.parse_args()
    generate(args.output, args.fps, args.bitrate)
