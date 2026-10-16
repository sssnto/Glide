#!/usr/bin/env python3
"""Add authored UTF-8 Chinese subtitles without changing the existing media matrix."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def generate(root):
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise SystemExit('ffmpeg required')
    samples = []
    for number, kind, font in [(12, 'ass', 'Arial'), (13, 'ass', 'Glide Missing Font'), (14, 'srt', None)]:
        subtitle = root / f'cjk-{number}.{kind}'
        text = '中文字幕正常显示' if number != 13 else '繁體字幕正常顯示'
        if kind == 'ass':
            subtitle.write_text(f'''[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
[V4+ Styles]
Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding
Style: Default,{font},34,&H00FFFFFF,&H000000FF,&H00000000,&H90000000,0,0,0,0,100,100,0,0,1,2,0,2,12,12,25,1
[Events]
Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
Dialogue: 0,0:00:00.00,0:00:19.50,Default,,0,0,0,,{text}\\NGlide CJK {kind.upper()}
''', encoding='utf-8')
        else:
            subtitle.write_text(f'1\n00:00:00,000 --> 00:00:19,500\n{text}\nGlide CJK SRT\n', encoding='utf-8')
        target = root / f'{number}-cjk-{kind}.mkv'
        subprocess.run([ffmpeg, '-y', '-hide_banner', '-loglevel', 'error',
            '-i', str(root / '01-h264-aac.mp4'), '-i', str(subtitle),
            '-map', '0:v', '-map', '0:a', '-map', '1:0', '-c', 'copy',
            '-metadata:s:s:0', 'language=zho', str(target)], check=True)
        samples.append({'file': target.name, 'font': font, 'text': text, 'codec': kind,
            'sha256': hashlib.sha256(target.read_bytes()).hexdigest()})
    (root / 'cjk-manifest.json').write_text(json.dumps({'originalSyntheticMedia': True,
        'samples': samples}, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    generate(parser.parse_args().output)
