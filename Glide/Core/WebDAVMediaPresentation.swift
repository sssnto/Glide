import Foundation

/// Only the actual file URL of the active WebDAV source may be replaced.
struct WebDAVRotationTarget: Equatable, Sendable {
    let server: MediaServer
    let file: URL
    init?(video: Video, server: MediaServer?, playingURL: URL?) {
        guard let server,server.kind == .webDAV,video.sourceID==server.id,video.offlineOnly != true,
              video.streamLinkID==nil,let file=video.url,playingURL==file,
              ["mp4","mov","m4v"].contains(file.pathExtension.lowercased()),
              file.user==nil,file.password==nil,file.query==nil,file.fragment==nil,
              DirectoryScope.contains(root:server.address,child:file) else { return nil }
        self.server=server;self.file=file
    }
}

enum DirectoryCoverCandidates {
    /// Stop after a few candidates; folder-only chains inherit a descendant's cover.
    static func find(root: URL, maximumDirectories: Int = 32, fetch: (URL) async throws -> [DAVEntry]) async throws -> [DAVEntry] {
        var pending:[(URL,Int)]=[(root,0)],visited=Set<String>(),cursor=0,result:[DAVEntry]=[],seen=Set<String>()
        while cursor<pending.count,visited.count<maximumDirectories,result.count<3 {
            try Task.checkCancellation()
            let (directory,depth)=pending[cursor];cursor+=1
            guard visited.insert(DirectoryScope.key(directory)).inserted else { continue }
            let raw: [DAVEntry]
            do { raw=try await fetch(directory) }
            catch is CancellationError { throw CancellationError() }
            catch { if directory==root { throw error } else { continue } }
            let entries=raw.filter {
                DirectoryScope.contains(root:root,child:$0.url) && DirectoryScope.contains(root:directory,child:$0.url)
                && $0.url.user==nil && $0.url.password==nil && $0.url.query==nil && $0.url.fragment==nil
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let images=entries.filter { !$0.isDirectory && ["jpg","jpeg","png","webp","heic"].contains($0.url.pathExtension.lowercased()) }
            let preferred=["folder","cover","poster","thumb"]
            let ordered=images.filter { preferred.contains($0.url.deletingPathExtension().lastPathComponent.lowercased()) }
                + entries.filter { !$0.isDirectory && DirectoryScope.isVideo($0.url) } + images
            for entry in ordered where seen.insert(DirectoryScope.key(entry.url)).inserted {
                result.append(entry);if result.count==3 { break }
            }
            if depth<12 { pending += entries.filter(\.isDirectory).map { ($0.url,depth+1) } }
        }
        return result
    }
}
