import Foundation
import Observation

enum UnifiedSource {
    static func binding(_ server: MediaServer) -> String {
        SubtitleSource.digest(Data([server.id.uuidString, server.kind.rawValue, server.address.absoluteString, server.username, server.userID ?? ""].joined(separator: "\n").utf8))
    }
    static func records(item: CatalogItem, server: MediaServer) -> [UnifiedRecord] {
        let sources = item.Type == "Series" ? [] : item.MediaSources ?? []
        let binding = binding(server), video = item.video(server: server)
        func row(_ source: CatalogItem.Source?, first: Bool) -> UnifiedRecord {
            UnifiedRecord(id: binding + ":" + video.id + ":" + (source?.Id ?? "default"), binding: binding,
                          sourceName: server.name, video: video, providers: item.ProviderIds ?? [:], year: item.ProductionYear,
                          overview: item.Overview, mediaSource: source, isDefault: first).sanitized()
        }
        return sources.isEmpty ? [row(nil, first: true)] : sources.enumerated().map { row($0.element, first: $0.offset == 0) }
    }
    @MainActor static func scope(_ record: UnifiedRecord, library: LibraryStore) throws -> DiscoveryScope {
        guard let server = library.servers.first(where: { $0.id == record.video.sourceID && binding($0) == record.binding }) else { throw MediaError.message("原来源已移除或账号已变化，请重新选择。") }
        if server.kind.isCatalogSource, let remote = record.video.remoteID {
            return DiscoveryScope(kind: record.kind == "Series" ? .catalog : .video, sourceID: server.id, accountID: server.userID ?? server.username, key: remote, name: record.video.title)
        }
        if server.kind == .local, let relative = record.video.localRelativePath {
            return DiscoveryScope(kind: .video, sourceID: server.id, accountID: server.userID ?? server.username, key: relative, name: record.video.title)
        }
        throw MediaError.message("此副本已在随身片库中；添加到频道需要原来源可用。")
    }
}

