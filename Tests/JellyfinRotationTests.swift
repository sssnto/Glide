import Foundation
import Testing
@testable import GlideCore

struct JellyfinRotationTests {
    private let server=MediaServer(name:"QA",kind:.jellyfin,address:URL(string:"https://example.test/jellyfin")!,username:"qa")
    @Test func onlyOnlineJellyfinCurrentVersionCanUseServerRotation() {
        let video=Video(id:"a",title:"a",subtitle:"",sourceID:server.id,remoteID:"item")
        let stream=URL(string:"https://example.test/stream")!
        #expect(JellyfinRotationTarget(video:video,server:server,resourceURL:stream,mediaSourceID:"v2")?.mediaSourceID=="v2")
        #expect(JellyfinRotationTarget(video:video,server:server,resourceURL:stream,mediaSourceID:nil)==nil)
        #expect(JellyfinRotationTarget(video:video,server:server,resourceURL:URL(fileURLWithPath:"/offline.mp4"),mediaSourceID:"v2")==nil)
        var offline=video;offline.offlineOnly=true
        #expect(JellyfinRotationTarget(video:offline,server:server,resourceURL:stream,mediaSourceID:"v2")==nil)
        var emby=server;emby.kind = .emby
        #expect(JellyfinRotationTarget(video:video,server:emby,resourceURL:stream,mediaSourceID:"v2")==nil)
    }
    @Test func durableRequestsContainIdsAndNoFilePathsOrCredentials() throws {
        let request=JellyfinRotationRequest(requestId:UUID(),itemId:"item",mediaSourceId:"version2",expectedVersion:"fingerprint",quarterTurns:1)
        let pending=JellyfinRotationPending(sourceID:server.id,videoID:"video",request:request)
        let encoded=try JSONEncoder().encode(pending)
        let string=String(decoding:encoded,as:UTF8.self)
        for secret in ["https:","Authorization","password","username","filePath","/Volumes"] { #expect(!string.contains(secret)) }
        #expect(try JSONDecoder().decode(JellyfinRotationPending.self,from:encoded)==pending)
        let target=JellyfinRotationTarget(video:Video(id:"video",title:"",subtitle:"",sourceID:server.id,remoteID:"item"),server:server,resourceURL:server.address,mediaSourceID:"version2")!
        #expect(pending.matches(target))
        var changed=request;changed = .init(requestId:request.requestId,itemId:"item",mediaSourceId:"other",expectedVersion:"fingerprint",quarterTurns:1)
        #expect(!JellyfinRotationPending(sourceID:server.id,videoID:"video",request:changed).matches(target))
    }
    @Test func jobStatesKeepAmbiguousResultsFromBeingSuccessful() throws {
        func job(_ state:String)->JellyfinRotationJob { .init(jobId:UUID(),requestId:UUID(),itemId:"i",mediaSourceId:"s",state:state,stage:state,progress:0,errorCode:nil,canRestore:false,refreshPending:false,updatedAt:"2026-11-10T00:00:00Z") }
        for state in ["queued","running","committing"] { #expect(job(state).isActive);#expect(!job(state).completed) }
        #expect(job("completed").completed)
        for state in ["needs_verification","failed","unknown"] { #expect(!job(state).completed) }
        #expect(try JSONDecoder().decode(JellyfinRotationJob.self,from:JSONEncoder().encode(job("committing"))).isActive)
    }
    @Test func unsafePluginRevisionCannotSaveMedia() {
        func capability(_ version:String)->JellyfinRotationCapability { .init(protocolVersion:1,pluginVersion:version,available:true,reason:nil) }
        #expect(!capability("1.0.0").supportsSafePublication)
        #expect(!capability("invalid").supportsSafePublication)
        for version in ["1.0.1","1.0.2"] { #expect(!capability(version).supportsSafePublication) }
        for version in ["1.0.3","1.1.0","2.0.0"] { #expect(capability(version).supportsSafePublication) }
    }
    @Test func publicationModeIsOptionalAndDecodesNewServerResponse() throws {
        let payload=Data(#"{"jobId":"11111111-2222-4333-8444-555555555555","requestId":"66666666-7777-4888-8999-aaaaaaaaaaaa","itemId":"i","mediaSourceId":"s","state":"completed","stage":"completed","progress":100,"canRestore":true,"refreshPending":false,"updatedAt":"2026-11-10T00:00:00Z","publicationMode":"SameDirectoryRename"}"#.utf8)
        let job=try JSONDecoder().decode(JellyfinRotationJob.self,from:payload)
        #expect(job.publicationMode=="SameDirectoryRename")
        #expect(job.completed && job.canRestore)
        var older=try JSONSerialization.jsonObject(with:payload) as! [String:Any]
        older.removeValue(forKey:"publicationMode")
        #expect(try JSONDecoder().decode(JellyfinRotationJob.self,from:JSONSerialization.data(withJSONObject:older)).publicationMode==nil)
    }
}
