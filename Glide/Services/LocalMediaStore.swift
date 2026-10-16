import Foundation
import AVFoundation
import UIKit

enum LocalMediaStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ImportedMedia", isDirectory: true)
    }
    static func managedDirectory(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func access(_ server: MediaServer) throws -> LocalFileAccess {
        guard server.kind == .local else { throw MediaError.message("此来源不是本地目录。") }
        let root: URL
        if let bookmark = server.localBookmark {
            var stale = false
            root = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        } else { root = managedDirectory(server.id) }
        return LocalFileAccess(root: root)
    }
    static func mount(_ url: URL) throws -> MediaServer {
        let access = LocalFileAccess(root: url)
        defer { withExtendedLifetime(access) {} }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw MediaError.message("请选择一个视频目录。") }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        return MediaServer(name: url.lastPathComponent, kind: .local, address: url, username: "", localBookmark: bookmark)
    }
    static func playback(_ video: Video, server: MediaServer) throws -> PlaybackResource {
        let access = try access(server)
        let relative = try video.localRelativePath ?? video.url.map { try LocalMediaIdentity.relativePath(root: server.address, file: $0) }
        guard let relative, !relative.isEmpty else { throw MediaError.message("找不到本地视频，请重新选择目录。") }
        let url = try LocalMediaIdentity.fileURL(root: access.root, relativePath: relative)
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw MediaError.message("本地文件已移动或无法读取，请在来源管理中重新授权目录。") }
        return PlaybackResource(url: url, delivery: .local, localAccess: access)
    }

    /// Stage the whole selection first, so cancellation/failure never publishes half an import.
    static func importFiles(_ urls: [URL], server: MediaServer) async throws -> Int {
        let operation = Task.detached {
            let root = managedDirectory(server.id), manager = FileManager.default
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let staging = root.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: staging) }
            var staged: [URL] = [], published: [URL] = []
            do {
                for url in urls {
                    try Task.checkCancellation()
                    guard DirectoryScope.isVideo(url) else { throw MediaError.message("请选择视频文件。") }
                    let access = LocalFileAccess(root: url)
                    defer { withExtendedLifetime(access) {} }
                    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                    guard values.isSymbolicLink != true, values.isRegularFile == true else {
                        throw MediaError.message("请选择原始视频文件。")
                    }
                    let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
                    var name = url.lastPathComponent, suffix = 2
                    while manager.fileExists(atPath: staging.appendingPathComponent(name).path) || manager.fileExists(atPath: root.appendingPathComponent(name).path) {
                        name = "\(base) (\(suffix)).\(ext)"; suffix += 1
                    }
                    let target = staging.appendingPathComponent(name)
                    let coordinator = NSFileCoordinator()
                    var coordinatorError: NSError?, copyError: Error?
                    coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { readable in
                        do { try manager.copyItem(at: readable, to: target) } catch { copyError = error }
                    }
                    if let error = coordinatorError { throw error }
                    if let error = copyError { throw error }
                    staged.append(target)
                }
                try Task.checkCancellation()
                for file in staged {
                    let target = root.appendingPathComponent(file.lastPathComponent)
                    try manager.moveItem(at: file, to: target); published.append(target)
                }
                return published.count
            } catch {
                published.forEach { try? manager.removeItem(at: $0) }
                throw error
            }
        }
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
}

@MainActor enum LocalArtwork {
    private static let cache: NSCache<NSString, UIImage> = {
        let result = NSCache<NSString, UIImage>(); result.totalCostLimit = 24 * 1024 * 1024; return result
    }()
    private static var active = 0
    static func clear() { cache.removeAllObjects() }
    static func image(video: Video, server: MediaServer) async -> UIImage? {
        guard let resource = try? LocalMediaStore.playback(video, server: server) else { return nil }
        let modified = (try? resource.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = (video.id + ":" + String(modified)) as NSString
        if let image = cache.object(forKey: key) { return image }
        while active >= 2 {
            do { try await Task.sleep(for: .milliseconds(75)) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        active += 1; defer { active -= 1; withExtendedLifetime(resource) {} }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: resource.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        do {
            let generated = try await withTaskCancellationHandler {
                try await generator.image(at: CMTime(seconds: 0, preferredTimescale: 600))
            } onCancel: { generator.cancelAllCGImageGeneration() }
            try Task.checkCancellation()
            let image = UIImage(cgImage: generated.image)
            cache.setObject(image, forKey: key, cost: generated.image.bytesPerRow * generated.image.height)
            return image
        } catch { return nil }
    }
}