/// Display metadata only. Disk reads, grouping and search stay off the main actor.
actor UnifiedLibraryIndex {
    static let shared = UnifiedLibraryIndex()
    private let store: RecoverableStore<UnifiedLibrarySnapshot>
    private var snapshot: UnifiedLibrarySnapshot?
    init(file: URL? = nil) {
        var folder = "UnifiedLibrary"
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--glide-unified-fixture") { folder = "UnifiedLibraryQA" }
#endif
        store = RecoverableStore(file: file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(folder + "/index-v1.json"))
    }
    private func load() throws -> UnifiedLibrarySnapshot {
        if let snapshot { return snapshot }
        let value = try store.load()?.value ?? UnifiedLibrarySnapshot()
        snapshot = value; return value
    }
    func records(active: Set<String>) throws -> [UnifiedRecord] {
        var value = try load()
        let retained = value.records.filter { active.contains($0.binding) }
        if retained.count != value.records.count {
            value.records = retained
            let ids = Set(retained.map(\.id)); value.preferred = value.preferred.filter { ids.contains($0.value) }
            try store.save(value); snapshot = value
        }
        return retained
    }
    func merge(_ rows: [UnifiedRecord], replacing binding: String? = nil, replacingFile: String? = nil) throws {
        var value = try load()
        var keyed = Dictionary(value.records.filter { $0.binding != binding && $0.fileIdentity != replacingFile }.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for row in rows { keyed[row.id] = row.sanitized() }
        value.records = Array(keyed.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(10_000))
        try store.save(value); snapshot = value
    }
    func prefer(work: String, record: String) throws {
        var value = try load(); value.preferred[work] = record
        if value.preferred.count > 2000 { value.preferred = [work: record] }
        try store.save(value); snapshot = value
    }
    func preferred(_ work: String) throws -> String? { try load().preferred[work] }
    func search(_ records: [UnifiedRecord], query: String, filter: UnifiedFilter) -> [UnifiedWork] {
        UnifiedLibraryGrouping.works(records, query: query, filter: filter)
    }
}

extension MediaClient {
    func unifiedSearch(server: MediaServer, query term: String, start: Int) async throws -> PersonMediaPage {
        guard server.kind.isCatalogSource, let user = server.userID, let token = Credentials.read(server.id) else { throw MediaError.message("请重新登录原来源。") }
        let query = ["UserId": user, "SearchTerm": term, "IncludeItemTypes": "Movie,Series,Episode,Video,MusicVideo", "Recursive": "true",
                     "Fields": "Overview,ProviderIds,MediaSources", "EnableUserData": "true", "StartIndex": String(start), "Limit": "60", "SortBy": "SortName", "SortOrder": "Ascending"]
        var request = URLRequest(url: ServerURL.endpoint(server.address, "Items", query: query))
        request.setValue(authorization(token, server: server), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        // Direct requests preserve task cancellation; no shared cache flight can outlive the query.
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw MediaError.message("来源暂时无法搜索，请检查连接与登录状态。") }
        guard data.count <= 15 * 1024 * 1024 else { throw MediaError.message("搜索响应过大，请缩小关键词范围。") }
        return try JSONDecoder().decode(PersonMediaPage.self, from: data)
    }
}

@MainActor @Observable final class UnifiedLibrarySession {
    private(set) var works: [UnifiedWork] = []
    private(set) var status: [String: String] = [:]
    private(set) var searching = Set<String>()
    private(set) var more = Set<String>()
    private(set) var message: String?
    private(set) var records: [UnifiedRecord] = []
    private var generation = UUID()
    private var cursors: [String: Int] = [:]
    private var localLoaded = Set<String>()
    private var localRows: [String: [UnifiedRecord]] = [:]
    private var receivedIDs: [String: Set<String>] = [:]
    private var publication = UUID()
    private var searchTerm = ""
    private var filter = UnifiedFilter.all
    private var selected = Set<String>()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    func stop() { tasks.forEach { $0.cancel() }; tasks = []; generation = UUID(); searching = [] }
    func invalidateLocal() { localLoaded = []; localRows = [:] }
    func search(_ term: String, filter: UnifiedFilter, selected: Set<String>, library: LibraryStore) async {
        stop(); let token = generation
        self.filter = filter; self.selected = selected; searchTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        cursors = [:]; receivedIDs = [:]; more = []; status = [:]; works = []; records = []; message = nil
        let active = Set(library.servers.filter { $0.kind.isCatalogSource || $0.kind == .local }.map(UnifiedSource.binding))
        do { records = try await UnifiedLibraryIndex.shared.records(active: active) }
        catch { message = "搜索缓存无法读取，原文件已保留：" + error.localizedDescription }
        guard generation == token, !Task.isCancelled else { return }
        records += offlineRecords(library)
        // The original demo remains useful without any account or NAS.
        if library.servers.isEmpty {
            records += (0..<3).compactMap { index in
                guard let url = Bundle.main.url(forResource: "demo\(index)", withExtension: "mp4") else { return nil }
                return UnifiedRecord(id: "demo-\(index)", binding: "demo", sourceName: "原创演示", video: Video(id: "demo-\(index)", title: ["静谧山野", "落日海岸", "蓝色时分"][index], subtitle: "原创演示", url: url, duration: 12, demoIndex: index))
            }
        }
        await publish(token)
        for server in library.servers where selected.contains(UnifiedSource.binding(server)) {
            if filter == .downloaded { continue }
            let binding = UnifiedSource.binding(server)
            if server.kind == .local {
                if let values = localRows[binding] { records.removeAll { $0.binding == binding }; records += values; await publish(token) }
                if !localLoaded.contains(binding) {
                    searching.insert(binding)
                    tasks.append(Task { await scanLocal(server, library: library, token: token) })
                }
            } else if server.kind.isCatalogSource, !searchTerm.isEmpty {
                searching.insert(binding)
                tasks.append(Task { await fetch(server, start: 0, library: library, token: token) })
            }
        }
    }
    func loadMore(library: LibraryStore) {
        let token = generation
        for server in library.servers {
            let binding = UnifiedSource.binding(server)
            if selected.contains(binding), more.contains(binding), !searching.contains(binding) {
                searching.insert(binding)
                tasks.append(Task { await fetch(server, start: cursors[binding] ?? 0, library: library, token: token) })
            }
        }
    }
    private func publish(_ token: UUID) async {
        let revision = UUID(); publication = revision
        let rows = records.filter { selected.contains($0.offline ? "offline" : $0.binding) }
        let result = await UnifiedLibraryIndex.shared.search(rows, query: searchTerm, filter: filter)
        guard token == generation, revision == publication, !Task.isCancelled else { return }
        works = result
    }
    private func fetch(_ server: MediaServer, start: Int, library: LibraryStore, token: UUID) async {
        let binding = UnifiedSource.binding(server), term = searchTerm
        defer { if token == generation { searching.remove(binding) } }
        do {
            let page = try await MediaClient.shared.unifiedSearch(server: server, query: term, start: start)
            try Task.checkCancellation()
            guard token == generation, library.servers.contains(where: { UnifiedSource.binding($0) == binding }) else { return }
            let rows = page.Items.flatMap { UnifiedSource.records(item: $0, server: server) }
            if start < page.TotalRecordCount, page.Items.isEmpty { throw MediaError.message("搜索分页没有进展，请重试。") }
            let ids = Set(rows.map(\.id))
            if start > 0, !rows.isEmpty, ids.isSubset(of: receivedIDs[binding] ?? []) { throw MediaError.message("搜索分页重复，请刷新重试。") }
            receivedIDs[binding, default: []].formUnion(ids)
            records.removeAll { ids.contains($0.id) }; records += rows
            cursors[binding] = start + page.Items.count
            if start + page.Items.count < page.TotalRecordCount && start < 6000 { more.insert(binding) } else { more.remove(binding) }
            status[binding] = "已读取 \(start + page.Items.count) / \(page.TotalRecordCount)"
            do { try await UnifiedLibraryIndex.shared.merge(rows) } catch { message = "本次结果尚未缓存：" + error.localizedDescription }
            await publish(token)
        } catch {
            if token == generation, !Task.isCancelled { status[binding] = "暂时无法连接；保留已缓存资料"; await publish(token) }
        }
    }
    private func scanLocal(_ server: MediaServer, library: LibraryStore, token: UUID) async {
        let binding = UnifiedSource.binding(server)
        defer { if token == generation { searching.remove(binding) } }
        do {
            let access = try LocalMediaStore.access(server)
            let operation = Task.detached { () throws -> [UnifiedRecord] in
                defer { withExtendedLifetime(access) {} }
                var folders = [access.root], rows = [UnifiedRecord](), visited = 0
                while let folder = folders.popLast() {
                    try Task.checkCancellation(); visited += 1
                    guard visited <= 500 else { throw MediaError.message("本地目录超过 500 个，请使用更小的授权范围。") }
                    for entry in try LocalDirectoryIndex.entries(root: access.root, directory: folder) {
                        if entry.isDirectory { folders.append(entry.url) }
                        else if DirectoryScope.isVideo(entry.url) {
                            guard rows.count < 5000 else { throw MediaError.message("本地视频超过 5000 个，请使用更小的授权范围。") }
                            let relative = try LocalMediaIdentity.relativePath(root: access.root, file: entry.url)
                            let video = Video(id: LocalMediaIdentity.id(sourceID: server.id, relativePath: relative), title: entry.name, subtitle: server.name, sourceID: server.id, localRelativePath: relative)
                            rows.append(UnifiedRecord(id: binding + ":" + video.id, binding: binding, sourceName: server.name, video: video).sanitized())
                        }
                    }
                }
                return rows
            }
            let rows = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            guard token == generation, library.servers.contains(where: { UnifiedSource.binding($0) == binding }) else { return }
            localLoaded.insert(binding); localRows[binding] = rows
            records.removeAll { $0.binding == binding }; records += rows
            try await UnifiedLibraryIndex.shared.merge(rows, replacing: binding)
            status[binding] = "已索引 \(rows.count) 个本地视频"; await publish(token)
        } catch { if token == generation, !Task.isCancelled { status[binding] = error.localizedDescription } }
    }
    private func offlineRecords(_ library: LibraryStore) -> [UnifiedRecord] {
        DownloadStore.shared.entries.compactMap { entry in
            guard DownloadStore.shared.localURL(videoID: entry.id) != nil else { return nil }
            let server = library.servers.first { $0.id == entry.video.sourceID }
            let same = server.flatMap { try? SubtitleSource.key(video: entry.video, server: $0) } == entry.accountBinding
            let binding = same ? server.map(UnifiedSource.binding) ?? "offline:" + entry.filename : "offline:" + entry.filename
            return UnifiedRecord(id: "offline:" + entry.id, binding: binding, sourceName: "已下载", video: entry.video,
                                 providers: entry.providerIDs ?? [:], year: entry.productionYear, overview: entry.overview, mediaSource: entry.source, offline: true).sanitized()
        }
    }
}

@MainActor enum UnifiedPlaybackResolver {
    struct Selection: Identifiable { var id = UUID(); var video: Video; var tracks = TrackSelection() }
    static func resolve(_ record: UnifiedRecord, library: LibraryStore) async throws -> Selection {
        if record.offline { return Selection(video: try DownloadStore.shared.offlineVideo(record.video.id)) }
        if record.video.demoIndex != nil {
            var video = record.video; video.url = Bundle.main.url(forResource: "demo\(video.demoIndex!)", withExtension: "mp4")
            return Selection(video: video)
        }
        guard let server = library.servers.first(where: { UnifiedSource.binding($0) == record.binding }) else { throw MediaError.message("来源账号或地址已变化，请重新搜索。") }
        if server.kind == .local { _ = try LocalMediaStore.playback(record.video, server: server); return Selection(video: record.video) }
        guard let remote = record.video.remoteID else { throw MediaError.message("视频标识缺失，请重新搜索。") }
        let item = try await MediaClient.shared.catalogDetail(server: server, id: remote, refresh: true)
        try Task.checkCancellation()
        guard item.Id == remote, item.Type == record.video.mediaType else { throw MediaError.message("作品资料已变化，请重新搜索。") }
        if let expected = record.providerKey, let actual = UnifiedLibraryGrouping.providerKey(item.ProviderIds ?? [:], type: item.Type ?? "Video"), expected != actual { throw MediaError.message("作品标识已变化，请重新搜索。") }
        if let sourceID = record.mediaSource?.Id, item.MediaSources?.contains(where: { $0.Id == sourceID }) != true { throw MediaError.message("所选版本已变化，请重新搜索并选择。") }
        guard library.servers.contains(where: { UnifiedSource.binding($0) == record.binding }) else { throw MediaError.message("播放准备期间来源账号已变化。") }
        return Selection(video: item.video(server: server), tracks: TrackSelection(mediaSourceID: record.mediaSource?.Id))
    }
}
