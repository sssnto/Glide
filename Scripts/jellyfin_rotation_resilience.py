#!/usr/bin/env python3
"""Large-file/disconnected-client/restart acceptance on the fixed local QA container."""
import http.client
import json
from pathlib import Path
import struct
import subprocess
import sys
import time
import uuid
import jellyfin_rotation_fixture as fixture

shared='--shared-mount' in sys.argv
cifs='--cifs' in sys.argv
name='GlideCIFSLargeRotation' if cifs else 'GlideSharedLargeRotation' if shared else 'GlideNativeLargeRotation'
file=Path('/tmp/GlideJellyfinQA/media' if shared else '/tmp/GlideJellyfinTools')/(name+'.mp4')
container_file=('/media/' if shared or cifs else '/tmp/glide-native-media/')+name+'.mp4'
container='glide-cifs-lock-qa' if cifs else 'glide-rotation-jellyfin-122'
base=Path(__file__).resolve().parents[1]/'Glide/Resources/demo0.mp4'
with file.open('wb') as stream:
    stream.write(base.read_bytes());stream.write(struct.pack('>I4s',512*1024*1024+8,b'free'));stream.truncate(stream.tell()+512*1024*1024)
def digest():
    return subprocess.run(['docker','exec',container,'sha256sum',container_file],capture_output=True,text=True,check=True).stdout.split()[0]
if not shared:
    target=('/tmp/glide-authored-share/'+name+'.mp4') if cifs else container_file
    subprocess.run(['docker','cp',str(file),container+':'+target],check=True)
    if cifs:
        subprocess.run(['docker','exec',container,'chown','1000:1000',target],check=True)
        subprocess.run(['docker','exec',container,'chmod','755',target],check=True)
token,user=fixture.login();fixture.call('/Library/Refresh','POST',{},token)
deadline=time.monotonic()+90
while time.monotonic()<deadline:
    item=next((x for x in fixture.items(token) if x['Name']==name),None)
    if item:break
    time.sleep(.5)
else:raise RuntimeError('Large authored fixture scan timed out')
detail=fixture.call('/Items/'+item['Id']+'?UserId='+user,token=token)
source=detail['MediaSources'][0]['Id']
endpoint='/GlideToolkit/Items/'+item['Id']+'/Rotation?mediaSourceId='+source
cap=fixture.call(endpoint,token=token)
request={'requestId':str(uuid.uuid4()),'itemId':item['Id'],'mediaSourceId':source,'expectedVersion':cap['version'],'quarterTurns':1}
original=digest();body=json.dumps(request).encode()
# Wait only for acceptance headers, then disconnect before reading the JSON
# response. A connection closed before acceptance may correctly enqueue nothing.
connection=http.client.HTTPConnection('127.0.0.1',8830,timeout=15)
connection.request('POST','/GlideToolkit/Jobs',body,{'Content-Type':'application/json','Authorization':fixture.AUTH+', Token="'+token+'"'})
response=connection.getresponse()
if response.status!=202:raise RuntimeError('Detached command was not accepted: '+str(response.status))
connection.close()
job=None;deadline=time.monotonic()+60
while time.monotonic()<deadline:
    jobs=fixture.call('/GlideToolkit/Items/'+item['Id']+'/Jobs?mediaSourceId='+source,token=token)
    job=next((x for x in jobs if x['requestId'].lower()==request['requestId'].lower()),None)
    if job:break
    time.sleep(.25)
if job is None:raise RuntimeError('Detached command did not enqueue')
done=fixture.wait(job,token)
if shared or cifs:assert done.get('publicationMode')=='SameDirectoryRename'
rotated=digest()
assert rotated!=original
subprocess.run(['docker','restart',container],stdout=subprocess.DEVNULL,check=True)
if cifs:
    subprocess.run(['docker','exec',container,'smbd','-D','-s','/tmp/glide-smb.conf'],check=True)
    time.sleep(1)
    subprocess.run(['docker','exec',container,'mount','-i','-t','cifs','//127.0.0.1/authored','/media','-o',
        'username=glidecifs,password=Authored-CIFS-QA-only,addr=127.0.0.1,port=1449,vers=3.0,uid=1000,gid=1000,file_mode=0755,dir_mode=0755,cache=none,actimeo=0'],check=True)
    subprocess.run(['docker','exec',container,'sh','-c','/jellyfin/jellyfin --datadir /config --cachedir /cache --ffmpeg /usr/lib/jellyfin-ffmpeg/ffmpeg > /tmp/glide-jellyfin.log 2>&1 & echo $! > /tmp/glide-jellyfin.pid'],check=True)
deadline=time.monotonic()+45
while time.monotonic()<deadline:
    try:
        if fixture.call('/GlideToolkit/Capabilities',token=token)['available']:break
    except Exception:pass
    time.sleep(.5)
else:raise RuntimeError('Restart recovery timed out')
again=fixture.call('/GlideToolkit/Jobs','POST',request,token,expected=(202,))
assert again['jobId']==done['jobId'] and again['state']=='completed' and digest()==rotated
for attempt in range(20):
    current=fixture.call(endpoint,token=token)
    restore={'requestId':str(uuid.uuid4()),'itemId':item['Id'],'mediaSourceId':source,'expectedVersion':current['version'],'quarterTurns':0,'restoreJobId':done['jobId']}
    restored=fixture.call('/GlideToolkit/Jobs','POST',restore,token,expected=(202,))
    deadline=time.monotonic()+120
    while restored['state'] in ['queued','running','committing']:
        if time.monotonic()>deadline:raise RuntimeError('Large restore timed out')
        time.sleep(.2);restored=fixture.call('/GlideToolkit/Jobs/'+restored['jobId'],token=token)
    if restored['state']=='completed':break
    if restored.get('errorCode')!='file_busy':raise RuntimeError('Large restore failed: '+str(restored.get('errorCode')))
    time.sleep(.5)
assert restored['state']=='completed'
assert digest()==original
report={'passed':True,'fileBytes':file.stat().st_size,'phoneCommandBytes':len(body),'checks':[
    '512_MiB_file_processed_on_server_without_phone_media_transfer','job_continues_after_client_disconnect_before_response',
    'job_and_backup_survive_actual_jellyfin_container_restart','same_request_after_restart_does_not_rotate_again','large_original_restored_with_exact_SHA256'],
    'publicationMode':done.get('publicationMode'),'sharedMount':shared,'cifs':cifs,
    'timestamp':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
Path('/tmp/GlideJellyfinTools/'+('103-cifs-large-report.json' if cifs else 'shared-large-report.json' if shared else 'server-resilience-report.json')).write_text(json.dumps(report,indent=2)+'\n')
# Remove only this run's exact authored file and backup/stage names after all
# assertions pass. Leave durable completed journals and unrelated files intact.
owned=[container_file]
for job in [done,restored]:
    work=container_file.rsplit('/',1)[0]+'/.glide-rotation/'
    owned.append(work+job['jobId'].replace('-','')+'.bak')
    if job.get('publicationMode')=='Exchange':owned.append(work+job['jobId'].replace('-','')+'.part')
subprocess.run(['docker','exec',container,'rm','--',*owned],check=True)
if file.exists():file.unlink()
print('Passed '+str(len(report['checks']))+' large-file and restart checks')
