#if DEBUG
import SwiftUI
import AVFoundation
import ImageIO

/// Read-only incident investigation. Credentials and supplied file paths remain
/// inside the device; never submit rotation, restore, refresh or delete requests.
struct JellyfinRotationRecoveryProbe:View {
    let library:LibraryStore
    @State private var stage="读取服务器旋转与播放状态"
    @State private var report:[String:Any]=[:]
    private var batch:Bool { ProcessInfo.processInfo.arguments.contains("--glide-nas-batch-rotation-acceptance") || ProcessInfo.processInfo.arguments.contains("--glide-nas-batch-readonly") }
    private var acceptance:Bool { ProcessInfo.processInfo.arguments.contains("--glide-nas-rotation-acceptance") }
    var body:some View {
        VStack(spacing:16) {
            Text(batch ? "NAS 批量旋转验收" : acceptance ? "NAS 原创短片验收" : "旋转恢复诊断").font(.headline)
            Text(stage).font(.caption).accessibilityIdentifier("rotation.recovery.status")
            Text(batch ? "仅处理逐字节核对的原创副本，完成后原样还原。" : acceptance ? "仅处理新建原创测试短片，保留原有视频和备份。" : "仅核对任务与文件读取，不修改视频或备份。").font(.footnote).foregroundStyle(.secondary)
            if batch, report["requiresFixtureCopies"] as? Bool == true {
                Button("重新验证") { Task { await runBatch() } }
            }
        }.padding().task {
            if batch { await runBatch() }
            else if acceptance {
                await NASRotationAcceptance.run(library:library) { value in
                    report=value;stage=value["stage"] as? String ?? "NAS 验收";save()
                }
            } else { await run() }
        }.onAppear { UIApplication.shared.isIdleTimerDisabled=true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled=false }
    }
    @MainActor private func runBatch() async {
        await NASBatchRotationAcceptance.run(library:library) { value in
            report=value;stage=value["stage"] as? String ?? "NAS 批量验收";save()
        }
    }
    @MainActor private func save() {
        report["stage"]=stage;report["time"]=ISO8601DateFormatter().string(from:Date());report["version"]=PlaybackPreferences.appVersion
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:root.appendingPathComponent(batch ? "JellyfinNASBatchRotationQA.json" : acceptance ? "JellyfinNASRotationQA.json" : "JellyfinRotationRecoveryQA.json"),options:.atomic) }
    }
    @MainActor private func call(_ server:MediaServer,_ path:String,query:[String:String]=[:],body:[String:Any]?=nil) async throws -> (Int,Any) {
        guard let token=Credentials.read(server.id) else { throw JellyfinRotationFailure.code("permission_denied") }
        var request=URLRequest(url:ServerURL.endpoint(server.address,path,query:query))
        request.setValue(MediaClient.shared.authorization(token,server:server),forHTTPHeaderField:"Authorization")
        if let body { request.httpMethod="POST";request.httpBody=try JSONSerialization.data(withJSONObject:body);request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let (data,response)=try await MediaClient.shared.session.data(for:request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0,(try? JSONSerialization.jsonObject(with:data)) ?? [:])
    }
    private func technical(_ source:[String:Any])->[String:Any] {
        let keys=["Id","Protocol","Container","Size","SupportsDirectPlay","SupportsDirectStream","SupportsTranscoding"]
        var safe=source.filter { keys.contains($0.key) }
        safe["streams"]=(source["MediaStreams"] as? [[String:Any]] ?? []).map { stream in
            stream.filter { ["Index","Type","Codec","Width","Height","BitDepth","Profile","Level","Rotation","VideoRangeType"].contains($0.key) }
        }
        return safe
    }
    private func safeJob(_ value:Any)->Any {
        let keys=["jobId","requestId","itemId","mediaSourceId","state","stage","progress","errorCode","canRestore","refreshPending","updatedAt","publicationMode","failureCode"]
        if let jobs=value as? [[String:Any]] { return jobs.map { $0.filter { keys.contains($0.key) } } }
        return (value as? [String:Any] ?? [:]).filter { keys.contains($0.key) }
    }
    @MainActor private func inspectFile(_ server:MediaServer,itemID:String) async throws -> [String:Any] {
        guard let token=Credentials.read(server.id) else { return [:] }
        var request=URLRequest(url:ServerURL.endpoint(server.address,"Items/\(itemID)/File"))
        request.setValue(MediaClient.shared.authorization(token,server:server),forHTTPHeaderField:"Authorization")
        request.setValue("bytes=0-4095",forHTTPHeaderField:"Range")
        let (bytes,response)=try await MediaClient.shared.session.bytes(for:request)
        defer { bytes.task.cancel() }
        let http=response as? HTTPURLResponse
        var prefix=Data()
        if [200,206].contains(http?.statusCode ?? 0) {
            for try await byte in bytes { prefix.append(byte);if prefix.count>=4096 { break } }
        }
        return ["status":http?.statusCode ?? 0,"prefixBytes":prefix.count,"container":MediaContainer.identify(prefix).rawValue,
                "declaredLength":http?.expectedContentLength ?? -1]
    }
    @MainActor private func run() async {
        do {
            guard let requested=UserDefaults.standard.string(forKey:"glideRotationRecoveryFile"),!requested.isEmpty else { throw MediaError.message("缺少核对文件") }
            let normalized=requested.precomposedStringWithCanonicalMapping
            let name=URL(fileURLWithPath:requested).deletingPathExtension().lastPathComponent
            let servers=library.servers.filter { $0.kind == .jellyfin }
            report["sourceCount"]=servers.count;save()
            let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            let journal=RecoverableStore<JellyfinRotationJournal.State>(file:root.appendingPathComponent("JellyfinRotation/pending-v1.json"))
            let pending=(try? journal.load()?.value.pending) ?? []
            for server in servers {
                let (infoStatus,infoValue)=try await call(server,"System/Info/Public")
                report["systemInfoStatus"]=infoStatus;report["serverVersion"]=(infoValue as? [String:Any])?["Version"]
                let (capStatus,capValue)=try await call(server,"GlideToolkit/Capabilities")
                report["capabilityStatus"]=capStatus
                if let cap=capValue as? [String:Any] { report["capability"]=cap.filter { ["protocolVersion","pluginVersion","available","reason"].contains($0.key) } }
                var known=Set(pending.filter { $0.sourceID==server.id }.compactMap(\.jobID))
                if let value=UserDefaults.standard.string(forKey:"glideRotationRecoveryJob"),let id=UUID(uuidString:value) { known.insert(id) }
                var knownJobs:[[String:Any]]=[]
                for id in known {
                    let (status,value)=try await call(server,"GlideToolkit/Jobs/\(id.uuidString)")
                    knownJobs.append(["jobID":id.uuidString,"status":status,"result":safeJob(value)])
                }
                report["knownJobs"]=knownJobs
                save()
                let search=name.components(separatedBy:"-").first ?? name
                let (status,value)=try await call(server,"Items",query:["UserId":server.userID ?? "","Recursive":"true","SearchTerm":search,"Fields":"MediaSources,Path","Limit":"100"])
                let items=(value as? [String:Any])?["Items"] as? [[String:Any]] ?? []
                report["searchStatus"]=status;report["searchCount"]=items.count;save()
                for item in items {
                    let sources=item["MediaSources"] as? [[String:Any]] ?? []
                    let paths=[item["Path"] as? String]+sources.map { $0["Path"] as? String }
                    guard paths.compactMap({$0?.precomposedStringWithCanonicalMapping}).contains(normalized),let itemID=item["Id"] as? String else { continue }
                    report["matchedExactFile"]=true;report["itemID"]=itemID
                    let (detailStatus,detailValue)=try await call(server,"Items/\(itemID)",query:["UserId":server.userID ?? ""])
                    let detail=detailValue as? [String:Any] ?? [:]
                    let currentSources=detail["MediaSources"] as? [[String:Any]] ?? []
                    report["detailStatus"]=detailStatus;report["sources"]=currentSources.map(technical);save()
                    let relevant=pending.filter { $0.sourceID==server.id && $0.request.itemId.lowercased()==itemID.lowercased() }
                    report["pendingRequests"]=relevant.map { ["requestID":$0.request.requestId.uuidString,"jobID":$0.jobID?.uuidString ?? "","mediaSourceID":$0.request.mediaSourceId] }
                    var ids=Set(currentSources.compactMap { $0["Id"] as? String });ids.insert(itemID)
                    relevant.forEach { ids.insert($0.request.mediaSourceId) }
                    var jobReads:[[String:Any]]=[]
                    for id in ids {
                        let (jobStatus,jobs)=try await call(server,"GlideToolkit/Items/\(itemID)/Jobs",query:["mediaSourceId":id])
                        jobReads.append(["mediaSourceID":id,"status":jobStatus,"result":safeJob(jobs)])
                    }
                    report["jobReads"]=jobReads;save()
                    report["fileRead"]=try await inspectFile(server,itemID:itemID);save()
                    var body=MediaServerAPI.playbackBody(kind:.jellyfin,userID:server.userID ?? "",quality:.original,directVideoCodecs:"h264,hevc")
                    body["EnableTranscoding"]=false
                    let (playStatus,playValue)=try await call(server,"Items/\(itemID)/PlaybackInfo",body:body)
                    let play=playValue as? [String:Any] ?? [:]
                    report["playbackInfoStatus"]=playStatus;report["playbackErrorCode"]=play["ErrorCode"]
                    report["playbackSources"]=(play["MediaSources"] as? [[String:Any]] ?? []).map(technical)
                    stage="只读核对完成";save();return
                }
            }
            stage="未找到路径完全匹配的媒体";save()
        } catch {
            report["errorDomain"]=(error as NSError).domain;report["errorCode"]=(error as NSError).code
            stage="诊断未完成";save()
        }
    }
}

