#!/usr/bin/env python3
"""Bounded localhost-only queue/thumbnail validation with authored videos.
Does not read saved application credentials or target a private server.
"""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import time
import urllib.request
import urllib.parse
import uuid
import jellyfin_rotation_fixture as api

CONTAINER = 'glide-rotation-jellyfin-122'
MEDIA = '/tmp/glide-native-media'
PREFIX = 'GlideBatchQA'
checks = []

def docker(*args):
    return subprocess.check_output(['docker', *args], stderr=subprocess.STDOUT)

def check(ok, name):
    if not ok:
        raise RuntimeError(name)
    checks.append(name)

def wait_for(predicate, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.25)
    raise RuntimeError('fixture_timeout')

def status(batch):
    return api.call('/GlideToolkit/Batches/' + batch, token=token)

def file_digest(path):
    return docker('exec', CONTAINER, 'sha256sum', path).decode().split()[0]

def probe(path):
    result = json.loads(docker('exec', CONTAINER, '/usr/lib/jellyfin-ffmpeg/ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height:stream_side_data=rotation', '-of', 'json', path))['streams'][0]
    angle = next((s.get('rotation', 0) for s in result.get('side_data_list', []) if 'rotation' in s), 0)
    return result['width'], result['height'], angle

def jpeg_size(data):
    assert data[:2] == b'\xff\xd8'
    i = 2
    while i < len(data):
        if data[i] != 255:
            i += 1
            continue
        marker = data[i+1]; i += 2
        if marker in (0xD8, 0xD9):
            continue
        length = int.from_bytes(data[i:i+2], 'big')
        if marker in (0xC0, 0xC1, 0xC2):
            return int.from_bytes(data[i+5:i+7], 'big'), int.from_bytes(data[i+3:i+5], 'big')
        i += length
    raise RuntimeError('invalid_preview_jpeg')

def image(item, revision):
    request = urllib.request.Request(api.ROOT + '/GlideToolkit/Items/' + item + '/RotationPreview?' + urllib.parse.urlencode({'revision': revision}), headers={'Authorization': api.AUTH + ', Token="' + token + '"'})
    with urllib.request.urlopen(request, timeout=40) as response:
        return response.read()

def states(ids):
    return api.call('/GlideToolkit/Items/RotationStates', 'POST', {'itemIds': ids}, token)

