#!/usr/bin/env python3
"""Prepare the hash-pinned official SDK, retaining only supported CPU slices."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PIN = ROOT / 'Dependencies/MobileVLCKit.json'
PREPARATION_VERSION = 3
HEADER_IMPORTS = {
    'VLCAdjustFilter.h': 'VLCFilter.h',
    'VLCConsoleLogger.h': 'VLCLogging.h',
    'VLCFileLogger.h': 'VLCLogging.h',
    'VLCLogMessageFormatter.h': 'VLCLogging.h',
}
TRANSFORMATION = ('Architecture thinning and public-header import normalization only; '
                  'official matching dSYMs retained; decoder binaries unchanged')


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def normalize_header_imports(framework):
    changes = []
    for name, imported in HEADER_IMPORTS.items():
        header = framework / 'Headers' / name
        original = header.read_bytes()
        quoted = ('#import "' + imported + '"').encode()
        qualified = ('#import <MobileVLCKit/' + imported + '>').encode()
        if original.count(quoted) == 1 and qualified not in original:
            changes.append((header, original.replace(quoted, qualified)))
        elif quoted in original or original.count(qualified) != 1:
            raise SystemExit('Unexpected SDK header import; normalization refused: ' + str(header))
    # Check every input before publishing any changes. Already normalized files
    # are accepted so an interrupted managed-cache upgrade can be retried.
    for header, contents in changes:
        temporary = header.with_suffix('.h.normalized')
        temporary.write_bytes(contents)
        temporary.replace(header)


def header_fingerprints(target):
    result = {}
    for identifier in ['ios-arm64', 'ios-arm64_x86_64-simulator']:
        for name, imported in HEADER_IMPORTS.items():
            header = target / identifier / 'MobileVLCKit.framework/Headers' / name
            contents = header.read_bytes()
            qualified = ('#import <MobileVLCKit/' + imported + '>').encode()
            if contents.count(qualified) != 1 or ('#import "' + imported + '"').encode() in contents:
                raise SystemExit('Unnormalized SDK header; rerun SDK preparation: ' + str(header))
            result[str(header.relative_to(target))] = digest(header)
    return result


def uuids(path):
    output = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True)
    values = dict((arch, uuid.upper()) for uuid, arch in re.findall(r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)', output))
    if not values:
        raise SystemExit('No Mach-O UUIDs found: ' + str(path))
    return values


def validate_symbols(target):
    info = plistlib.loads((target / 'Info.plist').read_bytes())
    expected = {'ios-arm64': {'arm64'}, 'ios-arm64_x86_64-simulator': {'arm64', 'x86_64'}}
    if {entry['LibraryIdentifier'] for entry in info['AvailableLibraries']} != expected.keys():
        raise SystemExit('Unexpected prepared SDK slices')
    result = {}
    for entry in info['AvailableLibraries']:
        identifier = entry['LibraryIdentifier']
        base = target / identifier
        binary = base / entry['LibraryPath'] / 'MobileVLCKit'
        dsym = base / entry.get('DebugSymbolsPath', 'missing-symbols') / 'MobileVLCKit.framework.dSYM'
        dwarf = dsym / 'Contents/Resources/DWARF/MobileVLCKit'
        if not dwarf.is_file():
            raise SystemExit('Missing official SDK dSYM; rerun SDK preparation')
        binary_uuids, symbol_uuids = uuids(binary), uuids(dwarf)
        if binary_uuids != symbol_uuids or set(binary_uuids) != expected[identifier]:
            raise SystemExit('SDK binary / dSYM architecture or UUID mismatch')
        result[identifier] = binary_uuids
    return result


def thin(binary, architectures):
    command = ['xcrun', 'lipo', str(binary)]
    if len(architectures) == 1:
        command += ['-thin', architectures[0]]
    else:
        command += ['-remove', 'i386']
    subprocess.run(command + ['-output', str(binary) + '.thin'], check=True)
    Path(str(binary) + '.thin').replace(binary)


def prepare(work, archive=None):
    pin = json.loads(PIN.read_text())
    work = work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    target = work / 'MobileVLCKit.xcframework'
    stamp = work / 'prepared-sdk.json'
    if target.exists():
        if archive is not None and digest(archive.resolve()) != pin['sha256']:
            raise SystemExit('SDK archive checksum mismatch; preparation refused')
        if not stamp.exists():
            raise SystemExit('Unmanaged SDK output exists; choose a fresh work directory')
        report = json.loads(stamp.read_text())
        if report['archiveSHA256'] != pin['sha256'] or any(
                not (target / name).exists() or digest(target / name) != sha
                for name, sha in report['binaries'].items()):
            raise SystemExit('Prepared SDK changed; choose a fresh work directory')
        if report.get('preparationVersion') in (2, PREPARATION_VERSION):
            if not report.get('symbols') or any(
                    not (target / name).exists() or digest(target / name) != sha
                    for name, sha in report['symbols'].items()):
                raise SystemExit('Prepared SDK symbols changed; choose a fresh work directory')
            validate_symbols(target)
            if report['preparationVersion'] == 2:
                # Upgrade headers without downloading or changing decoder / dSYM
                # binaries whose checksums and UUIDs have just been validated.
                for framework in target.glob('*/MobileVLCKit.framework'):
                    normalize_header_imports(framework)
                report.update(preparationVersion=PREPARATION_VERSION,
                              transformation=TRANSFORMATION,
                              headers=header_fingerprints(target))
                temporary_stamp = stamp.with_suffix('.json.normalized')
                temporary_stamp.write_text(json.dumps(report, indent=2) + '\n')
                temporary_stamp.replace(stamp)
            elif report.get('headers') != header_fingerprints(target):
                raise SystemExit('Prepared SDK headers changed; choose a fresh work directory')
            print(target)
            return target
        # Migrate the earlier managed output that excluded official dSYMs.
        # Keep it usable until the replacement has passed UUID validation.
    archive = archive.resolve() if archive else work / ('MobileVLCKit-' + pin['version'] + '.tar.xz')
    if not archive.exists():
        partial = archive.with_suffix('.partial')
        subprocess.run(['curl', '--fail', '--location', '--retry', '2', '--connect-timeout', '20',
            '--max-time', '360', pin['url'], '--output', str(partial)], check=True)
        partial.replace(archive)
    if digest(archive) != pin['sha256']:
        raise SystemExit('SDK archive checksum mismatch; preparation refused')
    with tempfile.TemporaryDirectory(prefix='prepare-', dir=work) as staging:
        stage = Path(staging)
        raw = stage / 'archive'
        raw.mkdir()
        with tarfile.open(archive, 'r:xz') as source:
            for member in source:
                if not member.name.startswith('MobileVLCKit-binary/MobileVLCKit.xcframework/'):
                    continue
                destination = raw / member.name
                if not destination.resolve().is_relative_to(raw):
                    raise SystemExit('Archive path escaped staging directory')
                if member.isdev() or member.isfifo():
                    raise SystemExit('Unexpected special file in SDK archive')
                if member.issym() or member.islnk():
                    link = destination.parent / member.linkname if member.issym() else raw / member.linkname
                    if not link.resolve().is_relative_to(raw):
                        raise SystemExit('Archive link escaped staging directory')
                source.extract(member, raw)
        original = raw / 'MobileVLCKit-binary/MobileVLCKit.xcframework'
        frameworks = []
        for identifier, architectures in [('ios-arm64_armv7_armv7s', ['arm64']),
                ('ios-arm64_i386_x86_64-simulator', ['arm64', 'x86_64'])]:
            framework = stage / identifier / 'MobileVLCKit.framework'
            shutil.copytree(original / identifier / 'MobileVLCKit.framework', framework)
            normalize_header_imports(framework)
            binary = framework / 'MobileVLCKit'
            thin(binary, architectures)
            dsym = stage / identifier / 'MobileVLCKit.framework.dSYM'
            shutil.copytree(original / identifier / 'dSYMs/MobileVLCKit.framework.dSYM', dsym)
            thin(dsym / 'Contents/Resources/DWARF/MobileVLCKit', architectures)
            if uuids(binary) != uuids(dsym):
                raise SystemExit('Official framework / dSYM UUID mismatch')
            signature = framework / '_CodeSignature'
            if signature.exists():
                shutil.rmtree(signature)
            frameworks += ['-framework', str(framework), '-debug-symbols', str(dsym)]
        candidate = stage / 'MobileVLCKit.xcframework'
        subprocess.run(['xcodebuild', '-create-xcframework', *frameworks, '-output', str(candidate)], check=True)
        symbol_uuids = validate_symbols(candidate)
        binaries = {str(f.relative_to(candidate)): digest(f) for f in candidate.glob('*/MobileVLCKit.framework/MobileVLCKit')}
        symbols = {str(f.relative_to(candidate)): digest(f) for f in candidate.glob('*/dSYMs/MobileVLCKit.framework.dSYM/Contents/Resources/DWARF/MobileVLCKit')}
        if target.exists() and binaries != report['binaries']:
            raise SystemExit('Symbol migration changed framework binaries; preparation refused')
        report = {'preparationVersion': PREPARATION_VERSION, 'sdkVersion': pin['version'], 'archiveSHA256': pin['sha256'],
            'deviceArchitectures': ['arm64'], 'simulatorArchitectures': ['arm64', 'x86_64'],
            'transformation': TRANSFORMATION, 'headers': header_fingerprints(candidate),
            'binaries': binaries, 'symbols': symbols, 'uuids': symbol_uuids}
        candidate_stamp = stage / 'prepared-sdk.json'
        candidate_stamp.write_text(json.dumps(report, indent=2) + '\n')
        previous = stage / 'previous-sdk'
        if target.exists():
            target.replace(previous)
        try:
            candidate.replace(target)
            candidate_stamp.replace(stamp)
        except BaseException:
            if target.exists():
                shutil.rmtree(target)
            if previous.exists():
                previous.replace(target)
            raise
    print(target)
    return target


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, default=ROOT / '.build/CompatibilitySDK')
    parser.add_argument('--archive', type=Path)
    args = parser.parse_args()
    prepare(args.work, args.archive)
