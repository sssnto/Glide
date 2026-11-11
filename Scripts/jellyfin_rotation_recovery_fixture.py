#!/usr/bin/env python3
"""Regression of the missing-original incident, on localhost authored media only."""
import hashlib
import json
from pathlib import Path
import subprocess
import time
import uuid
import xml.etree.ElementTree as ET
import jellyfin_rotation_fixture as fixture

CONTAINER = 'glide-rotation-jellyfin-122'
MEDIA = '/tmp/glide-native-media'
VIDEO = MEDIA + '/GlideNativeRotation.mp4'
JOURNALS = Path('/tmp/GlideJellyfinQA/config/data/glide-rotation-jobs')
checks = []

def check(value, name):
    if not value:
        raise RuntimeError(name)
    checks.append(name)

def docker(*args):
    return subprocess.run(['docker', *args], check=True, capture_output=True).stdout

def digest(path):
    assert path.startswith(MEDIA + '/')
    return docker('exec', CONTAINER, 'sha256sum', path).decode().split()[0]

def ready(token):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            if fixture.call('/GlideToolkit/Capabilities', token=token)['available']:
                return
        except Exception:
            pass
        time.sleep(.5)
    raise RuntimeError('Local plugin startup timed out')

authored = Path(__file__).resolve().parents[1] / 'Glide/Resources/demo0.mp4'
docker('exec', CONTAINER, 'mkdir', '-p', MEDIA)
exists = subprocess.run(['docker', 'exec', CONTAINER, 'test', '-f', VIDEO], capture_output=True)
if exists.returncode == 1:
    docker('cp', str(authored), CONTAINER + ':' + VIDEO)
elif exists.returncode != 0:
    raise RuntimeError('Authored fixture filesystem check failed')
elif digest(VIDEO) != hashlib.sha256(authored.read_bytes()).hexdigest():
    raise RuntimeError('Existing authored test fixture differs; inspect previous test before replacing it')

deadline = time.monotonic() + 60
while True:
    try:
        token, user = fixture.login()
        break
    except Exception:
        if time.monotonic() >= deadline:
            raise
        time.sleep(.5)
# Docker Desktop's shared mount does not implement exchange correctly. 1.0.2
# must select the separately probed same-parent native rename, never managed copy.
unsafe = next(x for x in fixture.items(token) if x['Name'] == 'GlideRotation')
unsafe_file = Path('/tmp/GlideJellyfinQA/media/GlideRotation.mp4')
unsafe_before = hashlib.sha256(unsafe_file.read_bytes()).hexdigest()
unsafe_detail = fixture.call('/Items/' + unsafe['Id'] + '?UserId=' + user, token=token)
unsafe_source = unsafe_detail['MediaSources'][0]['Id']
unsafe_cap = fixture.call('/GlideToolkit/Items/' + unsafe['Id'] + '/Rotation?mediaSourceId=' + unsafe_source, token=token)
unsafe_job = fixture.call('/GlideToolkit/Jobs', 'POST', {'requestId': str(uuid.uuid4()), 'itemId': unsafe['Id'],
    'mediaSourceId': unsafe_source, 'expectedVersion': unsafe_cap['version'], 'quarterTurns': 1}, token, expected=(202,))
unsafe_job = fixture.wait(unsafe_job, token)
check(unsafe_job['publicationMode'] == 'SameDirectoryRename', 'exchange_incompatible_mount_uses_probed_same_directory_native_rename')
check(hashlib.sha256(unsafe_file.read_bytes()).hexdigest() != unsafe_before, 'same_directory_rename_changes_authored_shared_mount_file')
unsafe_cap = fixture.call('/GlideToolkit/Items/' + unsafe['Id'] + '/Rotation?mediaSourceId=' + unsafe_source, token=token)
fixture.wait(fixture.call('/GlideToolkit/Jobs', 'POST', {'requestId': str(uuid.uuid4()), 'itemId': unsafe['Id'],
    'mediaSourceId': unsafe_source, 'expectedVersion': unsafe_cap['version'], 'quarterTurns': 0, 'restoreJobId': unsafe_job['jobId']}, token, expected=(202,)), token)
check(hashlib.sha256(unsafe_file.read_bytes()).hexdigest() == unsafe_before, 'shared_mount_fallback_restore_is_byte_identical')
folders = fixture.call('/Library/VirtualFolders', token=token)
if not any(MEDIA in folder.get('Locations', []) for folder in folders):
    fixture.call('/Library/VirtualFolders?name=Native%20Recovery&collectionType=movies&refreshLibrary=true', 'POST',
        {'LibraryOptions': {'PathInfos': [{'Path': MEDIA}], 'EnableRealtimeMonitor': False, 'EnableInternetProviders': False}}, token)
