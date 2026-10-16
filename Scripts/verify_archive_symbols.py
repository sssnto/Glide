#!/usr/bin/env python3
"""Verify archive UUID coverage; optionally restore the pinned MobileVLCKit dSYM."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import tempfile

from prepare_compatibility_sdk import PIN, ROOT, digest, uuids, validate_symbols


def application(archive):
    info = plistlib.loads((archive / 'Info.plist').read_bytes())
    if archive.suffix != '.xcarchive' or info.get('ApplicationProperties', {}).get('CFBundleIdentifier') != 'com.songpeng.glide':
        raise SystemExit('Expected a Glide distribution archive')
    app = archive / 'Products/Applications/Glide.app'
    if not app.is_dir():
        raise SystemExit('Missing archived Glide.app')
    return app


def repair_mobile_vlc(archive, sdk):
    app = application(archive)
    validate_symbols(sdk)
    report = json.loads((sdk.parent / 'prepared-sdk.json').read_text())
    if report.get('archiveSHA256') != json.loads(PIN.read_text())['sha256']:
        raise SystemExit('Unrecognized SDK provenance')
    source = sdk / 'ios-arm64/dSYMs/MobileVLCKit.framework.dSYM'
    dwarf = source / 'Contents/Resources/DWARF/MobileVLCKit'
    relative = str(dwarf.relative_to(sdk))
    if report.get('symbols', {}).get(relative) != digest(dwarf):
        raise SystemExit('Prepared dSYM checksum mismatch')
    embedded = app / 'Frameworks/MobileVLCKit.framework/MobileVLCKit'
    if uuids(embedded) != uuids(dwarf):
        raise SystemExit('Archived MobileVLCKit UUID does not match official dSYM; repair refused')
    destination = archive / 'dSYMs/MobileVLCKit.framework.dSYM'
    if destination.exists():
        if digest(destination / 'Contents/Resources/DWARF/MobileVLCKit') != digest(dwarf):
            raise SystemExit('A different MobileVLCKit dSYM already exists; repair refused')
        return False
    destination.parent.mkdir(exist_ok=True)
    # Only add symbols outside the signed app. Publish the complete bundle at once.
    with tempfile.TemporaryDirectory(prefix='.mobilevlc-symbols-', dir=destination.parent) as staging:
        candidate = Path(staging) / destination.name
        shutil.copytree(source, candidate)
        if uuids(candidate) != uuids(embedded):
            raise SystemExit('Copied dSYM UUID verification failed')
        candidate.rename(destination)
    return True


def verify(archive):
    app = application(archive)
    symbols = {}
    for bundle in (archive / 'dSYMs').glob('*.dSYM'):
        for dwarf in (bundle / 'Contents/Resources/DWARF').iterdir():
            if dwarf.is_file():
                for arch, uuid in uuids(dwarf).items():
                    symbols[(arch, uuid)] = str(bundle.relative_to(archive))
    bundles = [app, *sorted((app / 'Frameworks').glob('*.framework'))]
    coverage = []
    missing = []
    for bundle in bundles:
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        binary = bundle / info['CFBundleExecutable']
        for arch, uuid in uuids(binary).items():
            dsym = symbols.get((arch, uuid))
            entry = {'binary': str(binary.relative_to(archive)), 'architecture': arch, 'uuid': uuid, 'dSYM': dsym}
            coverage.append(entry)
            if dsym is None:
                missing.append(entry)
    if missing:
        raise SystemExit('Missing archive dSYMs: ' + json.dumps(missing, ensure_ascii=False))
    return {'archive': str(archive), 'passed': True, 'coverage': coverage}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--repair-mobilevlckit', action='store_true', help='Add only the official UUID-matched MobileVLCKit dSYM')
    parser.add_argument('--sdk', type=Path, default=ROOT / '.build/CompatibilitySDK/MobileVLCKit.xcframework')
    args = parser.parse_args()
    repaired = repair_mobile_vlc(args.archive.resolve(), args.sdk.resolve()) if args.repair_mobilevlckit else False
    result = verify(args.archive.resolve())
    result['repairedMobileVLCKit'] = repaired
    print(json.dumps(result, ensure_ascii=False, indent=2))
