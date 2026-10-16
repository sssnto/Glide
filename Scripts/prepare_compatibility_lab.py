#!/usr/bin/env python3
"""Generate the isolated QA project using the same pinned SDK as Glide."""
import argparse
from pathlib import Path
import subprocess
from prepare_compatibility_sdk import prepare as prepare_sdk

ROOT = Path(__file__).resolve().parents[1]


def prepare(work, archive=None, sdk_work=None):
    work = work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    framework = prepare_sdk(sdk_work or ROOT / '.build/CompatibilitySDK', archive)
    subprocess.run(['ruby', str(ROOT / 'Experiments/CompatibilityPlayer/generate_project.rb'),
        str(work), str(framework)], check=True)
    print(work / 'CompatibilityLab.xcodeproj')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, default=ROOT / '.build/CompatibilityLab')
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--sdk-work', type=Path)
    args = parser.parse_args()
    prepare(args.work, args.archive, args.sdk_work)