if __name__ == '__main__':
    output = Path(__import__('sys').argv[1])
    token, user = api.login()
    cap = api.call('/GlideToolkit/Capabilities', token=token)
    check(cap['pluginVersion'] == '1.1.0' and cap['available'], 'batch_plugin_110_available')
    # Use the existing isolated native Linux library, never a production mount.
    source = Path('/tmp/GlideBatchAuthored.mp4')
    original = Path('Glide/Resources/demo0.mp4').read_bytes()
    source.write_bytes(original)
    paths = []
    for number in range(3):
        path = f'{MEDIA}/{PREFIX}{number}.mp4'
        docker('cp', str(source), CONTAINER + ':' + path)
        paths.append(path)
    # A legal MP4 free box makes this a real large-file backup/check without a
    # copyrighted sample or an expensive encode. Append 64 MiB sparsely.
    docker('exec', CONTAINER, 'sh', '-c', "printf '\\004\\000\\000\\000free' >> /tmp/glide-native-media/GlideBatchQA2.mp4; truncate -s 67167183 /tmp/glide-native-media/GlideBatchQA2.mp4")
    originals = [file_digest(p) for p in paths]
    angles = [probe(p)[2] for p in paths]
    api.call('/Library/Refresh', 'POST', {}, token)
    def indexed():
        found = {i['Name']: i for i in api.items(token) if i['Name'].startswith(PREFIX)}
        return found if len(found) == 3 else None
    found = wait_for(indexed)
    ids = [found[PREFIX + str(i)]['Id'] for i in range(3)]
    request = {'requestId': str(uuid.uuid4()), 'quarterTurns': 1, 'items': [{'itemId': i, 'title': PREFIX + str(n)} for n, i in enumerate(ids)] + [{'itemId': uuid.uuid4().hex, 'title': 'Authored missing item'}]}
    created = api.call('/GlideToolkit/Batches', 'POST', request, token, expected=(202,))
    batch = created['batchId']
    repeated = api.call('/GlideToolkit/Batches', 'POST', request, token, expected=(202,))
    check(repeated['batchId'] == batch, 'http_batch_submit_is_idempotent')
    conflict = dict(request, quarterTurns=2)
    api.call('/GlideToolkit/Batches', 'POST', conflict, token, expected=(409,)); check(True, 'http_changed_body_rejected')
    api.call('/GlideToolkit/Batches/' + batch + '/pause', 'POST', {}, token)
    paused = wait_for(lambda: (b if (b := status(batch))['state'] == 'paused' else None))
    brief = api.call('/GlideToolkit/Batches/' + batch + '?includeItems=false', token=token)
    check(brief.get('items') is None and brief['total'] == 4, 'progress_poll_omits_thousand_item_detail_payload')
    check(paused['remaining'] > 0, 'http_pause_keeps_pending_files')
    before_restart = paused['completed']
    docker('restart', CONTAINER)
    def ready():
        try:
            return api.call('/GlideToolkit/Capabilities', token=token).get('available')
        except Exception:
            return False
    wait_for(ready)
    paused = status(batch)
    check(paused['state'] == 'paused' and paused['completed'] == before_restart, 'real_container_restart_preserves_paused_queue')
    api.call('/GlideToolkit/Batches/' + batch + '/resume', 'POST', {}, token)
    done = wait_for(lambda: (b if (b := status(batch))['state'] == 'finished' else None), 180)
    check(done['completed'] == 3 and done['failed'] == 1 and done['remaining'] == 0, 'batch_counts_include_missing_item_without_aborting_valid_videos')
    check(sum(1 for e in done['items'] if e['state'] == 'completed') == 3, 'detail_matches_summary_counts')
    rotated = states(ids)
    dashed = states([str(uuid.UUID(ids[0]))])
    check(len(dashed) == 1 and dashed[0]['itemId'] == ids[0], 'item_status_accepts_canonical_and_dashed_ids')
    check(len(rotated) == 3 and all(s['revision'] and s['state'] == 'completed' for s in rotated), 'list_states_include_saved_revision_and_badge')
    image_before_restore = image(ids[0], next(s['revision'] for s in rotated if s['itemId'] == ids[0]))
    w, h = jpeg_size(image_before_restore)
    check(w > h, 'regenerated_preview_applies_saved_rotation_matrix')
    check(image(ids[0], next(s['revision'] for s in rotated if s['itemId'] == ids[0])) == image_before_restore, 'derived_preview_is_cached')
    for n, path in enumerate(paths):
        check((probe(path)[2] - angles[n]) % 360 == 270, 'server_saved_clockwise_once_' + str(n))
    before_retry = [file_digest(p) for p in paths]
    api.call('/GlideToolkit/Batches/' + batch + '/retry', 'POST', {}, token)
    retry = wait_for(lambda: (b if (b := status(batch))['state'] == 'finished' else None))
    check(retry['completed'] == 3 and retry['failed'] == 1 and [file_digest(p) for p in paths] == before_retry, 'http_retry_does_not_repeat_successful_rotations')
    # Restore exact bytes through the same safe worker and assert a new preview
    # revision as well as correct upright image geometry.
    for entry in done['items']:
        if entry['state'] != 'completed':
            continue
        item = entry['itemId']; source_id = entry['mediaSourceId']
        inspect = api.call('/GlideToolkit/Items/' + item + '/Rotation?mediaSourceId=' + source_id, token=token)
        body = {'requestId': str(uuid.uuid4()), 'itemId': item, 'mediaSourceId': source_id, 'expectedVersion': inspect['version'], 'quarterTurns': 0, 'restoreJobId': entry['jobId']}
        restored = api.wait(api.call('/GlideToolkit/Jobs', 'POST', body, token, expected=(202,)), token)
        check(restored['state'] == 'completed', 'batch_child_backup_can_be_restored_' + item[:6])
    after = states(ids)
    first = next(s for s in after if s['itemId'] == ids[0])
    restored_image = image(ids[0], first['revision'])
    w, h = jpeg_size(restored_image)
    check(h > w and restored_image != image_before_restore and first['restored'], 'restore_changes_revision_badge_and_preview_geometry')
    check([file_digest(p) for p in paths] == originals, 'all_batch_videos_restore_byte_identically_including_large_file')
    reader = api.call('/Users/AuthenticateByName', 'POST', {'Username': 'glide-rotation-reader', 'Pw': ''})['AccessToken']
    api.call('/GlideToolkit/Batches', token=reader, expected=(403,)); check(True, 'unauthorized_user_cannot_read_or_dispatch_batches')
    # Remove only these fixed authored test files and their own child artifacts.
    for path in paths:
        docker('exec', CONTAINER, 'rm', '--', path)
    for entry in done['items']:
        if entry['state'] != 'completed':
            continue
        jobs = api.call('/GlideToolkit/Items/' + entry['itemId'] + '/Jobs?mediaSourceId=' + entry['mediaSourceId'], token=token)
        for job in jobs:
            job_id = job['jobId'].replace('-', '')
            for artifact in (f'{MEDIA}/.glide-rotation/{job_id}.bak', f'{MEDIA}/.glide-rotation/{job_id}.part', f'{MEDIA}/.glide-rotation-{job_id}.part'):
                docker('exec', CONTAINER, 'rm', '-f', '--', artifact)
    source.unlink()
    api.call('/Library/Refresh', 'POST', {}, token)
    wait_for(lambda: not any(i['Name'].startswith(PREFIX) for i in api.items(token)))
    output.write_text(json.dumps({'passed': True, 'serverVersion': '12.2.0', 'pluginVersion': '1.1.0', 'checks': checks, 'largeFixtureBytes': 67167183, 'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}, indent=2) + '\n')
    print('Passed', len(checks), 'official Jellyfin batch/thumbnail checks')
