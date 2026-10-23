import AVFoundation
import CryptoKit
import ImageIO
import Observation
import UIKit

extension MediaClient {
    /// Bounded metadata/image reads, retaining existing same-origin authentication redirects.
    func navigationData(_ url: URL, server: MediaServer, limit: Int) async throws -> Data {
        guard let token = Credentials.read(server.id) else { throw MediaError.message("请重新登录来源。") }
        var request = URLRequest(url: url)
        request.setValue(authorization(token, server: server), forHTTPHeaderField: "Authorization")
        request.allowsCellularAccess = await PlaybackPreferences.cellularPlayback; request.timeoutInterval = 20
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw MediaError.message("无法读取章节或缩略图，请检查来源权限与服务器设置。") }
        guard response.expectedContentLength <= limit else { throw MediaError.message("导航数据超过大小限制。") }
        var result = Data()
        for try await byte in bytes {
            if result.count % 16384 == 0 { try Task.checkCancellation() }
            guard result.count < limit else { throw MediaError.message("导航数据超过大小限制。") }
            result.append(byte)
        }
        return result
    }
    func navigationMetadata(video: Video, server: MediaServer) async throws -> VideoNavigationMetadata {
        guard let item = video.remoteID, let user = server.userID else { throw MediaError.message("来源账号或视频标识无效。") }
        let url = ServerURL.endpoint(server.address, "Users/\(user)/Items/\(item)", query: ["Fields": "MediaSources,Chapters,Trickplay"])
        let data: Data
        do { data = try await navigationData(url, server: server, limit: 2 * 1024 * 1024) }
        catch {
            try Task.checkCancellation()
            let fallback = ServerURL.endpoint(server.address, "Items/\(item)", query: ["UserId": user, "Fields": "MediaSources,Chapters,Trickplay"])
            data = try await navigationData(fallback, server: server, limit: 2 * 1024 * 1024)
        }
        return try JSONDecoder().decode(VideoNavigationMetadata.self, from: data)
    }
}

@MainActor enum MomentResolver {
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func reference(video: Video, library: LibraryStore, resource: PlaybackResource, metadata: VideoNavigationMetadata? = nil) async throws -> MomentReference {
        let server = library.servers.first { $0.id == video.sourceID }
        var kind: MomentReference.Kind
        let revision: String
        var sourceID: String?
        if resource.url.isFileURL {
            kind = video.demoIndex != nil ? .demo : video.remoteID != nil ? .offline : .local
            let values = try resource.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values.fileSize, let modified = values.contentModificationDate else { throw MediaError.message("无法读取本地文件版本。") }
            revision = digest("\(size):\(modified.timeIntervalSince1970)")
        } else if let server, server.kind.isCatalogSource {
            kind = .catalog
            let info: VideoNavigationMetadata
            if let metadata { info = metadata } else { info = try await MediaClient.shared.navigationMetadata(video: video, server: server) }
            guard let selected = info.source(resource.mediaSourceID) else { throw MediaError.message("未能确认当前媒体版本，暂时无法保存或恢复时刻。") }
            sourceID = selected.Id
            revision = digest("\(selected.Id):\(selected.Size ?? -1):\(selected.Container ?? ""):\(selected.Path ?? "")")
        } else if let server, server.kind == .smb {
            kind = .smb
            let location = try SMBLocation(server.address), path = try location.relativePath(resource.url)
            let access = try SMBAccess(server: server, password: Credentials.read(server.id) ?? "")
            let size = try await access.perform { try $0.size(path).uint64Value }
            let entries = try await SMBSourceProvider.entries(server: server, directory: resource.url.deletingLastPathComponent(), password: Credentials.read(server.id) ?? "")
            guard let entry = entries.first(where: { $0.url.path == resource.url.path }), let modified = entry.modifiedAt else { throw MediaError.message("来源未提供文件修改时间，暂时无法确认时刻对应的版本。") }
            revision = digest("\(path):\(size):\(modified.timeIntervalSince1970)")
        } else if let server, server.kind == .webDAV {
            kind = .webDAV
            var request = URLRequest(url: resource.url); request.httpMethod = "HEAD"; request.timeoutInterval = 15
            request.setValue(MediaClient.shared.basic(server: server), forHTTPHeaderField: "Authorization")
            let (_, response) = try await MediaClient.shared.session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let version = http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified") else { throw MediaError.message("来源未提供文件版本信息，暂时无法保存可恢复的时刻。") }
            revision = digest("\(resource.url.path):\(version):\(http.value(forHTTPHeaderField: "Content-Length") ?? "")")
        } else { throw MediaError.message("此链接没有稳定的文件版本，暂时无法收藏时刻。") }
        if video.sourceID != nil, server == nil { throw MediaError.message("视频来源已移除，请重新连接。") }
        return MomentReference(kind: kind, videoID: video.id, sourceID: video.sourceID, accountID: server?.userID ?? server?.username ?? "demo", mediaSourceID: sourceID, revision: revision)
    }
    static func storedVideo(_ video: Video, library: LibraryStore) throws -> Video {
        var saved = PersonalVideo(video: video).video
        if let server = library.servers.first(where: { $0.id == video.sourceID }), server.kind == .smb || server.kind == .webDAV {
            guard let url = video.url, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  let relative = DiscoveryResolver.relative(url, server: server) else { throw MediaError.message("文件位置已超出来源范围。") }
            saved.localRelativePath = relative
        }
        saved.url = nil; saved.artwork = nil
        return saved
    }
    static func resolve(_ moment: MediaMoment, library: LibraryStore) throws -> Video {
        _ = try moment.validated()
        var video = moment.video
        if let index = video.demoIndex, moment.reference.kind == .demo {
            video.url = Bundle.main.url(forResource: "demo\(index)", withExtension: "mp4")
        } else {
            guard let server = library.servers.first(where: { moment.reference.matches($0) }) else { throw MediaError.message("原来源已移除或账号已变化，请重新连接原账号。") }
            if server.kind == .smb || server.kind == .webDAV {
                guard let relative = video.localRelativePath else { throw MediaError.message("无法恢复原文件位置。") }
                let scope = DiscoveryScope(kind: .video, sourceID: server.id, accountID: moment.reference.accountID, key: relative, name: video.title)
                video.url = try DiscoveryResolver.directory(scope, server: server)
            }
        }
        return video
    }
    static func verify(_ expected: MomentReference, video: Video, library: LibraryStore, resource: PlaybackResource) async throws {
        let actual = try await reference(video: video, library: library, resource: resource)
        guard actual == expected else { throw MediaError.message("原文件版本已变化，已停止打开此时刻。请从片库确认视频后重新收藏。") }
    }
}

