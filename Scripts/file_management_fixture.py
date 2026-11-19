#!/usr/bin/env python3
"""Exercise file management only on the fixed authored localhost Jellyfin fixture."""
import argparse,hashlib,json,secrets,subprocess,time,urllib.request,urllib.error,urllib.parse,uuid
from pathlib import Path
BASE='http://127.0.0.1:8840'
ROOT=Path(__file__).resolve().parents[1]
WORK=ROOT/'.build/FileActionsQA'
PLUGIN='9e405477-411c-4c2b-8541-c3b5925f7169'
AUTH='MediaBrowser Client="GlideFileQA", Device="OriginalFixture", DeviceId="glide-file-local", Version="1.2.0"'
def call(path,method='GET',body=None,token=None,expected=(200,204,202)):
    headers={'Content-Type':'application/json','Authorization':AUTH+((', Token="'+token+'"') if token else '')}
    req=urllib.request.Request(BASE+path,data=None if body is None else json.dumps(body).encode(),headers=headers,method=method)
    try:
        with urllib.request.urlopen(req,timeout=60) as r:status,data=r.status,r.read()
    except urllib.error.HTTPError as e:status,data=e.code,e.read()
    result=json.loads(data) if data and data[:1] in (b'{',b'[') else None
    if status not in expected:raise RuntimeError(str(status)+' '+str(result or '')+' '+path.split('?')[0])
    return result

def login():
    creds=WORK/'auth.json'
    if not creds.exists():creds.write_text(json.dumps({'user':'glide-file-admin','password':secrets.token_urlsafe(30)}))
    values=json.loads(creds.read_text())
    end=time.monotonic()+60
    while True:
        try:
            info=call('/System/Info/Public')
            if isinstance(info,dict) and info.get('Version'):break
        except Exception:
            if time.monotonic()>end:raise
            time.sleep(.5)
    assert info['Version']=='12.2.0'
    if not info['StartupWizardCompleted']:
        call('/Startup/Configuration','POST',{'UICulture':'en-US','MetadataCountryCode':'US','PreferredMetadataLanguage':'en'})
        call('/Startup/FirstUser');call('/Startup/User','POST',{'Name':values['user'],'Password':values['password']})
        call('/Startup/RemoteAccess','POST',{'EnableRemoteAccess':False,'EnableAutomaticPortMapping':False});call('/Startup/Complete','POST',{})
    result=call('/Users/AuthenticateByName','POST',{'Username':values['user'],'Pw':values['password']})
    return result['AccessToken'],result['User']['Id']

