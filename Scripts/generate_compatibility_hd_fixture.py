#!/usr/bin/env python3
"""Author a 60-second 1080p SDR, dual-tone audio and styled ASS QA sample."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def generate(root):
    root.mkdir(parents=True, exist_ok=True)
    subtitle = root / 'hd-original.ass'
    subtitle.write_text('''[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
[V4+ Styles]
Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
Style: Default,Arial,60,&H0000FFFF,&H000000FF,&H00000000,&H90000000,1,0,0,0,100,100,0,0,3,2,0,2,24,24,40,1
[Events]
Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
Dialogue: 0,0:00:00.00,0:00:20.00,Default,,0,0,0,,Glide HD ASS first cue
Dialogue: 0,0:00:25.00,0:00:40.00,Default,,0,0,0,,Glide HD ASS second cue
Dialogue: 0,0:00:45.00,0:00:59.50,Default,,0,0,0,,Glide HD ASS final cue
''', encoding='utf-8')
    target = root / '11-hd-dual-ass.mkv'
    command = [shutil.which('ffmpeg') or 'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'testsrc2=size=1920x1080:rate=24:duration=60',
        '-f', 'lavfi', '-i', 'sine=frequency=440:duration=60',
        '-f', 'lavfi', '-i', 'sine=frequency=880:duration=60', '-i', str(subtitle),
        '-map', '0:v', '-map', '1:a', '-map', '2:a', '-map', '3:0',
        '-c:v', 'libx264', '-preset', 'veryfast', '-threads', '2', '-crf', '26',
        '-pix_fmt', 'yuv420p', '-g', '48', '-c:a', 'aac', '-b:a', '96k', '-c:s', 'ass',
        '-metadata:s:a:0', 'language=eng', '-metadata:s:a:1', 'language=zho', str(target)]
    subprocess.run(command, check=True)
    report = {'originalSyntheticMedia': True, 'duration': 60, 'width': 1920, 'height': 1080,
        'fps': 24, 'audioTonesHz': [440, 880], 'command': command,
        'file': target.name, 'bytes': target.stat().st_size,
        'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}
    (root / 'hd-manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print(target)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    generate(parser.parse_args().output)