fixture.call('/Library/Refresh', 'POST', {}, token)
deadline = time.monotonic() + 90
while time.monotonic() < deadline:
    item = next((x for x in fixture.items(token) if x['Name'] == 'GlideNativeRotation'), None)
    if item:
        break
    time.sleep(.5)
else:
    raise RuntimeError('Native authored fixture scan timed out')
detail = fixture.call('/Items/' + item['Id'] + '?UserId=' + user, token=token)
source = detail['MediaSources'][0]['Id']
endpoint = '/GlideToolkit/Items/' + item['Id'] + '/Rotation?mediaSourceId=' + source
cap = fixture.call(endpoint, token=token)
expected_version = ET.parse(Path(__file__).resolve().parents[1] / 'Server/Jellyfin.Plugin.GlideToolkit/Jellyfin.Plugin.GlideToolkit.csproj').findtext('.//Version')
check(cap['pluginVersion'] == expected_version, 'patched_plugin_loaded')
original = digest(VIDEO)
metadata = docker('exec', CONTAINER, 'stat', '-c', '%u:%g:%a', VIDEO)
request = {'requestId': str(uuid.uuid4()), 'itemId': item['Id'], 'mediaSourceId': source, 'expectedVersion': cap['version'], 'quarterTurns': 1}
done = fixture.wait(fixture.call('/GlideToolkit/Jobs', 'POST', request, token, expected=(202,)), token)
rotated = digest(VIDEO)
check(rotated != original and done['canRestore'], 'native_linux_atomic_rotation_completes')
journal = JOURNALS / (done['jobId'].replace('-', '') + '.json')
job = json.loads(journal.read_text())
check(digest(job['StageFile']) == original and digest(job['BackupFile']) == original, 'atomic_exchange_keeps_two_original_copies')
check(docker('exec', CONTAINER, 'stat', '-c', '%u:%g:%a', job['BackupFile']) == metadata, 'backup_preserves_original_ownership_and_permissions')
probe = json.loads(docker('exec', CONTAINER, '/usr/lib/jellyfin-ffmpeg/ffprobe', '-v', 'error', '-show_streams', '-of', 'json', VIDEO))
check(any(s['codec_type'] == 'video' for s in probe['streams']), 'rotated_native_file_remains_decodable')
same = fixture.call('/GlideToolkit/Jobs', 'POST', request, token, expected=(202,))
check(same['jobId'] == done['jobId'] and digest(VIDEO) == rotated, 'new_publication_remains_idempotent')
current = fixture.call(endpoint, token=token)
restore = {'requestId': str(uuid.uuid4()), 'itemId': item['Id'], 'mediaSourceId': source,
           'expectedVersion': current['version'], 'quarterTurns': 0, 'restoreJobId': done['jobId']}
fixture.wait(fixture.call('/GlideToolkit/Jobs', 'POST', restore, token, expected=(202,)), token)
check(digest(VIDEO) == original, 'native_linux_normal_restore_is_byte_identical')
current = fixture.call(endpoint, token=token)
request.update(requestId=str(uuid.uuid4()), expectedVersion=current['version'])
done = fixture.wait(fixture.call('/GlideToolkit/Jobs', 'POST', request, token, expected=(202,)), token)
journal = JOURNALS / (done['jobId'].replace('-', '') + '.json')
job = json.loads(journal.read_text())

# Simulate precisely the old failure's two retained files and missing path.
docker('cp', CONTAINER + ':' + VIDEO, '/tmp/GlideJellyfinTools/recovery-rotated.mp4')
docker('cp', '/tmp/GlideJellyfinTools/recovery-rotated.mp4', CONTAINER + ':' + job['StageFile'])
docker('exec', CONTAINER, 'rm', '--', VIDEO)
docker('stop', CONTAINER)
job.update(State='needs_verification', Stage='needs_verification', ErrorCode='uncertain_commit', BackupMetadataPreserved=False)
journal.write_text(json.dumps(job))
docker('start', CONTAINER)
ready(token)
fixture.call('/Library/Refresh', 'POST', {}, token)
deadline = time.monotonic() + 60
while time.monotonic() < deadline:
    if not any(x['Id'] == item['Id'] for x in fixture.items(token)):
        break
    time.sleep(.5)