/// Explicit DEBUG-only device acceptance. The only writable video is a newly
/// uploaded UUID-named copy of the bundled authored short. No private media path
/// is accepted as a rotation target; credentials stay in the saved app sources.
@MainActor private final class NASRotationAcceptance {
    private var report:[String:Any]=["passed":false,"checks":[]]
    private var checks:[String]=[]
    private let publish:([String:Any])->Void
    private init(publish:@escaping ([String:Any])->Void) { self.publish=publish }
    static func run(library:LibraryStore,publish:@escaping ([String:Any])->Void) async {
        let value=NASRotationAcceptance(publish:publish)
        do { try await value.execute(library) }
        catch {
            value.report["stage"]="NAS 验收未通过"
            value.report["errorDomain"]=(error as NSError).domain
            value.report["errorCode"]=(error as NSError).code
            if case let JellyfinRotationFailure.code(code)=error { value.report["failureCode"]=code }
            value.publish(value.report)
        }
    }
    private func stage(_ text:String) { report["stage"]=text;publish(report) }
    private func check(_ condition:Bool,_ name:String) throws {
        guard condition else { throw JellyfinRotationFailure.code(name) }
        checks.append(name);report["checks"]=checks;publish(report)
    }
    private func json(_ server:MediaServer,_ path:String,query:[String:String]=[:],body:[String:Any]?=nil) async throws -> [String:Any] {
        guard let token=Credentials.read(server.id) else { throw JellyfinRotationFailure.code("permission_denied") }
        let payload=try body.map { try JSONSerialization.data(withJSONObject:$0) }
        let data=try await MediaClient.shared.request(ServerURL.endpoint(server.address,path,query:query),method:body == nil ? "GET" : "POST",
            headers:["Authorization":MediaClient.shared.authorization(token,server:server),"Content-Type":"application/json"],
            body:payload)
        return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
    }
    private func fetch(_ url:URL,authorization:String,maximum:Int) async throws -> (Data,HTTPURLResponse) {
        var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData);request.setValue(authorization,forHTTPHeaderField:"Authorization")
        request.setValue("no-cache",forHTTPHeaderField:"Cache-Control")
        let (bytes,response)=try await MediaClient.shared.session.bytes(for:request)
        defer { bytes.task.cancel() }
        guard let http=response as? HTTPURLResponse,http.statusCode==200,response.expectedContentLength<=Int64(maximum) else { throw JellyfinRotationFailure.code("authored_read_failed") }
        var data=Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count<maximum else { throw JellyfinRotationFailure.code("authored_size_changed") }
            data.append(byte)
        }
        return (data,http)
    }
    private func wait(_ initial:JellyfinRotationJob,client:JellyfinRotationClient) async throws -> JellyfinRotationJob {
        var job=initial
        let limit=Date().addingTimeInterval(120)
        while job.isActive {
            report["jobState"]=job.state;report["jobStage"]=job.stage;report["jobProgress"]=job.progress;publish(report)
            guard Date()<limit else { throw JellyfinRotationFailure.code("authored_job_timeout") }
            try await Task.sleep(for:.milliseconds(500));job=try await client.job(job.jobId)
        }
        report["jobState"]=job.state;report["jobStage"]=job.stage;report["jobError"]=job.errorCode ?? "";report["publicationMode"]=job.publicationMode ?? "";report["serverFailureCode"]=job.failureCode ?? "";publish(report)
        guard job.completed else { throw JellyfinRotationFailure.code(job.errorCode ?? "authored_job_failed") }
        return job
    }
    private func execute(_ library:LibraryStore) async throws {
        let defaults=UserDefaults.standard
        guard let known=defaults.string(forKey:"glideRotationRecoveryJob"),UUID(uuidString:known) != nil,
              let address=defaults.string(forKey:"glideNASRotationWebDAVDirectory"),let davRoot=try? ServerURL.parse(address),
              let mediaRoot=defaults.string(forKey:"glideNASRotationLibraryDirectory"),mediaRoot.hasPrefix("/"),
              let local=Bundle.main.url(forResource:"demo0",withExtension:"mp4") else { throw JellyfinRotationFailure.code("acceptance_arguments_missing") }
        stage("确认服务器身份与已保存连接")
        var matched:MediaServer?
        var knownItemID:String?
        for server in library.servers where server.kind == .jellyfin {
            if let job=try? await json(server,"GlideToolkit/Jobs/"+known),job["jobId"] as? String != nil { matched=server;knownItemID=job["itemId"] as? String;break }
        }
        guard let server=matched else { throw JellyfinRotationFailure.code("saved_jellyfin_not_found") }
        let cap=try await json(server,"GlideToolkit/Capabilities")
        report["pluginVersion"]=cap["pluginVersion"];report["protocolVersion"]=cap["protocolVersion"]
        try check(cap["pluginVersion"] as? String == "1.0.3" && cap["available"] as? Bool == true,"updated_plugin_available")
        guard let token=Credentials.read(server.id) else { throw JellyfinRotationFailure.code("permission_denied") }
        let authored=try Data(contentsOf:local),digest=try RemoteVideoRotation.digest(local)
        report["authoredBytes"]=authored.count
        let existing=ProcessInfo.processInfo.arguments.contains("--glide-nas-rotation-existing")
        var path=""
        if existing {
            report["authoredFromManualCopy"]=true
        } else {
        var folderRequest=URLRequest(url:ServerURL.endpoint(server.address,"Library/VirtualFolders"))
        folderRequest.setValue(MediaClient.shared.authorization(token,server:server),forHTTPHeaderField:"Authorization")
        let (foldersData,foldersResponse)=try await MediaClient.shared.session.data(for:folderRequest)
        report["libraryRootsHTTPStatus"]=(foldersResponse as? HTTPURLResponse)?.statusCode ?? 0
        let folders=(try? JSONSerialization.jsonObject(with:foldersData)) as? [[String:Any]] ?? []
        let roots=folders.flatMap { $0["Locations"] as? [String] ?? [] }
        var provenParents=Set<String>()
        if let id=knownItemID,let detail=try? await json(server,"Items/"+id,query:["UserId":server.userID ?? ""]) {
            let paths=[detail["Path"] as? String]+(detail["MediaSources"] as? [[String:Any]] ?? []).map { $0["Path"] as? String }
            provenParents=Set(paths.compactMap { $0.map { URL(fileURLWithPath:$0).deletingLastPathComponent().standardized.path } })
        }
        var candidates:[(URL,String)]=[(davRoot,mediaRoot)]
        if let address=defaults.string(forKey:"glideNASRotationFallbackDAVDirectory"),let alternate=try? ServerURL.parse(address),
           let root=defaults.string(forKey:"glideNASRotationFallbackLibraryDirectory"),root.hasPrefix("/") { candidates.append((alternate,root)) }
        var choices:[(MediaServer,URL,String)]=[]
        report["directoryCandidates"]=candidates.map { url,path -> [String:Any] in
            let visible=provenParents.contains(URL(fileURLWithPath:path).standardized.path) || roots.contains { root in
                let base=URL(fileURLWithPath:root).standardized.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
                let child=URL(fileURLWithPath:path).standardized.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
                return child==base || child.hasPrefix(base+"/")
            }
            let matches=library.servers.filter { $0.kind == .webDAV && ServerURL.sameOrigin($0.address,url) && DirectoryScope.contains(root:$0.address,child:url) && Credentials.read($0.id) != nil }
            if visible,let match=matches.sorted(by:{$0.address.path.count>$1.address.path.count}).first { choices.append((match,url,path)) }
            return ["inJellyfinLibrary":visible,"matchingSavedDAVSources":matches.count]
        }
        publish(report)
        guard let (dav,selectedDAVRoot,selectedMediaRoot)=choices.first else { throw JellyfinRotationFailure.code("shared_directory_mapping_unavailable") }
        let fileName="GlideRotationQA"+UUID().uuidString.replacingOccurrences(of:"-",with:"")+".mp4"
        let file=selectedDAVRoot.appendingPathComponent(fileName)
        path=URL(fileURLWithPath:selectedMediaRoot,isDirectory:true).appendingPathComponent(fileName).path
        stage("上传一次性原创测试短片")
        var upload=URLRequest(url:file);upload.httpMethod="PUT";upload.httpBody=authored
        upload.setValue(MediaClient.shared.basic(server:dav),forHTTPHeaderField:"Authorization")
        upload.setValue("*",forHTTPHeaderField:"If-None-Match");upload.setValue("video/mp4",forHTTPHeaderField:"Content-Type")
        let (_,response)=try await MediaClient.shared.session.data(for:upload)
        try check([201,204].contains((response as? HTTPURLResponse)?.statusCode ?? 0),"authored_fixture_uploaded")
        // The exact newly created path only; no broad library/metadata refresh.
        _=try await json(server,"Library/Media/Updated",body:["Updates":[["Path":path,"UpdateType":"Created"]]])
        }
        stage("等待 Jellyfin 索引原创短片")
        var item:[String:Any]?
        var attempts=0
        let deadline=Date().addingTimeInterval(120)
        while Date()<deadline,item == nil {
            let result=try await json(server,"Items",query:["UserId":server.userID ?? "","Recursive":"true","SearchTerm":"GlideRotationQA","Fields":"MediaSources,Path","Limit":"100"])
            attempts+=1;report["indexQueries"]=attempts;report["indexCandidates"]=(result["Items"] as? [[String:Any]] ?? []).count;publish(report)
            item=(result["Items"] as? [[String:Any]] ?? []).first { value in
                let paths=[value["Path"] as? String]+(value["MediaSources"] as? [[String:Any]] ?? []).map { $0["Path"] as? String }
                if existing {
                    if let found=paths.compactMap({$0}).first(where:{ candidate in
                        let url=URL(fileURLWithPath:candidate)
                        let name=url.deletingPathExtension().lastPathComponent
                        let suffix=String(name.dropFirst("GlideRotationQA".count))
                        return url.deletingLastPathComponent().standardized.path == URL(fileURLWithPath:mediaRoot).standardized.path
                            && url.pathExtension.lowercased()=="mp4" && name.hasPrefix("GlideRotationQA") && suffix.count==32
                            && suffix.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
                    }) { path=found;return true }
                    return false
                }
                return paths.compactMap({$0?.precomposedStringWithCanonicalMapping}).contains(path.precomposedStringWithCanonicalMapping)
            }
            if item == nil { try await Task.sleep(for:.seconds(2)) }
        }
        guard let item,let id=item["Id"] as? String else { throw JellyfinRotationFailure.code("authored_index_timeout") }
        report["authoredItemID"]=id
        let detail=try await json(server,"Items/"+id,query:["UserId":server.userID ?? ""])
        guard let source=(detail["MediaSources"] as? [[String:Any]])?.first(where:{$0["Path"] as? String == path}),let sourceID=source["Id"] as? String,
              Credentials.read(server.id) != nil else { throw JellyfinRotationFailure.code("authored_source_mismatch") }
        let authorization=MediaClient.shared.authorization(token,server:server),download=ServerURL.endpoint(server.address,"Items/\(id)/File")
        let (initialBytes,_)=try await fetch(download,authorization:authorization,maximum:authored.count+1)
        try check(initialBytes==authored,"jellyfin_points_to_exact_authored_bytes")
        let video=Video(id:"nas-rotation-"+id,title:"原创 NAS 旋转测试",subtitle:"",sourceID:server.id,remoteID:id)
        guard let target=JellyfinRotationTarget(video:video,server:server,resourceURL:download,mediaSourceID:sourceID) else { throw JellyfinRotationFailure.code("authored_target_invalid") }
        let client=JellyfinRotationClient(target:target),current=try await client.capability()
        guard let version=current.version else { throw JellyfinRotationFailure.code("authored_version_missing") }
        stage("由 Jellyfin 插件备份并旋转短片")
        let command=JellyfinRotationRequest(requestId:UUID(),itemId:id,mediaSourceId:sourceID,expectedVersion:version,quarterTurns:1)
        let done:JellyfinRotationJob
        do { done=try await wait(client.submit(command),client:client) }
        catch {
            if let (unchanged,_)=try? await fetch(download,authorization:authorization,maximum:authored.count+1) { report["authoredUnchangedAfterRefusal"]=unchanged==authored;publish(report) }
            throw error
        }
        report["authoredRotationJobID"]=done.jobId.uuidString
        try check(done.canRestore,"server_rotation_completed_with_backup")
        let (rotated,_)=try await fetch(download,authorization:authorization,maximum:authored.count+1)
        let workspace=FileManager.default.temporaryDirectory.appendingPathComponent("GlideNASRotation-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:workspace) }
        let rotatedFile=workspace.appendingPathComponent("rotated.mp4");try rotated.write(to:rotatedFile)
        let patch=try VideoFileRotation.inspect(local,turn:.clockwise),savedPatch=try VideoFileRotation.inspect(rotatedFile,turn:.original)
        try check(rotated.count==authored.count && savedPatch.original==patch.replacement,"saved_matrix_is_clockwise_90")
        try check(try RemoteVideoRotation.digest(rotatedFile,excluding:patch.matrixOffset..<patch.matrixOffset+36)==RemoteVideoRotation.digest(local,excluding:patch.matrixOffset..<patch.matrixOffset+36),"all_other_bytes_preserved")
        let asset=AVURLAsset(url:rotatedFile)
        try check(try await asset.load(.isPlayable),"rotated_asset_playable")
        let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true
        let frame=try await generator.image(at:CMTime(seconds:0.5,preferredTimescale:600)).image
        let originalAsset=AVURLAsset(url:local)
        let originalGenerator=AVAssetImageGenerator(asset:originalAsset);originalGenerator.appliesPreferredTrackTransform=true
        let originalFrame=try await originalGenerator.image(at:CMTime(seconds:0.5,preferredTimescale:600)).image
        try check(frame.width==originalFrame.height && frame.height==originalFrame.width,"native_decoded_frame_rotated_90")
        let again=try await client.submit(command)
        try check(again.jobId==done.jobId,"same_request_is_idempotent_on_real_nas")
        stage("由 Jellyfin 插件原样还原短片")
        let currentVersion=try await client.capability()
        guard let version=currentVersion.version else { throw JellyfinRotationFailure.code("authored_version_missing") }
        let restored=try await wait(client.submit(.init(requestId:UUID(),itemId:id,mediaSourceId:sourceID,expectedVersion:version,quarterTurns:0,restoreJobId:done.jobId)),client:client)
        report["authoredRestoreJobID"]=restored.jobId.uuidString
        let (final,_)=try await fetch(download,authorization:authorization,maximum:authored.count+1)
        try check(restored.completed && final==authored,"restored_file_byte_identical")
        // Keep this one authored clip and server backups for inspection. Never
        // infer ownership of any preexisting media or historical backup.
        report["authoredFixtureRetained"]=true;report["serverBackupsRetained"]=true
        report["originalSHA256"]=digest;report["rotatedSHA256"]=try RemoteVideoRotation.digest(rotatedFile)
        report["passed"]=true;stage("NAS 旋转保存与原样还原验证通过")
    }
}

