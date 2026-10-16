#!/usr/bin/env python3
"""Extend the original playback matrix with authored ASS and dual-audio MKV samples."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from generate_playback_fixtures import generate


def extend(root):
    if not (root / 'manifest.json').exists():
        generate(root)
    manifest = json.loads((root / 'manifest.json').read_text())
    for entry in manifest['samples']:
        if entry['file'].startswith(('01-', '08-')):
            if hashlib.sha256((root / entry['file']).read_bytes()).hexdigest() != entry['sha256']:
                raise SystemExit('Original fixture changed: ' + entry['file'])
    subtitle = root / 'original.ass'
    subtitle.write_text('''[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
[V4+ Styles]
Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
Style: Default,Arial,34,&H0000FFFF,&H000000FF,&H00000000,&H90000000,1,0,0,0,100,100,0,0,3,2,0,2,12,12,20,1
[Events]
Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
Dialogue: 0,0:00:00.00,0:00:19.50,Default,,0,0,0,,Glide ASS subtitle
''', encoding='utf-8')
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise SystemExit('ffmpeg required for original QA sample generation')
    commands = []
    for name, source, maps in [
        ('09-ass.mkv', '01-h264-aac.mp4', ['-map', '0:v', '-map', '0:a', '-map', '1:0']),
        ('10-dual-audio-ass.mkv', '08-multi-track.mp4', ['-map', '0:v', '-map', '0:a:0', '-map', '0:a:1', '-map', '1:0'])]:
        args = ['-i', str(root / source), '-i', str(subtitle), *maps, '-c:v', 'copy', '-c:a', 'copy', '-c:s', 'ass', '-metadata:s:s:0', 'language=eng']
        subprocess.run([ffmpeg, '-y', '-hide_banner', '-loglevel', 'error', *args, str(root / name)], check=True)
        commands.append({'file': name, 'args': args})
    manifest['compatibilityCommands'] = commands
    manifest['samples'] = [{'file': p.name, 'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(root.iterdir()) if p.suffix in ['.mp4', '.mkv', '.avi']]
    (root / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(f'Compatibility matrix: {len(manifest["samples"])} original synthetic files')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    extend(parser.parse_args().output)
