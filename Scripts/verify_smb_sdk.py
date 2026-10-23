#!/usr/bin/env python3
"""Validate the pinned public SMB ABI without linking a second client library."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = {
    'smb2_init_context', 'smb2_destroy_context', 'smb2_get_fds', 'smb2_which_events',
    'smb2_service_fd', 'smb2_set_version', 'smb2_set_security_mode', 'smb2_set_timeout',
    'smb2_set_user', 'smb2_set_password', 'smb2_set_domain', 'smb2_set_seal',
    'smb2_connect_share_async', 'smb2_opendir_async', 'smb2_readdir', 'smb2_closedir',
    'smb2_stat_async', 'smb2_open_async', 'smb2_close_async', 'smb2_pread_async',
    'smb2_get_max_read_size', 'smb2_get_error',
}


def verify(sdk):
    manifest = json.loads((ROOT / 'Docs/Dependencies/libsmb2-4.0.0-headers.json').read_text())
    headers = ROOT / 'Glide/Services/SMB/Vendor'
    for name, expected in manifest['headers'].items():
        path = (headers / name).resolve()
        if not path.is_relative_to(headers.resolve()) or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError('SMB public header differs from pinned 4.0.0 source: ' + name)
    variants = {}
    for variant, architectures in [('ios-arm64', ['arm64']), ('ios-arm64_x86_64-simulator', ['arm64', 'x86_64'])]:
        binary = sdk / variant / 'MobileVLCKit.framework/MobileVLCKit'
        for arch in architectures:
            try:
                result = subprocess.run(['nm', '-arch', arch, '-gU', str(binary)], check=True, capture_output=True, text=True)
            except subprocess.CalledProcessError as error:
                raise ValueError(f'Cannot inspect SMB ABI for {variant}/{arch}') from error
            symbols = {line.split()[-1].removeprefix('_') for line in result.stdout.splitlines() if line.split()}
            missing = REQUIRED - symbols
            if missing:
                raise ValueError(f'{variant}/{arch} is missing SMB ABI: ' + ', '.join(sorted(missing)))
        variants[variant] = {'architectures': architectures, 'requiredSymbols': len(REQUIRED)}
    return {'component': 'libsmb2', 'version': '4.0.0', 'binaryProvider': 'MobileVLCKit 3.7.3', 'variants': variants, 'passed': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, default=ROOT / '.build/CompatibilitySDK/MobileVLCKit.xcframework')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    value = verify(args.sdk)
    encoded = json.dumps(value, indent=2) + '\n'
    if args.output:
        args.output.write_text(encoded)
    print(encoded, end='')
