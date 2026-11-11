#if DEBUG
import SwiftUI

struct DirectoryCacheQAProbe: View {
    var library: LibraryStore
    var live = false
    @State private var status = "正在验证"
    @State private var detail = ""
    @State private var returned = false
    var body: some View {
        Group {
            if returned { AdaptiveLibraryRoot(library:library) }
            else {
        NavigationStack {
            List { Text(status).accessibilityIdentifier("directory.qa.status");Text(detail).font(.caption) }
                .navigationTitle("目录缓存验证")
                .toolbar { if live { Button("返回片库") { returned=true } } }
        }
            }
        }.task { await run() }
    }
    @MainActor private func run() async {
        var checks: [String:Bool]=[:],counts:[String:Int]=[:]
        do {
            if live {
                guard let server=library.selectedServer,server.kind == .webDAV else { throw MediaError.message("请先选择 WebDAV 来源。") }
                detail="首次建立完整目录索引，随后验证重复进入和磁盘恢复。"
                await library.loadIfNeeded()
                guard !library.loading,library.error==nil,!library.scanStopped,library.directoryScanDate != nil else { throw MediaError.message("目录尚未完成扫描。") }
                let baseline=DirectoryRequestQA.counts[server.id,default:0],expected=library.videos.count
                await library.select(server.id)
                for _ in 0..<3 { await library.loadIfNeeded() }
                counts["repeatSelectionRequests"]=DirectoryRequestQA.counts[server.id,default:0]-baseline
                checks["reentryWithoutRequests"]=counts["repeatSelectionRequests"]==0
                let fresh=LibraryStore();await fresh.loadIfNeeded()
                checks["newStoreRestoresDiskIndex"]=fresh.videos.count==expected && fresh.directoryScanDate != nil && fresh.error==nil
                let queue=try await fresh.collectPlaybackVideos { _ in }
                checks["queueUsesIndex"]=queue.count==expected
                counts["allRequestsAfterIndex"]=DirectoryRequestQA.counts[server.id,default:0]-baseline
                checks["noRequestsAfterIndex"]=counts["allRequestsAfterIndex"]==0
                counts["videoCount"]=expected
            } else {
                let resumed=ProcessInfo.processInfo.arguments.contains("--glide-directory-cache-resume")
                let runID=resumed ? UserDefaults.standard.string(forKey:"directoryProbeRun") ?? UUID().uuidString : UUID().uuidString
                UserDefaults.standard.set(runID,forKey:"directoryProbeRun")
                let serverID=resumed ? UserDefaults.standard.string(forKey:"directoryProbeSource").flatMap(UUID.init(uuidString:)) ?? UUID() : UUID()
                UserDefaults.standard.set(serverID.uuidString,forKey:"directoryProbeSource")
                let root=URL(string:"http://127.0.0.1:8829/run-"+runID+"/")!
                let server=MediaServer(id:serverID,name:"原创目录",kind:.webDAV,address:root,username:"glide")
                try Credentials.save("directory-fixture",for:server.id)
                let folder=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("DirectoryCacheQA/"+runID)
                let cache=DirectoryListingCache(directory:folder)
                let store=LibraryStore(directoryCache:cache);store.servers=[server]
                await store.select(server.id)
                if resumed {
                    checks["processRestartUsesDisk"]=store.videos.count==650 && DirectoryRequestQA.counts[server.id,default:0]==0
                } else {
                    let first=DirectoryRequestQA.counts[server.id,default:0]
                    checks["firstScan"]=store.videos.count==649 && first==3
                    await store.select(server.id);await store.loadIfNeeded()
                    store.showDemo();await store.select(server.id)
                    await store.enter(root.appendingPathComponent("Child",isDirectory:true))
                    checks["subtree"]=store.videos.count==4
                    await store.back()
                    var options=store.browseOptions;options.sort = .nameDescending;await store.setBrowseOptions(options)
                    await store.setFolderSort(.nameDescending)
                    options.includesDescendants=false;await store.setBrowseOptions(options)
                    checks["nonrecursive"]=store.videos.count==645
                    options.includesDescendants=true;await store.setBrowseOptions(options)
                    let queue=try await store.collectPlaybackVideos(search:"episode") { _ in }
                    checks["queue"]=queue.count==649
                    let fresh=LibraryStore(directoryCache:DirectoryListingCache(directory:folder));fresh.servers=[server];await fresh.select(server.id)
                    checks["newStoreDisk"]=fresh.videos.count==649
                    await fresh.enter(root.appendingPathComponent("Empty",isDirectory:true))
                    for _ in 0..<4 { await fresh.loadIfNeeded();await fresh.select(server.id) }
                    checks["emptyLoaded"]=fresh.videos.isEmpty && fresh.directoryScanDate != nil
                    checks["allReentryOperationsWithoutRequests"]=DirectoryRequestQA.counts[server.id,default:0]==first
                    counts["firstScan"]=first;counts["requestsAfterReentry"]=DirectoryRequestQA.counts[server.id,default:0]-first
                    await fresh.back()
                    var request=URLRequest(url:root.appendingPathComponent("__advance"));request.httpMethod="POST"
                    _=try await URLSession.shared.data(for:request)
                    await fresh.reload()
                    checks["explicitRefresh"]=fresh.videos.count==650 && DirectoryRequestQA.counts[server.id,default:0]>first
                    let failed=MediaServer(name:"失败目录",kind:.webDAV,address:URL(string:"http://127.0.0.1:8829/failure-"+runID+"/")!,username:"glide")
                    try Credentials.save("directory-fixture",for:failed.id);defer { Credentials.delete(failed.id) }
                    let broken=LibraryStore(directoryCache:cache);broken.servers=[failed];await broken.select(failed.id)
                    let partial=await cache.scan(DirectoryCacheIdentity(failed),directory:failed.address,recursive:true)
                    checks["failedScanNotCommitted"]=broken.error != nil && partial==nil
                    let failedCount=DirectoryRequestQA.counts[failed.id,default:0]
                    await broken.loadIfNeeded();await broken.select(failed.id)
                    checks["failedScanNoAutomaticRetry"]=DirectoryRequestQA.counts[failed.id,default:0]==failedCount
                    let slow=MediaServer(name:"中断目录",kind:.webDAV,address:URL(string:"http://127.0.0.1:8829/slow-"+runID+"/")!,username:"glide")
                    try Credentials.save("directory-fixture",for:slow.id);defer { Credentials.delete(slow.id) }
                    let interrupted=LibraryStore(directoryCache:cache);interrupted.servers=[slow]
                    let job=Task { await interrupted.select(slow.id) }
                    for _ in 0..<100 { if DirectoryRequestQA.counts[slow.id,default:0]>=2 { break };try await Task.sleep(for:.milliseconds(10)) }
                    interrupted.cancelDirectoryScan();await job.value
                    let stopped=await cache.scan(DirectoryCacheIdentity(slow),directory:slow.address,recursive:true)
                    checks["stoppedScanNotCommitted"]=interrupted.scanStopped && stopped==nil
                }
            }
            guard checks.values.allSatisfy({ $0 }),!checks.isEmpty else { throw MediaError.message("缓存契约未全部通过。") }
            status="验证通过";detail="重进、子目录、排序和队列复用索引；显式刷新读取新内容。"
        } catch { status="验证失败";detail=error.localizedDescription }
        let report:[String:Any]=["build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "","result":status,"checks":checks,"counts":counts,"live":live,"time":ISO8601DateFormatter().string(from:Date())]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
            let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            try? data.write(to:root.appendingPathComponent("DirectoryCacheQA.json"),options:.atomic)
            if !live,!ProcessInfo.processInfo.arguments.contains("--glide-directory-cache-resume") { try? data.write(to:root.appendingPathComponent("DirectoryCacheQA-Initial.json"),options:.atomic) }
        }
        if live,status=="验证通过" { try? await Task.sleep(for:.seconds(2));returned=true }
    }
}
#endif
