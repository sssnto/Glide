#!/usr/bin/env python3
"""Bootstrap/verify an isolated official Jellyfin 12.2 with authored media only.
Never targets a saved/private server and never prints its local fixture token.
The original verify command requires correct native atomic filesystem support.
Docker Desktop shared media mounts may be refused by 1.0.1: use
jellyfin_rotation_recovery_fixture.py to test both refusal and native success.
"""
import argparse
import hashlib
import os
import stat
import subprocess
import json
from pathlib import Path
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = 'http://127.0.0.1:8830'
AUTH = 'MediaBrowser Client="GlideServerQA", Device="AuthoredFixture", DeviceId="glide-rotation-'+str(uuid.uuid4())+'", Version="1.0"'
USERNAME = 'glide-rotation-admin'
PASSWORD = 'Authored-Glide-rotation-only-122'

def call(path, method='GET', body=None, token=None, expected=(200,204)):
    data = None if body is None else json.dumps(body).encode()
    headers = {'Authorization': AUTH + (', Token="'+token+'"' if token else ''), 'Content-Type':'application/json'}
    request = urllib.request.Request(ROOT+path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request,timeout=30) as response: status,raw=response.status,response.read()
    except urllib.error.HTTPError as error: status,raw=error.code,error.read()
    if status not in expected:
        code = json.loads(raw).get('errorCode','') if raw[:1]==b'{' else ''
        raise RuntimeError('Fixture request failed: '+str(status)+' '+code+' '+path.split('?')[0])
    return json.loads(raw) if raw and raw[:1] in (b'{',b'[') else None

def login():
    result=call('/Users/AuthenticateByName','POST',{'Username':USERNAME,'Pw':PASSWORD})
    return result['AccessToken'],result['User']['Id']

def items(token):
    return call('/Items?Recursive=true&IncludeItemTypes=Video,Movie&Fields=MediaSources&Limit=100',token=token)['Items']

def bootstrap():
    info=call('/System/Info/Public')
    if not info.get('StartupWizardCompleted'):
        call('/Startup/Configuration','POST',{'UICulture':'en-US','MetadataCountryCode':'US','PreferredMetadataLanguage':'en'})
        call('/Startup/FirstUser')
        call('/Startup/User','POST',{'Name':USERNAME,'Password':PASSWORD})
        call('/Startup/RemoteAccess','POST',{'EnableRemoteAccess':True,'EnableAutomaticPortMapping':False})
        call('/Startup/Complete','POST',{})
    token,user=login()
    folders=call('/Library/VirtualFolders',token=token)
    if not any('/media' in folder.get('Locations',[]) for folder in folders):
        call('/Library/VirtualFolders?name=Original%20Rotation&collectionType=movies&refreshLibrary=true','POST',
             {'LibraryOptions':{'PathInfos':[{'Path':'/media'}],'EnableRealtimeMonitor':False,'EnableInternetProviders':False,'EnableAutomaticSeriesGrouping':False}},token)
    call('/Library/Refresh','POST',{},token,expected=(200,204))
    deadline=time.monotonic()+90
    while time.monotonic()<deadline:
        found=items(token)
        if len(found)>=2:break
        time.sleep(1)
    else:raise RuntimeError('Authored library scan timed out')
    print(json.dumps({'serverVersion':info['Version'],'authoredItems':len(found),'ready':True}))

def wait(job,token):
    deadline=time.monotonic()+90
    while job['state'] in ['queued','running','committing']:
        if time.monotonic()>deadline:raise RuntimeError('Server job timed out')
        time.sleep(.1);job=call('/GlideToolkit/Jobs/'+job['jobId'],token=token)
    if job['state']!='completed':raise RuntimeError('Server job did not complete: '+str(job.get('errorCode')))
    return job

