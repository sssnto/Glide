#!/usr/bin/env python3
"""Compare old/new plugin publication over an isolated loopback SMB2 mount.
The container and paths are fixed authored QA resources, never a private NAS.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid
import jellyfin_rotation_fixture as fixture

container = 'glide-cifs-lock-qa'
config = Path('/tmp/GlideCIFSQA/config')
repo = Path(__file__).resolve().parents[1]
checks = []

def docker(*args):
    return subprocess.run(['docker', *args], check=True, capture_output=True).stdout

def check(value, name):
    if not value:
        raise RuntimeError(name)
    checks.append(name)

def ready():
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            token, user = fixture.login()
            if fixture.call('/GlideToolkit/Capabilities', token=token)['available']:
                return token, user
        except Exception:
            pass
        time.sleep(.5)
    raise RuntimeError('Isolated CIFS server startup timed out')

def digest(name):
    assert name in ['GlideRotation.mp4', 'GlideAlternate.mp4']
    raw = subprocess.run(['docker', 'exec', container, 'sha256sum', '/tmp/glide-authored-share/' + name], capture_output=True)
    return raw.stdout.decode().split()[0] if raw.returncode == 0 else None

def terminal(job, token):
    deadline = time.monotonic() + 90
    while job['state'] in ['queued', 'running', 'committing']:
        if time.monotonic() > deadline:
            raise RuntimeError('CIFS job timed out')
        time.sleep(.1)
        job = fixture.call('/GlideToolkit/Jobs/' + job['jobId'], token=token)
    return job

token, user = ready()
check(docker('exec', container, 'stat', '-f', '-c', '%T', '/media').decode().strip() == 'smb2', 'actual_kernel_smb2_mount')
cap = fixture.call('/GlideToolkit/Capabilities', token=token)
old = sys.argv[1] == 'before'
check(cap['pluginVersion'] == ('1.0.2' if old else '1.0.3'), 'expected_plugin_version_loaded')
fixture.call('/Library/Refresh', 'POST', {}, token)
deadline = time.monotonic() + 60
while time.monotonic() < deadline:
    item = next((x for x in fixture.items(token) if x['Name'] == 'GlideRotation'), None)
    if item:
        break
    time.sleep(.5)
else:
    raise RuntimeError('Authored CIFS media not indexed')
detail = fixture.call('/Items/' + item['Id'] + '?UserId=' + user, token=token)
source = detail['MediaSources'][0]['Id']
endpoint = '/GlideToolkit/Items/' + item['Id'] + '/Rotation?mediaSourceId=' + source
current = fixture.call(endpoint, token=token)
original = hashlib.sha256((repo / 'Glide/Resources/demo0.mp4').read_bytes()).hexdigest()
check(digest('GlideRotation.mp4') == original, 'authored_original_matches_fixture')
command = {'requestId': str(uuid.uuid4()), 'itemId': item['Id'], 'mediaSourceId': source,
           'expectedVersion': current['version'], 'quarterTurns': 1}
done = terminal(fixture.call('/GlideToolkit/Jobs', 'POST', command, token, expected=(202,)), token)
journal = json.loads((config / 'data/glide-rotation-jobs' / (done['jobId'].replace('-', '') + '.json')).read_text())
report = {'pluginVersion': cap['pluginVersion'], 'filesystem': 'smb2', 'state': done['state'],
          'errorCode': done.get('errorCode'), 'failureCode': journal.get('FailureCode'),
          'originalPathExistsAfterJob': digest('GlideRotation.mp4') is not None,
          'publicationMode': done.get('publicationMode'), 'checks': checks,
          'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
if old:
    check(done['state'] != 'completed', 'old_open_handle_publication_fails_on_real_smb2')
    report.update(passed=True, checks=checks)
else:
    check(done['state'] == 'completed' and done['canRestore'], 'new_plugin_rotates_with_backup_on_real_smb2')
    check(digest('GlideRotation.mp4') != original, 'smb2_output_direction_changes')
    check(digest('GlideAlternate.mp4') == original, 'other_smb2_file_unchanged')
    again = fixture.call('/GlideToolkit/Jobs', 'POST', command, token, expected=(202,))
    check(again['jobId'] == done['jobId'], 'smb2_rotation_is_idempotent')
    # A queued ffprobe refresh may briefly use the file after saving. A known
    # pre-publication busy rejection is safe to retry as a fresh restore job.
    for attempt in range(20):
        current = fixture.call(endpoint, token=token)
        restore = {'requestId': str(uuid.uuid4()), 'itemId': item['Id'], 'mediaSourceId': source,
                   'expectedVersion': current['version'], 'quarterTurns': 0, 'restoreJobId': done['jobId']}
        restored = terminal(fixture.call('/GlideToolkit/Jobs', 'POST', restore, token, expected=(202,)), token)
        if restored['state'] == 'completed':
            break
        if restored.get('errorCode') != 'file_busy':
            raise RuntimeError('CIFS restore failed: ' + str(restored.get('errorCode')))
        time.sleep(.5)
    check(restored['state'] == 'completed' and digest('GlideRotation.mp4') == original, 'smb2_restore_byte_identical')
    check(digest('GlideAlternate.mp4') == original, 'other_smb2_file_still_unchanged_after_restore')
    docker('exec', container, 'rm', '-f', '/tmp/glide-cifs-reader-ready', '/tmp/glide-cifs-reader-release')
    docker('exec', '-d', container, 'sh', '-c', 'set -e; exec 9< /media/GlideRotation.mp4; flock -s 9; touch /tmp/glide-cifs-reader-ready; while [ ! -f /tmp/glide-cifs-reader-release ]; do sleep .1; done; flock -u 9; exec 9<&-')
    try:
        deadline = time.monotonic() + 10
        while subprocess.run(['docker', 'exec', container, 'test', '-f', '/tmp/glide-cifs-reader-ready'], capture_output=True).returncode != 0:
            if time.monotonic() > deadline:
                raise RuntimeError('CIFS authored reader did not acquire lock')
            time.sleep(.1)
        current = fixture.call(endpoint, token=token)
        busy_command = {'requestId': str(uuid.uuid4()), 'itemId': item['Id'], 'mediaSourceId': source,
                        'expectedVersion': current['version'], 'quarterTurns': 1}
        busy = terminal(fixture.call('/GlideToolkit/Jobs', 'POST', busy_command, token, expected=(202,)), token)
        busy_journal = json.loads((config / 'data/glide-rotation-jobs' / (busy['jobId'].replace('-', '') + '.json')).read_text())
        check(busy['state'] == 'failed' and (busy.get('errorCode') == 'file_busy' or str(busy.get('errorCode')).startswith('file_lock_')), 'real_external_smb2_reader_refuses_publication')
        check(not busy_journal.get('BackupFile') and busy['progress'] == 0, 'smb2_busy_refused_before_backup_or_replacement')
        check(digest('GlideRotation.mp4') == original, 'smb2_busy_original_remains_byte_identical')
    finally:
        docker('exec', container, 'touch', '/tmp/glide-cifs-reader-release')
    report.update(passed=True, checks=checks, sourceSHA256=original)
Path('/tmp/GlideCIFSQA/' + ('Before.json' if old else 'After.json')).write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'phase': 'before' if old else 'after', 'state': done['state'], 'failureCode': report['failureCode'], 'checks': len(checks)}))
