import Foundation
import CryptoKit

struct DirectoryCacheIdentity: Codable, Equatable, Sendable {
    let sourceID: UUID
    let root: URL
    let account: String
    init(_ server: MediaServer) {
        sourceID=server.id;root=server.address
        account=SHA256.hash(data:Data((server.username+"\n"+(server.userID ?? "")).utf8)).map { String(format:"%02x",$0) }.joined()
    }
    var filename: String {
        SHA256.hash(data:Data((sourceID.uuidString+"\n"+DirectoryScope.key(root)+"\n"+account).utf8)).map { String(format:"%02x",$0) }.joined()+".json"
    }
}
struct CachedDirectoryListing: Codable, Equatable, Sendable {
    var directory: URL
    var entries: [DAVEntry]
    var date: Date
}
struct CachedDirectoryScan: Sendable {
    var videos: [DAVEntry]
    var directories: [DAVEntry]
    var date: Date
}

/// Complete Depth-1 listings, committed only after a successful scan. A recursive
/// hit requires every reachable directory, including empty ones, to be present.
actor DirectoryListingCache {
    static let shared=DirectoryListingCache(directory:FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("WebDAVDirectoryIndex",isDirectory:true))
    private struct Index: Codable {
        var identity: DirectoryCacheIdentity
        var listings: [String:CachedDirectoryListing]
    }
    private let directory: URL
    private var memory: [String:Index] = [:]
    private var order: [String] = []
    init(directory: URL) { self.directory=directory }
    func listing(_ identity: DirectoryCacheIdentity, directory root: URL) -> CachedDirectoryListing? {
        guard valid(root,identity:identity) else { return nil }
        return load(identity)?.listings[DirectoryScope.key(root)]
    }

    func scan(_ identity: DirectoryCacheIdentity, directory root: URL, recursive: Bool) -> CachedDirectoryScan? {
        guard valid(root,identity:identity),let index=load(identity) else { return nil }
        var pending=[root],seen=Set<String>(),files=Set<String>(),videos:[DAVEntry]=[],cursor=0,date=Date.distantFuture
        guard let initial=index.listings[DirectoryScope.key(root)] else { return nil }
        while cursor<pending.count {
            let folder=pending[cursor];cursor+=1
            guard seen.insert(DirectoryScope.key(folder)).inserted else { continue }
            guard let listing=index.listings[DirectoryScope.key(folder)] else { return nil }
            date=min(date,listing.date)
            for entry in listing.entries where DirectoryScope.contains(root:root,child:entry.url) {
                if entry.isDirectory { if recursive { pending.append(entry.url) } }
                else if DirectoryScope.isVideo(entry.url),files.insert(DirectoryScope.key(entry.url)).inserted { videos.append(entry) }
            }
        }
        return CachedDirectoryScan(videos:videos,directories:initial.entries.filter(\.isDirectory),date:date)
    }
    func store(_ identity: DirectoryCacheIdentity, root: URL, recursive: Bool, listings: [CachedDirectoryListing]) throws {
        guard !listings.isEmpty,valid(root,identity:identity),listings.allSatisfy({ listing in
            valid(listing.directory,identity:identity) && DirectoryScope.contains(root:root,child:listing.directory)
            && listing.entries.allSatisfy { valid($0.url,identity:identity) && DirectoryScope.contains(root:listing.directory,child:$0.url) }
        }) else { return }
        var index=load(identity) ?? Index(identity:identity,listings:[:])
        if recursive { index.listings=index.listings.filter { !DirectoryScope.contains(root:root,child:$0.value.directory) } }
        for listing in listings {
            if let old=index.listings[DirectoryScope.key(listing.directory)] {
                let current=Set(listing.entries.filter(\.isDirectory).map { DirectoryScope.key($0.url) })
                let removed=old.entries.filter { $0.isDirectory && !current.contains(DirectoryScope.key($0.url)) }.map(\.url)
                index.listings=index.listings.filter { item in !removed.contains { DirectoryScope.contains(root:$0,child:item.value.directory) } }
            }
            index.listings[DirectoryScope.key(listing.directory)]=listing
        }
        guard index.listings.count<=10_000,index.listings.values.reduce(0,{ $0+$1.entries.count })<=100_000,
              try JSONEncoder().encode(index).count<=24*1024*1024 else { return }
        try RecoverableStore(file:directory.appendingPathComponent(identity.filename)).save(index)
        remember(index);trimDisk()
    }
    func remove(sourceID: UUID) {
        memory=memory.filter { $0.value.identity.sourceID != sourceID };order=order.filter { memory[$0] != nil }
        for file in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] where file.pathExtension=="json" {
            if let value=try? RecoverableStore<Index>(file:file).load()?.value,value.identity.sourceID==sourceID {
                try? FileManager.default.removeItem(at:file);try? FileManager.default.removeItem(at:file.appendingPathExtension("backup"))
            }
        }
    }
    private func valid(_ url: URL, identity: DirectoryCacheIdentity) -> Bool {
        ["http","https"].contains(url.scheme?.lowercased() ?? "") && url.user==nil && url.password==nil && url.query==nil && url.fragment==nil && DirectoryScope.contains(root:identity.root,child:url)
    }
    private func load(_ identity: DirectoryCacheIdentity) -> Index? {
        if let hit=memory[identity.filename] { remember(hit);return hit }
        let file=directory.appendingPathComponent(identity.filename)
        guard let size=try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=24*1024*1024,
              let index=try? RecoverableStore<Index>(file:file).load()?.value,index.identity==identity,
              index.listings.count<=10_000,index.listings.values.allSatisfy({ listing in
                  valid(listing.directory,identity:identity) && listing.entries.allSatisfy { valid($0.url,identity:identity) && DirectoryScope.contains(root:listing.directory,child:$0.url) }
              }) else { return nil }
        remember(index);return index
    }
    private func remember(_ value: Index) {
        let key=value.identity.filename;memory[key]=value;order.removeAll { $0==key };order.append(key)
        while order.count>4 { memory.removeValue(forKey:order.removeFirst()) }
    }
    private func trimDisk() {
        let files=((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey,.fileSizeKey])) ?? []).filter { $0.pathExtension=="json" }.sorted {
            ((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var size=0
        for (index,file) in files.enumerated() {
            size += ((try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)+((try? file.appendingPathExtension("backup").resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)
            if index>=12 || size>96*1024*1024 {
                try? FileManager.default.removeItem(at:file);try? FileManager.default.removeItem(at:file.appendingPathExtension("backup"))
                memory.removeValue(forKey:file.lastPathComponent);order.removeAll { $0==file.lastPathComponent }
            }
        }
    }
}