def verify(root,output):
    token,user=login();checks=[]
    def check(result,name):
        if not result:raise RuntimeError(name)
        checks.append(name)
    cap=call('/GlideToolkit/Capabilities',token=token)
    check(cap['available'] and cap['protocolVersion']==1,'plugin_loaded_by_official_jellyfin_12_2')
    check(cap.get('supportedExtensions')==['mp4','mov','m4v'],'bounded_lossless_formats')
    found=items(token)
    item=next(x for x in found if x['Name']=='GlideRotation')
    detail=call('/Items/'+item['Id']+'?UserId='+user,token=token)
    source=detail['MediaSources'][0]['Id']
    endpoint='/GlideToolkit/Items/'+item['Id']+'/Rotation?mediaSourceId='+source
    capability=call(endpoint,token=token)
    original=(root/'GlideRotation.mp4').read_bytes()
    def angle():
        result=subprocess.run(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream_side_data=rotation','-of','json',str(root/'GlideRotation.mp4')],capture_output=True,text=True,check=True)
        return next((side['rotation'] for stream in json.loads(result.stdout).get('streams',[]) for side in stream.get('side_data_list',[]) if 'rotation' in side),0)
    original_angle=angle()
    original_mode=stat.S_IMODE((root/'GlideRotation.mp4').stat().st_mode)
    other=(root/'GlideAlternate.mp4').read_bytes()
    request={'requestId':str(uuid.uuid4()),'itemId':item['Id'],'mediaSourceId':source,'expectedVersion':capability['version'],'quarterTurns':1}
    accepted=call('/GlideToolkit/Jobs','POST',request,token,expected=(202,))
    done=wait(accepted,token)
    check(done['canRestore'],'rotation_completed_with_backup')
    rotated=(root/'GlideRotation.mp4').read_bytes()
    check(rotated!=original and len(rotated)==len(original),'actual_server_file_direction_changed')
    check((angle()-original_angle)%360==270,'ffprobe_confirms_clockwise_90_degrees_composed_with_existing_direction')
    check(stat.S_IMODE((root/'GlideRotation.mp4').stat().st_mode)==original_mode,'original_file_permissions_preserved')
    check((root/'GlideAlternate.mp4').read_bytes()==other,'unselected_media_file_untouched')
    again=call('/GlideToolkit/Jobs','POST',request,token,expected=(202,))
    check(again['jobId']==done['jobId'] and (root/'GlideRotation.mp4').read_bytes()==rotated,'repeated_post_is_idempotent_no_double_rotation')
    conflict=dict(request);conflict['quarterTurns']=2
    call('/GlideToolkit/Jobs','POST',conflict,token,expected=(409,));check(True,'same_request_id_with_changed_body_rejected')
    stale=dict(request);stale['requestId']=str(uuid.uuid4())
    call('/GlideToolkit/Jobs','POST',stale,token,expected=(409,));check(True,'changed_original_version_rejected')
    bad=dict(request);bad['requestId']=str(uuid.uuid4());bad['mediaSourceId']='wrong-version'
    call('/GlideToolkit/Jobs','POST',bad,token,expected=(409,422));check(True,'invalid_media_source_rejected')
    # A normal authenticated user must not gain file-write rights.
    users=call('/Users',token=token)
    guest=next((x for x in users if x['Name']=='glide-rotation-reader'),None)
    if guest is None:guest=call('/Users/New','POST',{'Name':'glide-rotation-reader'},token)
    reader=call('/Users/AuthenticateByName','POST',{'Username':'glide-rotation-reader','Pw':''})['AccessToken']
    check(not call('/GlideToolkit/Capabilities',token=reader)['available'],'ordinary_user_denied_by_default')
    call('/GlideToolkit/Jobs/'+done['jobId'],token=reader,expected=(403,));check(True,'unauthorized_user_cannot_query_write_job')
    plugin='/Plugins/9e405477-411c-4c2b-8541-c3b5925f7169/Configuration'
    configuration=call(plugin,token=token)
    authorized=dict(configuration);authorized['AllowedUserIds']=[guest['Id'].replace('-','')]
    try:
        call(plugin,'POST',authorized,token)
        check(call('/GlideToolkit/Capabilities',token=reader)['available'],'explicit_reader_authorization_accepts_compact_user_id')
    finally:call(plugin,'POST',configuration,token)
    verified=call('/GlideToolkit/Jobs/'+done['jobId']+'/Verify','POST',token=token)
    check(verified['state']=='completed' and (root/'GlideRotation.mp4').read_bytes()==rotated,'verify_endpoint_is_read_only')
    current=call(endpoint,token=token)
    restore={'requestId':str(uuid.uuid4()),'itemId':item['Id'],'mediaSourceId':source,'expectedVersion':current['version'],'quarterTurns':0,'restoreJobId':done['jobId']}
    restored=wait(call('/GlideToolkit/Jobs','POST',restore,token,expected=(202,)),token)
    check((root/'GlideRotation.mp4').read_bytes()==original,'restore_is_byte_identical_to_original')
    history=call('/GlideToolkit/Items/'+item['Id']+'/Jobs?mediaSourceId='+source,token=token)
    check(any(x['jobId']==done['jobId'] for x in history),'reconnecting_client_can_query_persisted_history')
    check(not any(key in json.dumps(history).lower() for key in ['authorization','password','/media/','.bak','.part']),'api_results_contain_no_paths_or_credentials')
    # The current file cannot be replaced while another accepted playback
    # session still uses it. Releasing that session allows the queued job.
    current=call(endpoint,token=token)
    call('/Sessions/Playing','POST',{'ItemId':item['Id'],'MediaSourceId':source,'CanSeek':True,'IsPaused':False,'PositionTicks':0,'PlayMethod':'DirectPlay'},token)
    waiting_request={'requestId':str(uuid.uuid4()),'itemId':item['Id'],'mediaSourceId':source,'expectedVersion':current['version'],'quarterTurns':1}
    waiting=call('/GlideToolkit/Jobs','POST',waiting_request,token,expected=(202,))
    try:
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            waiting=call('/GlideToolkit/Jobs/'+waiting['jobId'],token=token)
            if waiting['stage']=='waiting_playback':break
            time.sleep(.1)
        check(waiting['stage']=='waiting_playback' and (root/'GlideRotation.mp4').read_bytes()==original,'active_playback_prevents_original_replacement')
    finally:call('/Sessions/Playing/Stopped','POST',{'ItemId':item['Id'],'MediaSourceId':source,'PositionTicks':0},token)
    waiting=wait(waiting,token)
    current=call(endpoint,token=token)
    restore={'requestId':str(uuid.uuid4()),'itemId':item['Id'],'mediaSourceId':source,'expectedVersion':current['version'],'quarterTurns':0,'restoreJobId':waiting['jobId']}
    wait(call('/GlideToolkit/Jobs','POST',restore,token,expected=(202,)),token)
    check((root/'GlideRotation.mp4').read_bytes()==original,'waiting_job_completes_after_playback_stops_and_restores')
    report={'passed':True,'serverVersion':'12.2.0','checks':checks,'sourceSHA256':hashlib.sha256(original).hexdigest(),'rotatedSHA256':hashlib.sha256(rotated).hexdigest(),'timestamp':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())}
    output.write_text(json.dumps(report,indent=2)+'\n');print('Passed '+str(len(checks))+' official-server checks')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('command',choices=['bootstrap','verify'])
    parser.add_argument('--media',type=Path,default=Path('/tmp/GlideJellyfinQA/media'))
    parser.add_argument('--report',type=Path,default=Path('/tmp/GlideJellyfinTools/server-api-report.json'))
    args=parser.parse_args();bootstrap() if args.command=='bootstrap' else verify(args.media,args.report)
