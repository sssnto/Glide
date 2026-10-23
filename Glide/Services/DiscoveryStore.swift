import Foundation
import Observation
import AVFoundation

@MainActor @Observable final class DiscoveryStore {
    struct Snapshot: Codable { var channels: [PrivateChannel] = []; var timeScopes: [DiscoveryScope] = [] }
    static let shared = DiscoveryStore()
    private(set) var channels: [PrivateChannel] = []
    private(set) var timeScopes: [DiscoveryScope] = []
    private(set) var message: String?
    private let store: RecoverableStore<Snapshot>
    init(file: URL? = nil) {
        var defaultFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Discovery/discovery-v1.json")
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--glide-discovery-fixture") {
            defaultFile = defaultFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DiscoveryUIQA/discovery-v1.json")
            if ProcessInfo.processInfo.arguments.contains("--glide-discovery-reset") {
                try? FileManager.default.removeItem(at: defaultFile)
                try? FileManager.default.removeItem(at: defaultFile.appendingPathExtension("backup"))
            }
        }
#endif
        store = RecoverableStore(file: file ?? defaultFile)
        do {
            if let saved = try store.load() {
                channels = saved.value.channels; timeScopes = saved.value.timeScopes
                if saved.recovered { message = "频道已从备份恢复。" }
            }
        } catch { message = "频道数据暂时无法读取，已保留原文件。" }
    }
    private func update(_ edit: (inout Snapshot) throws -> Void) throws {
        var value = try store.load()?.value ?? Snapshot()
        try edit(&value); try store.save(value)
        channels = value.channels; timeScopes = value.timeScopes; message = nil
    }
    func save(_ channel: PrivateChannel) throws {
        let channel = try channel.validated()
        try update { value in
            if let index = value.channels.firstIndex(where: { $0.id == channel.id }) { value.channels[index] = channel }
            else {
                guard value.channels.count < 50 else { throw MediaError.message("最多保存 50 个频道。") }
                value.channels.append(channel)
            }
        }
    }
    func remove(_ id: UUID) throws { try update { $0.channels.removeAll { $0.id == id } } }
    func setTimeScopes(_ scopes: [DiscoveryScope]) throws {
        guard !scopes.isEmpty, scopes.count <= 16 else { throw MediaError.message("请选择 1–16 个内容范围。") }
        let scopes = try scopes.map { try $0.validated() }
        try update { $0.timeScopes = scopes }
    }
    func recordStart(channelID: UUID, videoID: String) {
        do {
            try update { value in
                guard let index = value.channels.firstIndex(where: { $0.id == channelID }) else { return }
                value.channels[index].recordStart(videoID, at: Date())
            }
        } catch { message = "本次频道开播记录尚未保存，请检查存储空间。" }
    }
}

