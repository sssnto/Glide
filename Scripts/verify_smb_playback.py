#!/usr/bin/env python3
"""Drive the opt-in SMB QA probe against ONLY Glide's isolated Samba fixture.

Launch GlideCompatibilityQA with --glide-smb-probe --glide-smb-stress first.
This script never connects to or interrupts a user's NAS.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def run(simulator, pid, work, output):
    fixture = 'glide150-samba'
    details = json.loads(command('docker', 'inspect', fixture))[0]
    expected_image = 'dperson/samba@sha256:66088b78a19810dd1457a8f39340e95e663c728083efa5fe7dc0d40b2478e869'
    if details['Config']['Image'] != expected_image or not any(
        Path(m['Source']).resolve() == (work / 'share').resolve() and m['Destination'] == '/mount' and not m['RW']
        for m in details['Mounts']
    ):
        raise ValueError('Refusing to interrupt a container other than the isolated, read-only Glide SMB fixture')
    container = Path(command('xcrun', 'simctl', 'get_app_container', simulator, 'com.songpeng.glide.compatibilityqa', 'data'))
    report = container / 'Library/Application Support/smb-probe.json'
    stages = set()
    samples = []
    stopped = False
    next_sample = 0
    deadline = time.monotonic() + 3600
    value = {}
    try:
        while time.monotonic() < deadline:
            try:
                value = json.loads(report.read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                time.sleep(1)
                continue
            stage = value.get('stage', '')
            if stage not in stages:
                print(stage, flush=True)
                stages.add(stage)
            stop = re.fullmatch(r'await-network-stop-([0-4])', stage)
            restore = re.fullmatch(r'await-network-return-([0-4])', stage)
            if stop and 'stop:' + stage not in stages:
                command('docker', 'stop', '--timeout', '1', fixture)
                stopped = True
                stages.add('stop:' + stage)
            if restore and 'restore:' + stage not in stages:
                command('docker', 'start', fixture)
                stopped = False
                stages.add('restore:' + stage)
            if stage == 'longplay-30-minutes' and time.monotonic() >= next_sample:
                rss = int(command('ps', '-p', str(pid), '-o', 'rss='))
                samples.append({'monotonicSeconds': time.monotonic(), 'rssKiB': rss})
                next_sample = time.monotonic() + 30
                print(f'Long playback sample {len(samples)}: RSS {rss} KiB', flush=True)
            if value.get('error') or value.get('passed'):
                break
            time.sleep(1)
        else:
            raise TimeoutError('SMB QA probe did not finish within one hour')
    finally:
        if stopped:
            command('docker', 'start', fixture)
    required = {'lifecycle:50-open-stop', 'network:reconnect-4', 'playback:30-minutes'}
    passed = value.get('passed') is True and required.issubset(value.get('checks', []))
    release = ''
    if passed:
        for _ in range(15):
            release = command('docker', 'exec', fixture, 'smbstatus', '-b')
            if not any(re.match(r'^\s*\d+\s+', line) for line in release.splitlines()):
                break
            time.sleep(1)
        else:
            passed = False
    artifact = {'passed': passed, 'appReport': value, 'rssSamples': samples,
        'memoryScope': 'macOS simulator process RSS; not a physical-device heap or leak measurement',
        'connectionsAfterStop': release, 'simulator': simulator}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(artifact, ensure_ascii=False, indent=2) + '\n')
    print(f'Wrote {output}; passed={passed}', flush=True)
    return passed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--work', type=Path, default=Path('/tmp/Glide150'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    raise SystemExit(0 if run(args.simulator, args.pid, args.work, args.output) else 1)