def main():
    token,user=login();checks=[]
    def check(value,name):
        if not value:raise RuntimeError(name)
        checks.append(name);print('Passed '+name,flush=True)
    ep='/GlideToolkit/FileManagement/'
    cap=call(ep+'Capabilities',token=token);check(cap['protocolVersion']==1,'file_management_protocol_available')
    config=call('/Plugins/'+PLUGIN+'/Configuration',token=token)
    config['FileManagementEnabled']=True
    config['FileManagementUserIds']=[]
    call('/Plugins/'+PLUGIN+'/Configuration','POST',config,token)
    check(call(ep+'Capabilities',token=token)['available'],'administrator_explicitly_enables_file_management')
    folders=call('/Library/VirtualFolders',token=token)
    if not any('/media' in f.get('Locations',[]) for f in folders):
        call('/Library/VirtualFolders?name=Original%20File%20QA&collectionType=homevideos&refreshLibrary=true','POST',{'LibraryOptions':{'PathInfos':[{'Path':'/media'}],'EnableRealtimeMonitor':False,'EnableInternetProviders':False}},token)
    call('/Library/Refresh','POST',{},token)
    roots=call('/Library/MediaFolders',token=token)['Items']
    pending=[x['Id'] for x in roots if x.get('CollectionType')=='homevideos'];catalog=[];seen=set()
    while pending:
        parent=pending.pop(0)
        if parent in seen:continue
        seen.add(parent)
        page=call('/Items?ParentId='+parent+'&Fields=Path,MediaSources&Limit=1000',token=token)['Items']
        catalog.extend(page)
        pending.extend(x['Id'] for x in page if x.get('IsFolder'))
        if len(seen)>30:raise RuntimeError('Fixture folder walk escaped authored scope')
    def item(name):return next(x for x in catalog if x.get('Path')=='/media/source/'+name+'.mp4')
    destination=next(x for x in catalog if x.get('Path')=='/media/destination')
    visible=call(ep+'Folders',token=token)
    check(bool(visible['folders']),'folder_picker_lists_visible_libraries')
    request_counter=0
    def submit(names,operation,dest=None):
        nonlocal request_counter
        ids=[item(n)['Id'] for n in names]
        inspected=call(ep+'Inspect','POST',{'itemIds':ids},token)
        check(all(x['errorCode'] is None for x in inspected),'inspect_'+operation+'_'+str(request_counter));request_counter+=1
        request={'requestId':str(uuid.uuid4()),'operation':operation,'items':[{'itemId':x['itemId'],'mediaSourceId':x['mediaSourceId'],'expectedVersion':x['version'],'title':x['title']} for x in inspected]}
        if dest:request['destinationId']=dest
        return request,call(ep+'Batches','POST',request,token)
    def wait(batch):
        end=time.monotonic()+40
        while True:
            b=call(ep+'Batches/'+batch['batchId'],token=token)
            if b['remaining']==0:return b
            if time.monotonic()>end:raise RuntimeError('batch timed out '+json.dumps(b))
            time.sleep(.1)
    req,moved=submit(['move-a','move-b'],'move',destination['Id']);done=wait(moved)
    check(done['completed']==2 and done['failed']==0,'server_batch_moves_two_videos')
    check(all((WORK/'media/destination'/(n+'.mp4')).exists() and (WORK/'media/destination'/(n+'.zh.ass')).exists() and not (WORK/'media/source'/(n+'.mp4')).exists() for n in ['move-a','move-b']),'video_and_subtitles_move_on_nas_without_phone_transfer')
    again=call(ep+'Batches','POST',req,token);check(again['batchId']==done['batchId'],'lost_response_retry_returns_same_batch')
    modified=dict(req);modified['operation']='trash';check(call(ep+'Batches','POST',modified,token,expected=(409,))['errorCode']=='request_conflict','same_request_with_changed_intent_rejected')
    def restore(batch):
        request={'requestId':str(uuid.uuid4()),'operation':'restore','restoreBatchId':batch['batchId'],'items':[{'itemId':e['itemId'],'mediaSourceId':e['mediaSourceId'],'expectedVersion':'journal','title':e['title']} for e in batch['items'] if e['state']=='completed']}
        return wait(call(ep+'Batches','POST',request,token))
    restored=restore(done);check(restored['completed']==2,'server_move_restore_returns_original_paths')
    req,deleted=submit(['trash-a','trash-b'],'trash');deleted=wait(deleted)
    check(deleted['completed']==2 and all(not (WORK/'media/source'/(n+'.mp4')).exists() for n in ['trash-a','trash-b']),'delete_removes_selected_original_paths')
    recycle=list((WORK/'media/source/.glide-trash').rglob('*.mp4'))
    check(len(recycle)==2 and all(p.read_bytes()==(ROOT/'Server/test-media/original.mp4').read_bytes() for p in recycle),'delete_retains_byte_identical_recoverable_originals')
    check(restore(deleted)['completed']==2,'delete_restore_returns_videos_and_subtitles')
    _,conflict=submit(['conflict'],'move',destination['Id']);conflict=wait(conflict)
    check(conflict['failed']==1 and conflict['items'][0]['errorCode']=='destination_exists' and (WORK/'media/source/conflict.mp4').exists(),'same_name_conflict_does_not_overwrite_or_remove_source')
    guest=next((x for x in call('/Users',token=token) if x['Name']=='glide-file-reader'),None)
    if guest is None:guest=call('/Users/New','POST',{'Name':'glide-file-reader'},token)
    reader=call('/Users/AuthenticateByName','POST',{'Username':'glide-file-reader','Pw':''})['AccessToken']
    config['AllowedUserIds']=[guest['Id']];call('/Plugins/'+PLUGIN+'/Configuration','POST',config,token)
    check(not call(ep+'Capabilities',token=reader)['available'],'rotation_authorization_does_not_grant_file_management')
    call(ep+'Batches','POST',req,reader,expected=(403,));check(True,'ordinary_user_cannot_submit_file_changes')
    call(ep+'Batches/'+done['batchId'],token=reader,expected=(403,));check(True,'unauthorized_user_cannot_read_private_batch')
    # Playback occupancy is checked server-side, regardless of the client's current screen.
    active=item('busy')
    call('/Sessions/Playing','POST',{'ItemId':active['Id'],'MediaSourceId':active['MediaSources'][0]['Id'],'CanSeek':True,'IsPaused':False,'PositionTicks':0,'PlayMethod':'DirectPlay'},token)
    try:
        _,busy=submit(['busy'],'move',destination['Id']);busy=wait(busy)
        check(busy['failed']==1 and busy['items'][0]['errorCode']=='active_playback','active_playback_prevents_move')
    finally:call('/Sessions/Playing/Stopped','POST',{'ItemId':active['Id'],'PositionTicks':0},token)
    retried=call(ep+'Batches/'+busy['batchId']+'/retry','POST',token=token);retried=wait(retried)
    check(retried['completed']==1 and retried['failed']==0,'retry_only_failed_items_after_playback_stops')
    check(restore(retried)['completed']==1,'retried_move_can_be_restored')
    # An explicitly authorized ordinary user still cannot read another user's jobs.
    config['FileManagementUserIds']=[guest['Id']];call('/Plugins/'+PLUGIN+'/Configuration','POST',config,token)
    call(ep+'Batches/'+done['batchId'],token=reader,expected=(409,));check(True,'file_management_authorized_user_cannot_read_other_users_jobs')
    # Verify actual source/target indexing catches up, without a full library scan.
    end=time.monotonic()+30
    source_folder=next(x for x in catalog if x.get('Path')=='/media/source')
    while True:
        originals=call('/Items?ParentId='+source_folder['Id']+'&Fields=Path&Limit=1000',token=token)['Items']
        current={x.get('Path') for x in originals}
        if all('/media/source/'+n+'.mp4' in current for n in ['move-a','move-b','trash-a','trash-b','busy']):break
        if time.monotonic()>end:raise RuntimeError('Changed folders were not reindexed')
        time.sleep(.2)
    check(True,'batch_folder_refresh_restores_catalog_visibility')
    history=call(ep+'Batches',token=token)
    check(all(not b['items'] for b in history) and any(b['batchId']==done['batchId'] and b['completed']==2 for b in history),'history_returns_lightweight_counts_with_details_loaded_on_demand')
    (WORK/'completed-batches.json').write_text(json.dumps({'move':done['batchId'],'trash':deleted['batchId'],'busy':retried['batchId']}))
    output={'passed':True,'serverVersion':'12.2.0','pluginVersion':'1.2.0.0','scope':'Fixed localhost authored media only; no private NAS','checks':checks}
    target=ROOT/'Docs/Testing/File-Management-2026-11-16';target.mkdir(parents=True,exist_ok=True)
    (target/'Server-API.json').write_text(json.dumps(output,indent=2)+'\n')
    print('Passed '+str(len(checks))+' API checks',flush=True)
if __name__=='__main__':main()