else:
    raise RuntimeError('Authored missing item was not removed by scan')
check(True, 'legacy_failure_reproduced_with_item_removed_from_library')

recovery = '/GlideToolkit/Jobs/' + done['jobId']
status = fixture.call(recovery + '/Recovery', token=token)
check(status['canRecoverMissing'] and status['backupExists'] and not status['originalExists'], 'recovery_works_without_indexed_item')
history = fixture.call('/GlideToolkit/Items/' + item['Id'] + '/Jobs?mediaSourceId=' + source, token=token)
check(any(j['jobId'] == done['jobId'] for j in history), 'own_job_history_does_not_require_existing_media')
if not any(x['Name'] == 'glide-rotation-reader' for x in fixture.call('/Users', token=token)):
    fixture.call('/Users/New', 'POST', {'Name': 'glide-rotation-reader'}, token)
reader = fixture.call('/Users/AuthenticateByName', 'POST', {'Username': 'glide-rotation-reader', 'Pw': ''})['AccessToken']
fixture.call(recovery + '/Recovery', token=reader, expected=(403,))
fixture.call(recovery + '/RecoverMissing', 'POST', {'confirmed': True}, reader, expected=(403,))
check(True, 'ordinary_user_cannot_inspect_or_execute_emergency_restore')
fixture.call(recovery + '/RecoverMissing', 'POST', {'confirmed': False}, token, expected=(409,))
check(True, 'explicit_recovery_confirmation_required')
config_path = '/Plugins/9e405477-411c-4c2b-8541-c3b5925f7169/Configuration'
config = fixture.call(config_path, token=token)
try:
    disabled = dict(config, Enabled=False)
    fixture.call(config_path, 'POST', disabled, token)
    recovered = fixture.call(recovery + '/RecoverMissing', 'POST', {'confirmed': True}, token)
    check(recovered['originalRestored'] and digest(VIDEO) == original, 'exact_backup_restored_even_when_normal_writes_disabled')
finally:
    fixture.call(config_path, 'POST', config, token)
check(digest(job['BackupFile']) == original and digest(job['StageFile']) == rotated, 'emergency_restore_retains_backup_and_processed_stage')
again = fixture.call(recovery + '/RecoverMissing', 'POST', {'confirmed': True}, token)
check(again['originalRestored'] and digest(VIDEO) == original, 'repeated_emergency_restore_does_not_write_again')
docker('cp', '/tmp/GlideJellyfinTools/recovery-rotated.mp4', CONTAINER + ':' + VIDEO)
fixture.call(recovery + '/RecoverMissing', 'POST', {'confirmed': True}, token, expected=(409,))
check(digest(VIDEO) == rotated, 'existing_different_file_is_never_overwritten')
# Return this authored fixture to its exact initial bytes, not a private file.
docker('cp', str(Path(__file__).resolve().parents[1] / 'Glide/Resources/demo0.mp4'), CONTAINER + ':' + VIDEO)
check(digest(VIDEO) == original, 'authored_fixture_returned_to_initial_bytes')
# A user may copy the backup manually, as in the reported incident. Clear only
# that task's uncertain state after the exact digest matches; don't write media.
docker('stop', CONTAINER)
job.update(State='needs_verification', Stage='needs_verification', ErrorCode='uncertain_commit')
journal.write_text(json.dumps(job))
docker('start', CONTAINER)
ready(token)
# Startup may reconcile an identical original immediately. Recovery stays
# idempotent and still works after this read-only reconciliation.
manual = fixture.call(recovery + '/RecoverMissing', 'POST', {'confirmed': True}, token)
check(manual['originalRestored'] and manual['state'] == 'failed' and digest(VIDEO) == original, 'manual_nas_copy_reconciliation_is_read_only')
jobs = fixture.call('/GlideToolkit/Recovery/Jobs', token=token)
check(not any(x in json.dumps(jobs) for x in ['/media/', '/tmp/', '.bak', 'Token=', 'password']), 'recovery_api_exports_no_paths_or_credentials')
report = {'passed': True, 'checks': checks, 'originalSHA256': original, 'rotatedSHA256': rotated,
          'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
Path('/tmp/GlideJellyfinTools/repair-recovery-api-report.json').write_text(json.dumps(report, indent=2) + '\n')
print('Passed ' + str(len(checks)) + ' official-server recovery checks')
