import Foundation
import Testing
@testable import GlideCore

struct DirectoryListingCacheTests {
    private func source() -> MediaServer { MediaServer(name:"NAS",kind:.webDAV,address:URL(string:"https://nas.invalid/videos/")!,username:"viewer") }
    private func temporary() throws -> URL {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);return dir
    }
    private func file(_ root: URL,_ name: String) -> DAVEntry { DAVEntry(url:root.appendingPathComponent(name),name:name,isDirectory:false) }
    @Test func completedLargeLibrarySurvivesNewCacheInstance() async throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        let server=source(),identity=DirectoryCacheIdentity(server)
        let entries=(0..<1649).map { file(server.address,"video-\($0).mp4") }
        try await DirectoryListingCache(directory:dir).store(identity,root:server.address,recursive:true,listings:[CachedDirectoryListing(directory:server.address,entries:entries,date:Date())])
        let restored=await DirectoryListingCache(directory:dir).scan(identity,directory:server.address,recursive:true)
        #expect(restored?.videos.count==1649)
    }
    @Test func subtreeAndNonrecursiveViewsReuseOneCompleteIndex() async throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        let server=source(),identity=DirectoryCacheIdentity(server),cache=DirectoryListingCache(directory:dir)
        let child=server.address.appendingPathComponent("Season",isDirectory:true)
        try await cache.store(identity,root:server.address,recursive:true,listings:[
            CachedDirectoryListing(directory:server.address,entries:[file(server.address,"root.mp4"),DAVEntry(url:child,name:"Season",isDirectory:true)],date:Date()),
            CachedDirectoryListing(directory:child,entries:[file(child,"episode.mp4")],date:Date())])
        #expect(await cache.scan(identity,directory:server.address,recursive:true)?.videos.count==2)
        #expect(await cache.scan(identity,directory:server.address,recursive:false)?.videos.count==1)
        #expect(await cache.scan(identity,directory:child,recursive:true)?.videos.first?.name=="episode.mp4")
    }
    @Test func missingChildIsNotACompleteRecursiveHitButEmptyDirectoryIs() async throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        let server=source(),identity=DirectoryCacheIdentity(server),cache=DirectoryListingCache(directory:dir)
        let child=server.address.appendingPathComponent("Empty",isDirectory:true)
        try await cache.store(identity,root:server.address,recursive:false,listings:[CachedDirectoryListing(directory:server.address,entries:[DAVEntry(url:child,name:"Empty",isDirectory:true)],date:Date())])
        #expect(await cache.scan(identity,directory:server.address,recursive:true)==nil)
        try await cache.store(identity,root:child,recursive:true,listings:[CachedDirectoryListing(directory:child,entries:[],date:Date())])
        #expect(await cache.scan(identity,directory:server.address,recursive:true)?.videos.isEmpty==true)
        #expect(await cache.scan(identity,directory:child,recursive:true)?.videos.isEmpty==true)
    }
    @Test func refreshingChildChangesParentResultsAndDropsRemovedDescendants() async throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        let server=source(),identity=DirectoryCacheIdentity(server),cache=DirectoryListingCache(directory:dir)
        let child=server.address.appendingPathComponent("Child",isDirectory:true),deep=child.appendingPathComponent("Deep",isDirectory:true)
        try await cache.store(identity,root:server.address,recursive:true,listings:[
            CachedDirectoryListing(directory:server.address,entries:[DAVEntry(url:child,name:"Child",isDirectory:true)],date:Date()),
            CachedDirectoryListing(directory:child,entries:[DAVEntry(url:deep,name:"Deep",isDirectory:true)],date:Date()),
            CachedDirectoryListing(directory:deep,entries:[file(deep,"old.mp4")],date:Date())])
        try await cache.store(identity,root:child,recursive:true,listings:[CachedDirectoryListing(directory:child,entries:[file(child,"new.mp4")],date:Date())])
        #expect(await cache.scan(identity,directory:server.address,recursive:true)?.videos.map(\.name)==["new.mp4"])
        #expect(await cache.scan(identity,directory:deep,recursive:true)==nil)
    }
    @Test func accountSourceAndRootAreIsolatedAndRemovalPersists() async throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        let server=source(),identity=DirectoryCacheIdentity(server),cache=DirectoryListingCache(directory:dir)
        try await cache.store(identity,root:server.address,recursive:true,listings:[CachedDirectoryListing(directory:server.address,entries:[file(server.address,"private.mp4")],date:Date())])
        var other=server;other.username="another"
        #expect(await cache.scan(DirectoryCacheIdentity(other),directory:server.address,recursive:true)==nil)
        other=server;other.address=URL(string:"https://nas.invalid/other/")!
        #expect(await cache.scan(DirectoryCacheIdentity(other),directory:other.address,recursive:true)==nil)
        other=server;other.id=UUID()
        #expect(await cache.scan(DirectoryCacheIdentity(other),directory:server.address,recursive:true)==nil)
        await cache.remove(sourceID:server.id)
        #expect(await DirectoryListingCache(directory:dir).scan(identity,directory:server.address,recursive:true)==nil)
    }
    @Test func shallowRefreshRemovesDeletedChildIndexAndCorruptCacheIsAMiss() async throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        let server=source(),identity=DirectoryCacheIdentity(server),cache=DirectoryListingCache(directory:dir)
        let child=server.address.appendingPathComponent("Removed",isDirectory:true)
        try await cache.store(identity,root:server.address,recursive:true,listings:[CachedDirectoryListing(directory:server.address,entries:[DAVEntry(url:child,name:"Removed",isDirectory:true)],date:Date()),CachedDirectoryListing(directory:child,entries:[file(child,"old.mp4")],date:Date())])
        try await cache.store(identity,root:server.address,recursive:false,listings:[CachedDirectoryListing(directory:server.address,entries:[],date:Date())])
        #expect(await cache.scan(identity,directory:child,recursive:true)==nil)
        try Data("broken".utf8).write(to:dir.appendingPathComponent(identity.filename))
        try? FileManager.default.removeItem(at:dir.appendingPathComponent(identity.filename).appendingPathExtension("backup"))
        #expect(await DirectoryListingCache(directory:dir).scan(identity,directory:server.address,recursive:true)==nil)
    }
    @Test func invalidAndCredentialBearingEntriesAreNotStored() async throws {
        let dir=try temporary();defer { try? FileManager.default.removeItem(at:dir) }
        let server=source(),identity=DirectoryCacheIdentity(server),cache=DirectoryListingCache(directory:dir)
        for url in [URL(string:"https://nas.invalid/outside.mp4")!,URL(string:"https://viewer:secret@nas.invalid/videos/video.mp4")!,URL(string:"https://nas.invalid/videos/video.mp4?token=secret")!] {
            try await cache.store(identity,root:server.address,recursive:true,listings:[CachedDirectoryListing(directory:server.address,entries:[DAVEntry(url:url,name:"video",isDirectory:false)],date:Date())])
            #expect(await cache.scan(identity,directory:server.address,recursive:true)==nil)
        }
    }
}