/// Actual NAS acceptance, DEBUG only. Its write set is limited to two authored
/// MP4s whose every byte outside the display matrix matches the bundled sample.
/// A durable receipt precedes every POST; relaunch resumes rather than rotating twice.
@MainActor private final class NASBatchRotationAcceptance {
    private static var running=false
    private struct Clip:Codable {
        let id:String
        let sourceID:String
        let title:String
        let bytes:Data
        var restore:JellyfinRotationRequest?
    }
    private struct State:Codable {
        let serverID:UUID
        let userID:String?
        let requestID:UUID
        var clips:[Clip]
        var batchID:UUID?
        var pauseChecked=false
        var passed=false
    }
    private var value:[String:Any]=["passed":false,"checks":[]]
    private var checks:[String]=[]
    private let publish:([String:Any])->Void
    private var journal:RecoverableStore<State> {
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        return RecoverableStore(file:root.appendingPathComponent("JellyfinRotation/NASBatchAcceptance-v1.json"))
    }
    private init(_ publish:@escaping ([String:Any])->Void) { self.publish=publish }
    static func run(library:LibraryStore,publish:@escaping ([String:Any])->Void) async {
        guard !running else { return };running=true;defer { running=false }
        let probe=NASBatchRotationAcceptance(publish)
        do {
            if ProcessInfo.processInfo.arguments.contains("--glide-nas-batch-readonly") { try await probe.inventory(library) }
            else { try await probe.execute(library) }
        }
        catch {
            probe.value["errorDomain"]=(error as NSError).domain;probe.value["errorCode"]=(error as NSError).code
            if case JellyfinRotationFailure.code(let code)=error { probe.value["failureCode"]=code }
            probe.stage("批量验收未完成；未确认任务请勿重复提交")
        }
    }
    private func stage(_ text:String) { value["stage"]=text;publish(value) }
    private func check(_ result:Bool,_ name:String) throws {
        guard result else { throw JellyfinRotationFailure.code(name) }
        checks.append(name);value["checks"]=checks;publish(value)
    }
    private func json(_ server:MediaServer,_ path:String,query:[String:String]=[:],body:[String:Any]?=nil) async throws -> [String:Any] {
        guard let token=Credentials.read(server.id) else { throw JellyfinRotationFailure.code("permission_denied") }
        let payload=try body.map { try JSONSerialization.data(withJSONObject:$0) }
        let bytes=try await MediaClient.shared.request(ServerURL.endpoint(server.address,path,query:query),method:body == nil ? "GET":"POST",headers:["Authorization":MediaClient.shared.authorization(token,server:server),"Content-Type":"application/json"],body:payload)
        return (try JSONSerialization.jsonObject(with:bytes)) as? [String:Any] ?? [:]
    }
    private func fetch(_ server:MediaServer,_ path:String,query:[String:String]=[:],maximum:Int) async throws -> Data {
        guard let token=Credentials.read(server.id) else { throw JellyfinRotationFailure.code("permission_denied") }
        var request=URLRequest(url:ServerURL.endpoint(server.address,path,query:query),cachePolicy:.reloadIgnoringLocalCacheData)
        request.setValue(MediaClient.shared.authorization(token,server:server),forHTTPHeaderField:"Authorization")
        let (stream,response)=try await MediaClient.shared.session.bytes(for:request);defer { stream.task.cancel() }
        guard (response as? HTTPURLResponse)?.statusCode==200,response.expectedContentLength<=maximum else { throw JellyfinRotationFailure.code("authored_read_failed") }
        var bytes=Data()
        for try await byte in stream {
            try Task.checkCancellation();guard bytes.count<maximum else { throw JellyfinRotationFailure.code("authored_size_changed") };bytes.append(byte)
        }
        return bytes
    }
    private func ownedName(_ path:String)->Bool {
        let url=URL(fileURLWithPath:path),stem=url.deletingPathExtension().lastPathComponent,prefix="GlideRotationQA"
        guard url.pathExtension.lowercased()=="mp4",stem.hasPrefix(prefix) else { return false }
        let suffix=stem.dropFirst(prefix.count)
        return suffix.count==32 && suffix.allSatisfy(\.isHexDigit)
    }
    private func samePayload(_ bytes:Data,_ original:Data,offset:Int)->Bool {
        bytes.count==original.count && bytes.prefix(offset)==original.prefix(offset) && bytes.dropFirst(offset+36)==original.dropFirst(offset+36)
    }
    private func imageSize(_ bytes:Data) throws -> CGSize {
        guard let source=CGImageSourceCreateWithData(bytes as CFData,nil),let info=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=info[kCGImagePropertyPixelWidth] as? NSNumber,let height=info[kCGImagePropertyPixelHeight] as? NSNumber else { throw JellyfinRotationFailure.code("authored_preview_invalid") }
        return CGSize(width:width.doubleValue,height:height.doubleValue)
    }
    private func preview(_ library:LibraryStore,_ server:MediaServer,_ clip:Clip) async throws -> CGSize {
        await library.rotationQueue.refreshItems(server,ids:[clip.id])
        guard let state=library.rotationQueue.record(server:server,itemID:clip.id).value,
              let revision=state.revision,library.rotationQueue.previewURL(server:server,itemID:clip.id,state:state) != nil else { throw JellyfinRotationFailure.code("authored_preview_state_missing") }
        let bytes=try await fetch(server,"GlideToolkit/Items/\(clip.id)/RotationPreview",query:["revision":revision],maximum:4*1024*1024)
        value["previewBytes"]=bytes.count;return try imageSize(bytes)
    }
    private func singleClient(_ server:MediaServer,_ clip:Clip) throws -> JellyfinRotationClient {
        let video=Video(id:server.id.uuidString+clip.id,title:clip.title,subtitle:"原创批量验证",sourceID:server.id,remoteID:clip.id)
        guard let target=JellyfinRotationTarget(video:video,server:server,resourceURL:ServerURL.endpoint(server.address,"Items/\(clip.id)/File"),mediaSourceID:clip.sourceID) else { throw JellyfinRotationFailure.code("authored_target_invalid") }
        return JellyfinRotationClient(target:target)
    }
    private func discover(_ library:LibraryStore,_ server:MediaServer,original:Data,offset:Int) async throws -> [Clip] {
        let response=try await json(server,"Items",query:["UserId":server.userID ?? "","Recursive":"true","SearchTerm":"GlideRotationQA","Fields":"MediaSources,Path","Limit":"200"])
        let items=response["Items"] as? [[String:Any]] ?? []
        let allowed=Set((UserDefaults.standard.string(forKey:"glideNASBatchVerifiedItems") ?? "").split(separator:",").map { String($0).lowercased() })
        var clips:[Clip]=[],seen=Set<String>()
        for item in items {
            guard clips.count<2,let id=item["Id"] as? String,allowed.contains(id.lowercased()),
                  let path=item["Path"] as? String,ownedName(path),seen.insert(path).inserted else { continue }
            let detail=try await json(server,"Items/"+id,query:["UserId":server.userID ?? ""])
            guard let source=(detail["MediaSources"] as? [[String:Any]])?.first(where:{$0["Path"] as? String == path}),let sourceID=source["Id"] as? String,
                  let bytes=try? await fetch(server,"Items/\(id)/File",maximum:original.count+1),samePayload(bytes,original,offset:offset) else { continue }
            clips.append(Clip(id:id,sourceID:sourceID,title:URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent,bytes:bytes))
        }
        value["verifiedAuthoredClips"]=clips.count
        if clips.count>=2 { return clips }
        value["requiresFixtureCopies"]=true;value["availableAuthoredName"]=clips.first?.title ?? ""
        stage("需要两份已入库的原创测试副本，再点重新验证")
        return []
    }
    private func inventory(_ library:LibraryStore) async throws {
        value["readOnly"]=true;stage("只读核对原创样片，不修改远程文件")
        guard let local=Bundle.main.url(forResource:"demo0",withExtension:"mp4") else { throw JellyfinRotationFailure.code("authored_fixture_missing") }
        let original=try Data(contentsOf:local),offset=Int(try VideoFileRotation.inspect(local,turn:.original).matrixOffset)
        var sources:[[String:Any]]=[]
        for server in library.servers where server.kind == .jellyfin {
            var entry:[String:Any]=["sourceID":server.id.uuidString]
            guard let cap:JellyfinRotationCapability=try? await JellyfinRotationClient.request(server:server,path:"Capabilities") else {
                entry["capabilityReadable"]=false;sources.append(entry);continue
            }
            entry["pluginVersion"]=cap.pluginVersion;entry["available"]=cap.available
            guard cap.available,cap.supportsBatchRotation else { sources.append(entry);continue }
            let response=try await json(server,"Items",query:["UserId":server.userID ?? "","Recursive":"true","SearchTerm":"GlideRotationQA","Fields":"MediaSources,Path","Limit":"200"])
            let items=response["Items"] as? [[String:Any]] ?? []
            var proven:[[String:Any]]=[]
            for item in items {
                guard let id=item["Id"] as? String,let path=item["Path"] as? String,ownedName(path) else { continue }
                guard let bytes=try? await fetch(server,"Items/\(id)/File",maximum:original.count+1),samePayload(bytes,original,offset:offset) else { continue }
                proven.append(["itemID":id,"name":URL(fileURLWithPath:path).lastPathComponent,"bytes":bytes.count,"allOtherBytesMatchBundledSample":true])
            }
            entry["searchCandidates"]=items.count;entry["verifiedAuthoredClips"]=proven;sources.append(entry)
        }
        value["sources"]=sources;value["passed"]=true
        stage("只读核对完成；未提交旋转、还原或上传")
    }
    private func execute(_ library:LibraryStore) async throws {
        stage("核对 NAS 插件和原创样片")
        guard let local=Bundle.main.url(forResource:"demo0",withExtension:"mp4") else { throw JellyfinRotationFailure.code("authored_fixture_missing") }
        let original=try Data(contentsOf:local),patch=try VideoFileRotation.inspect(local,turn:.clockwise)
        let offset=Int(patch.matrixOffset)
        let saved=try journal.load()?.value
        var selected:MediaServer?
        guard let source=UserDefaults.standard.string(forKey:"glideNASBatchVerifiedSource"),let verifiedSource=UUID(uuidString:source),
              let itemList=UserDefaults.standard.string(forKey:"glideNASBatchVerifiedItems"),Set(itemList.split(separator:",")).count==2 else { throw JellyfinRotationFailure.code("explicit_authored_targets_required") }
        let allowedIDs=Set(itemList.split(separator:",").map { String($0).lowercased() })
        for server in library.servers where server.kind == .jellyfin {
            guard server.id==verifiedSource else { continue }
            if let saved,saved.serverID != server.id { continue }
            guard let cap: JellyfinRotationCapability = try? await JellyfinRotationClient.request(server:server,path:"Capabilities"),cap.available,cap.supportsBatchRotation else { continue }
            value["pluginVersion"]=cap.pluginVersion;selected=server;break
        }
        guard let server=selected else { throw JellyfinRotationFailure.code("batch_plugin_or_saved_server_not_found") }
        try check(true,"nas_plugin_110_available")
        var state:State
        if let saved { guard saved.userID==server.userID else { throw JellyfinRotationFailure.code("source_changed") };state=saved }
        else {
            let clips=try await discover(library,server,original:original,offset:offset)
            guard clips.count==2 else { return }
            state=State(serverID:server.id,userID:server.userID,requestID:UUID(),clips:clips)
            try journal.save(state)
        }
        guard Set(state.clips.map { $0.id.lowercased() })==allowedIDs else { throw JellyfinRotationFailure.code("authored_target_selection_changed") }
        value["authoredItemIDs"]=state.clips.map(\.id)
        if state.passed { value["passed"]=true;stage("已完成批量验收，原样还原记录已保留");return }
        // Validate persisted baseline again before any accepted POST can be replayed.
        try check(state.clips.count==2 && Set(state.clips.map(\.id)).count==2 && state.clips.allSatisfy { samePayload($0.bytes,original,offset:offset) },"only_two_byte_verified_authored_clips_selected")
        if state.batchID == nil {
            stage("提交两份原创短片到服务器队列")
            let videos=state.clips.map { Video(id:server.id.uuidString+$0.id,title:$0.title,subtitle:"原创批量验证",sourceID:server.id,remoteID:$0.id) }
            let result=try await library.rotationQueue.submit(server,videos:videos,turns:1,requestID:state.requestID)
            state.batchID=result.batchId;try journal.save(state)
        }
        guard let batchID=state.batchID else { throw JellyfinRotationFailure.code("authored_batch_missing") }
        value["batchID"]=batchID.uuidString
        if !state.pauseChecked {
            var paused=try await library.rotationQueue.change(server,batch:batchID,action:"pause")
            let pauseDeadline=Date().addingTimeInterval(45)
            while paused.state == "pausing",Date()<pauseDeadline {
                try await Task.sleep(for:.milliseconds(500));paused=try await library.rotationQueue.detail(server,id:batchID)
            }
            value["pauseObservedWithPendingFiles"]=paused.state == "paused" && paused.remaining>0
            if paused.state == "paused" {
                let completed=paused.completed
                try await Task.sleep(for:.seconds(2))
                let still=try await library.rotationQueue.detail(server,id:batchID)
                try check(still.state == "paused" && still.completed==completed,"nas_paused_queue_does_not_start_next_file")
                _=try await library.rotationQueue.change(server,batch:batchID,action:"resume")
            } else if paused.state == "pausing" {
                _=try await library.rotationQueue.change(server,batch:batchID,action:"resume")
            }
            state.pauseChecked=true;try journal.save(state)
        }
        stage("等待 NAS 完成批量旋转")
        var batch=try await library.rotationQueue.detail(server,id:batchID)
        let deadline=Date().addingTimeInterval(240)
        while batch.active {
            value["completed"]=batch.completed;value["remaining"]=batch.remaining;value["failed"]=batch.failed
            value["currentStage"]=batch.current?.stage ?? "";publish(value)
            guard Date()<deadline else { throw JellyfinRotationFailure.code("authored_batch_timeout") }
            try await Task.sleep(for:.seconds(1));batch=try await library.rotationQueue.detail(server,id:batchID)
        }
        value["batchState"]=batch.state
        value["completed"]=batch.completed;value["remaining"]=batch.remaining;value["failed"]=batch.failed
        value["children"]=(batch.items ?? []).map { entry -> [String:Any] in
            ["itemID":entry.itemId,"jobID":entry.jobId?.uuidString ?? "","state":entry.state,"errorCode":entry.errorCode ?? ""]
        }
        publish(value)
        try check(batch.completed==2 && batch.remaining==0 && batch.failed==0 && batch.needsVerification==0,"nas_batch_two_saved_zero_remaining_zero_failed")
        value["completed"]=batch.completed;value["remaining"]=batch.remaining;value["failed"]=batch.failed
        let body=RotationBatchRequest(requestId:state.requestID,quarterTurns:1,items:state.clips.map { RotationBatchItem(itemId:$0.id,title:$0.title) })
        let repeated:RotationBatch=try await JellyfinRotationClient.request(server:server,path:"Batches",method:"POST",body:JSONEncoder().encode(body))
        try check(repeated.batchId==batchID,"same_batch_request_is_idempotent_on_real_nas")
        let workspace=FileManager.default.temporaryDirectory.appendingPathComponent("GlideNASBatch-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:workspace) }
        for index in state.clips.indices {
            let clip=state.clips[index],client=try singleClient(server,clip)
            guard let entry=batch.items?.first(where:{$0.itemId.lowercased()==clip.id.lowercased()}),let jobID=entry.jobId else { throw JellyfinRotationFailure.code("authored_child_missing") }
            if state.clips[index].restore == nil {
                stage("核对第 \(index+1) 个视频的新预览与方向状态")
                let bytes=try await fetch(server,"Items/\(clip.id)/File",maximum:original.count+1)
                let before=workspace.appendingPathComponent("before.mp4"),after=workspace.appendingPathComponent("after.mp4")
                try clip.bytes.write(to:before);try bytes.write(to:after)
                let expected=try VideoFileRotation.inspect(before,turn:.clockwise),actual=try VideoFileRotation.inspect(after,turn:.original)
                try check(samePayload(bytes,clip.bytes,offset:offset) && actual.original==expected.replacement,"nas_matrix_and_other_bytes_correct_\(index)")
                let beforeFrame=AVAssetImageGenerator(asset:AVURLAsset(url:before));beforeFrame.appliesPreferredTrackTransform=true
                let frame=try await beforeFrame.image(at:CMTime(seconds:0.5,preferredTimescale:600)).image
                let size=try await preview(library,server,clip)
                try check(abs(size.width/size.height-Double(frame.height)/Double(frame.width))<0.03,"nas_regenerated_preview_has_rotated_aspect_\(index)")
                try check(library.rotationQueue.record(server:server,itemID:clip.id).value?.state=="completed","client_list_saved_badge_\(index)")
                let capability=try await client.capability()
                guard let version=capability.version else { throw JellyfinRotationFailure.code("authored_version_missing") }
                state.clips[index].restore=JellyfinRotationRequest(requestId:UUID(),itemId:clip.id,mediaSourceId:clip.sourceID,expectedVersion:version,quarterTurns:0,restoreJobId:jobID)
                try journal.save(state)
            }
            stage("原样还原第 \(index+1) 个原创测试副本")
            guard let restore=state.clips[index].restore else { throw JellyfinRotationFailure.code("authored_restore_missing") }
            var job=try await client.submit(restore)
            let limit=Date().addingTimeInterval(120)
            while job.isActive {
                guard Date()<limit else { throw JellyfinRotationFailure.code("authored_restore_timeout") }
                try await Task.sleep(for:.milliseconds(500));job=try await client.job(job.jobId)
            }
            try check(job.completed,"nas_child_backup_restored_\(index)")
            let final=try await fetch(server,"Items/\(clip.id)/File",maximum:original.count+1)
            try check(final==clip.bytes,"nas_restore_is_byte_identical_\(index)")
            _=try await preview(library,server,clip)
            try check(library.rotationQueue.record(server:server,itemID:clip.id).value?.restored==true,"client_list_restored_badge_\(index)")
        }
        state.passed=true;try journal.save(state)
        value["passed"]=true;value["authoredFixturesRetained"]=true;value["serverBackupsRetained"]=true
        stage("真机批量旋转、新预览与原样还原验证通过")
    }
}

#endif
