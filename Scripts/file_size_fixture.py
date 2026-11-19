#!/usr/bin/env python3
"""Prepare varied-size authored MP4s only in the existing fixed loopback fixture."""
import json, struct, time
from pathlib import Path
import file_management_fixture as fixture

root = fixture.WORK / 'media/size-sort'
root.mkdir(parents=True, exist_ok=True)
sample = (fixture.ROOT / 'Server/test-media/original.mp4').read_bytes()
for index in range(205):
    padding = b'\0' * (index * 1024)
    expected = sample + struct.pack('>I4s', len(padding) + 8, b'free') + padding
    path = root / ('size%03d.mp4' % index)
    if not path.exists(): path.write_bytes(expected)
    if path.read_bytes() != expected: raise RuntimeError('Authored fixture file changed')
token, user = fixture.login()
config = fixture.call('/Plugins/'+fixture.PLUGIN+'/Configuration',token=token)
config['FileManagementEnabled'] = True
fixture.call('/Plugins/'+fixture.PLUGIN+'/Configuration','POST',config,token)
fixture.call('/Library/Refresh', 'POST', {}, token)
limit = time.monotonic() + 120
while True:
    pending = [None]
    folder = None
    while pending and folder is None:
        parent = pending.pop(0)
        route = '/GlideToolkit/FileManagement/Folders' + (('?parent='+parent) if parent else '')
        for child in fixture.call(route,token=token)['folders']:
            if child['name'] == 'size-sort': folder = child['id']; break
            pending.append(child['id'])
        if len(pending)>30: raise RuntimeError('Fixture folder walk left authored scope')
    page = fixture.call('/Items?ParentId='+folder+'&IsFolder=false&Fields=MediaSources&Limit=500',token=token) if folder else {'Items':[]}
    items = [x for x in page['Items'] if x.get('Name', '').startswith('size') and x.get('Type') == 'Video']
    if len(items) == 205 and all((x.get('MediaSources') or [{}])[0].get('Size') for x in items): break
    if time.monotonic() > limit: raise RuntimeError('Authored size fixture not fully indexed')
    time.sleep(1)
for item in items:
    index = int(item['Name'][4:])
    assert item['MediaSources'][0]['Size'] == (root / ('size%03d.mp4' % index)).stat().st_size
out = fixture.ROOT / 'Docs/Testing/File-Size-Sort-2026-11-16'
out.mkdir(parents=True, exist_ok=True)
(out / 'Server-Metadata.json').write_text(json.dumps({'passed':True,'serverVersion':'12.2.0','scope':'Authored localhost fixture only','videoCount':205,'checks':['mp4_free_padding_preserves_authored_media','default_media_source_size_matches_file_bytes','catalog_exceeds_first_200_item_page']}, indent=2)+'\n')
print('Verified byte sizes for 205 authored Jellyfin videos')