actor ContentMapCache {
    static let shared = ContentMapCache()
    static let budget = 64 * 1024 * 1024
    private let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ContentMap-v1")
    private var generation = 0
    func token() -> Int { generation }
    func read(_ key: String) -> Data? {
        let url = root.appendingPathComponent(key)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), (values.fileSize ?? Int.max) <= 8 * 1024 * 1024 else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }
    func write(_ data: Data, key: String, token: Int) throws {
        guard token == generation, data.count <= 8 * 1024 * 1024 else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries where total > Self.budget { try? FileManager.default.removeItem(at: entry.0); total -= entry.1 }
    }
    func clear() throws { generation += 1; if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
}

private struct CachedMapFrame: Codable { var data: Data; var time: Double }
struct ContentMapFrame { var image: UIImage; var time: Double }

@MainActor @Observable final class VideoNavigationSession {
    private(set) var chapters: [NavigationChapter] = []
    private(set) var status = "正在读取视频导航…"
    private(set) var ready = false
    private(set) var hasMap = false
    private(set) var reference: MomentReference?
    private var resource: PlaybackResource?
    private var server: MediaServer?
    private var remoteID: String?
    private var trickplay: TrickplayInfo?
    private var active = 0
    private var lifetime = UUID()
    private let sheets: NSCache<NSString, UIImage> = { let cache = NSCache<NSString, UIImage>(); cache.totalCostLimit = 64 * 1024 * 1024; cache.countLimit = 1; return cache }()
    func prepare(video: Video, library: LibraryStore, resource: PlaybackResource, duration: Double) async {
        let token = UUID(); lifetime = token
        self.resource = resource
        do {
            var metadata: VideoNavigationMetadata?
            if resource.url.isFileURL {
                hasMap = true; status = "点击画面播放，或细看某个时间段。"
                let asset = AVURLAsset(url: resource.url)
                reference = try await MomentResolver.reference(video: video, library: library, resource: resource)
                let groups = (try? await withTaskCancellationHandler {
                    try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
                } onCancel: { asset.cancelLoading() }) ?? []
                var values: [NavigationChapter] = []
                for (index, group) in groups.enumerated() {
                    let title = group.items.first { $0.commonKey == .commonKeyTitle }
                    let name = try? await title?.load(.stringValue)
                    values.append(NavigationChapter(id: "local-\(index)", name: name ?? "章节 \(index + 1)", time: group.timeRange.start.seconds))
                }
                chapters = NavigationChapter.normalized(values, duration: duration)
            } else if let server = library.servers.first(where: { $0.id == video.sourceID }), server.kind.isCatalogSource {
                self.server = server; remoteID = video.remoteID
                metadata = try await MediaClient.shared.navigationMetadata(video: video, server: server)
                if let source = resource.mediaSourceID {
                    trickplay = server.kind == .jellyfin ? metadata?.trickplay(sourceID: source) : nil
                    chapters = metadata?.chapters(sourceID: source, duration: duration) ?? []
                }
                hasMap = trickplay != nil
                status = hasMap ? "使用服务器缩略图，点击画面可跳到对应时间。" : "服务器未提供当前版本的时间缩略图；可使用已有章节或收藏时刻。"
            } else { status = "此来源暂不支持内容地图，可尝试收藏当前时刻。" }
            try Task.checkCancellation(); guard lifetime == token else { return }
            if resource.url.isFileURL || metadata != nil { reference = try await MomentResolver.reference(video: video, library: library, resource: resource, metadata: metadata) }
        } catch is CancellationError { return }
        catch { guard lifetime == token else { return }; status = error.localizedDescription }
        guard lifetime == token, !Task.isCancelled else { return }; ready = true
    }
    func frame(at time: Double) async throws -> ContentMapFrame {
        let token = lifetime
        guard let resource, let reference, hasMap else { throw MediaError.message("此视频暂无可用的画面预览。") }
        while active >= 2 { try await Task.sleep(for: .milliseconds(40)) }
        try Task.checkCancellation(); guard token == lifetime else { throw CancellationError() }
        active += 1; defer { active -= 1; withExtendedLifetime(resource) {} }
        let generation = await ContentMapCache.shared.token()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identity = try encoder.encode(reference).base64EncodedString()
        let sample = trickplay?.tile(at: time)
        let actualTime = sample?.time ?? time
        let key = MomentResolver.digest(identity + ":frame:\(actualTime)")
        if let bytes = await ContentMapCache.shared.read(key), let saved = try? JSONDecoder().decode(CachedMapFrame.self, from: bytes), let image = UIImage(data: saved.data) { return ContentMapFrame(image: image, time: saved.time) }
        let image: UIImage
        var generatedTime = actualTime
        if resource.url.isFileURL {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: resource.url))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 480, height: 320)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
            let result = try await withTaskCancellationHandler { try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) } onCancel: { generator.cancelAllCGImageGeneration() }
            image = UIImage(cgImage: result.image); generatedTime = result.actualTime.seconds
        } else if let info = trickplay, let sample, let server, let remoteID {
            let sheetKey = "\(reference.revision):\(sample.sheet)" as NSString
            let sheet: UIImage
            if let cached = sheets.object(forKey: sheetKey) { sheet = cached }
            else {
                let endpoint = ServerURL.endpoint(server.address, "Videos/\(remoteID)/Trickplay/\(info.Width)/\(sample.sheet).jpg", query: ["MediaSourceId": reference.mediaSourceID ?? ""])
                let bytes = try await MediaClient.shared.navigationData(endpoint, server: server, limit: 8 * 1024 * 1024)
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width == info.Width * info.TileWidth, height == info.Height * info.TileHeight,
                      let decoded = UIImage(data: bytes) else { throw MediaError.message("服务器缩略图尺寸与索引不符。") }
                sheet = decoded; sheets.setObject(sheet, forKey: sheetKey, cost: width * height * 4)
            }
            guard let crop = sheet.cgImage?.cropping(to: CGRect(x: sample.x, y: sample.y, width: info.Width, height: info.Height)) else { throw MediaError.message("服务器缩略图索引无效。") }
            // Detach the small crop from the sprite's backing store so visible
            // thumbnails cannot each retain an entire decoded sprite sheet.
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            image = UIGraphicsImageRenderer(size: CGSize(width: info.Width, height: info.Height), format: format).image { _ in
                UIImage(cgImage: crop).draw(in: CGRect(x: 0, y: 0, width: info.Width, height: info.Height))
            }
        } else { throw MediaError.message("此视频暂无可用的画面预览。") }
        try Task.checkCancellation(); guard token == lifetime else { throw CancellationError() }
        if let data = image.jpegData(compressionQuality: 0.75), let saved = try? JSONEncoder().encode(CachedMapFrame(data: data, time: generatedTime)) {
            try? await ContentMapCache.shared.write(saved, key: key, token: generation)
        }
        return ContentMapFrame(image: image, time: generatedTime)
    }
    func cancel() { lifetime = UUID(); sheets.removeAllObjects() }
}
