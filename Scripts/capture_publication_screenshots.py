#!/usr/bin/env python3
"""Capture actual Simulator framebuffers at public-demo XCTest checkpoints."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--device', required=True)
parser.add_argument('--display', required=True)
parser.add_argument('--runner', required=True)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
started = time.time()
seen = set()
records = []
while time.time() - started < 420:
    container = subprocess.run(['xcrun', 'simctl', 'get_app_container', args.device, args.runner, 'data'], capture_output=True, text=True)
    if container.returncode:
        time.sleep(0.3)
        continue
    root = Path(container.stdout.strip()) / 'Documents/Publishing201'
    try:
        stage = json.loads((root / 'stage.json').read_text())
        ack = json.loads((root / 'captured.json').read_text()) if (root / 'captured.json').exists() else {}
        if stage['nonce'] in seen or ack.get('nonce') == stage['nonce']:
            time.sleep(0.2)
            continue
        # Ignore an abandoned checkpoint from a previous test process.
        if (root / 'stage.json').stat().st_mtime < started - 2:
            time.sleep(0.2)
            continue
    except (FileNotFoundError, json.JSONDecodeError):
        time.sleep(0.2)
        continue
    filename = stage['stage'].lower() + '.jpg'
    target = args.output / filename
    subprocess.run(['xcrun', 'simctl', 'io', args.device, 'screenshot', '--type=jpeg', '--display=' + args.display, str(target)], check=True, capture_output=True)
    metadata = subprocess.check_output(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', '-g', 'hasAlpha', str(target)], text=True)
    assert 'hasAlpha: no' in metadata, metadata
    records.append({'file': filename, 'stage': stage['stage'], 'metadata': metadata.splitlines()[1:],
                    'sha256': hashlib.sha256(target.read_bytes()).hexdigest(), 'source': 'unmodified Simulator framebuffer'})
    (args.output / 'capture-manifest.json').write_text(json.dumps(records, ensure_ascii=False, indent=2) + '\n')
    seen.add(stage['nonce'])
    temporary = root / 'captured.tmp'
    temporary.write_text(json.dumps({'nonce': stage['nonce']}))
    temporary.replace(root / 'captured.json')
    print(filename, flush=True)
    if stage['stage'] == '06-Library-Dark':
        break
else:
    raise SystemExit('Timed out waiting for public-demo capture checkpoints')