@MainActor enum DiscoveryResolver {
    static func root(_ server: MediaServer) -> DiscoveryScope {
        DiscoveryScope(kind: server.kind.isCatalogSource ? .catalog : .directory, sourceID: server.id,
                       accountID: server.userID ?? server.username, key: "", name: server.name)
    }
    static func current(_ library: LibraryStore) -> DiscoveryScope {
        guard let server = library.selectedServer else { return .demo }
        var scope = root(server)
        if server.kind.isCatalogSource { scope.key = library.jellyPath.last?.id ?? "" }
        else if let target = library.path.last { scope.key = relative(target, server: server) ?? "" }
        scope.name = library.hasParent ? library.currentDirectoryName : server.name
        return scope
    }
    static func server(_ scope: DiscoveryScope, library: LibraryStore) throws -> MediaServer {
        guard let server = library.servers.first(where: { scope.matches($0) }) else {
            throw MediaError.message("“\(scope.name)”的来源已移除或账号已变化，请重新选择。")
        }
        return server
    }
    static func relative(_ url: URL, server: MediaServer) -> String? {
        guard DirectoryScope.contains(root: server.address, child: url) else { return nil }
        if server.kind == .local { return try? LocalMediaIdentity.relativePath(root: server.address, file: url) }
        let root = server.address.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path == root ? "" : String(path.dropFirst(root.isEmpty ? 0 : root.count + 1))
    }
    static func directory(_ scope: DiscoveryScope, server: MediaServer) throws -> URL {
        _ = try scope.validated()
        let url = scope.key.isEmpty ? server.address : server.address.appendingPathComponent(scope.key, isDirectory: scope.kind == .directory)
        guard DirectoryScope.contains(root: server.address, child: url) else { throw MediaError.message("目录已超出来源范围。") }
        return url
    }
    static func children(_ scope: DiscoveryScope, library: LibraryStore) async throws -> [DiscoveryScope] {
        if scope.kind == .demo { return [] }
        let server = try server(scope, library: library)
        if server.kind.isCatalogSource {
            var result: [DiscoveryScope] = [], cursor = 0
            while true {
                try Task.checkCancellation()
                let page = try await MediaClient.shared.browse(server: server, parentID: scope.key.isEmpty ? nil : scope.key, start: cursor)
                result += page.folders.map { DiscoveryScope(kind: .catalog, sourceID: server.id, accountID: scope.accountID, key: $0.id, name: $0.name) }
                result += page.videos.compactMap { video in video.remoteID.map { DiscoveryScope(kind: .video, sourceID: server.id, accountID: scope.accountID, key: $0, name: video.title) } }
                if page.nextIndex >= page.total { return result }
                guard page.nextIndex > cursor, result.count < 2000 else { throw MediaError.message("此层级过大或分页没有进展，请选择更小的目录。") }
                cursor = page.nextIndex
            }
        }
        let entries = try await SourceProviders.directories(for: server.kind).entries(server: server, directory: directory(scope, server: server))
        try Task.checkCancellation()
        return entries.compactMap { entry in
            guard entry.isDirectory || DirectoryScope.isVideo(entry.url), let key = relative(entry.url, server: server) else { return nil }
            return DiscoveryScope(kind: entry.isDirectory ? .directory : .video, sourceID: server.id, accountID: scope.accountID, key: key, name: entry.name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func batches(_ scopes: [DiscoveryScope], library: LibraryStore, readDurations: Bool = false, progress: (Int) -> Void) async throws -> [DiscoveryBatch] {
        var result: [DiscoveryBatch] = [], count = 0
        for scope in scopes {
            try Task.checkCancellation()
            let videos = try await videos(scope, library: library, readDurations: readDurations) { progress(count + $0) }
            try Task.checkCancellation()
            count += videos.count; result.append(DiscoveryBatch(scope: scope, videos: videos)); progress(count)
            guard count <= 5000 else { throw MediaError.message("已达到 5000 条内容上限，请缩小范围后重试。") }
        }
        return result
    }
    private static func videos(_ scope: DiscoveryScope, library: LibraryStore, readDurations: Bool, progress: (Int) -> Void) async throws -> [Video] {
        _ = try scope.validated()
        if scope.kind == .demo {
            return (0..<3).compactMap { index in
                Bundle.main.url(forResource: "demo\(index)", withExtension: "mp4").map {
                    Video(id: "demo-\(index)", title: ["静谧山野", "落日海岸", "蓝色时分"][index], subtitle: "原创演示", url: $0, duration: 12, demoIndex: index)
                }
            }
        }
        let server = try server(scope, library: library)
        var values: [Video]
        if server.kind.isCatalogSource {
            if scope.kind == .video {
                values = [try await MediaClient.shared.catalogDetail(server: server, id: scope.key, refresh: true).video(server: server)]
            } else {
                let roots = scope.key.isEmpty ? try await MediaClient.shared.browse(server: server, parentID: nil).folders.map(\.id) : [scope.key]
                guard roots.count <= 30 else { throw MediaError.message("请选定媒体库后再准备内容。") }
                values = []
                for root in roots {
                    let previous = values.count
                    let videos = try await ScopedQueueCollector.pages(fetch: { cursor in
                        let page = try await MediaClient.shared.playbackVideos(server: server, parentID: root, start: cursor)
                        guard previous + page.nextIndex <= 5000, previous + page.total <= 5000 else { throw MediaError.message("此范围超过 5000 条，请选择更小的媒体库或剧集。") }
                        return page
                    }, progress: { progress(previous + $0) })
                    values += videos
                }
            }
        } else {
            let url = try directory(scope, server: server)
            if scope.kind == .video { values = [try fileVideo(.init(url: url, name: scope.name, isDirectory: false), server: server)] }
            else {
                let provider = try SourceProviders.directories(for: server.kind)
                var folders = 0, files = 0
                let entries = try await ScopedQueueCollector.webDAV(root: url, fetch: { folder in
                    folders += 1
                    guard folders <= 500 else { throw MediaError.message("目录数量超过 500 个，请缩小范围。") }
                    let values = try await provider.entries(server: server, directory: folder)
                    files += values.filter { !$0.isDirectory && DirectoryScope.isVideo($0.url) }.count
                    guard files <= 5000 else { throw MediaError.message("视频数量超过 5000 条，请缩小范围。") }
                    return values
                }, progress: { progress($0) }, partial: { _ in })
                guard entries.count <= 5000 else { throw MediaError.message("视频数量超过 5000 条，请缩小范围。") }
                values = try entries.map { try fileVideo($0, server: server) }
            }
        }
        for index in values.indices {
            try Task.checkCancellation()
            let cached = library.personalVideos[values[index].id]?.video
            if values[index].duration <= 0, let duration = cached?.duration { values[index].duration = duration }
            if server.kind.isCatalogSource {
                values[index].resume = library.progressSnapshots[values[index].id]?.resolved(serverPosition: values[index].resume, serverLastPlayed: nil) ?? values[index].resume
            } else { values[index].resume = library.resumePosition(values[index]) }
            // File protocols do not expose reliable running times. Read only
            // explicitly authorized local files; never download a NAS video to scan it.
            if readDurations, server.kind == .local, values[index].duration <= 0, index < 200 {
                if let resource = try? LocalMediaStore.playback(values[index], server: server) {
                    let asset = AVURLAsset(url: resource.url)
                    let duration = try? await withTaskCancellationHandler { try await asset.load(.duration) } onCancel: { asset.cancelLoading() }
                    if let duration, duration.seconds.isFinite { values[index].duration = max(0, duration.seconds) }
                    withExtendedLifetime(resource.localAccess) {}
                }
            }
        }
        _ = try self.server(scope, library: library)
        return values
    }
    private static func fileVideo(_ entry: DAVEntry, server: MediaServer) throws -> Video {
        let relative = server.kind == .local ? try LocalMediaIdentity.relativePath(root: server.address, file: entry.url) : nil
        return Video(id: relative.map { LocalMediaIdentity.id(sourceID: server.id, relativePath: $0) } ?? server.id.uuidString + entry.id,
                     title: entry.name, subtitle: server.name, sourceID: server.id, url: entry.url, artwork: entry.artwork,
                     addedAt: entry.displayDate, localRelativePath: relative)
    }
}
