import Foundation
import Observation

@MainActor @Observable
final class LibraryStore {
    var servers: [MediaServer] = []
    var selectedID: UUID?
    var videos: [Video] = []
    var directories: [DAVEntry] = []
    var path: [URL] = []
    var jellyPath: [MediaFolder] = []
    var folders: [MediaFolder] = []
    var folderNextIndex = 0
    var folderTotal = 0
    var hasMoreFolders: Bool { folderNextIndex < folderTotal }
    var nextIndex = 0
    var hasMore: Bool { selectedServer?.kind == .jellyfin && !jellyPath.isEmpty && nextIndex < total }
    var hasParent: Bool { !path.isEmpty || !jellyPath.isEmpty }
    var currentDirectoryName: String { jellyPath.last?.name ?? path.last?.lastPathComponent ?? (selectedServer?.kind == .jellyfin ? "媒体库" : selectedServer?.name ?? "离线演示") }
    var locationKey: String { (selectedID?.uuidString ?? "demo") + ":" + (jellyPath.last?.id ?? path.last?.absoluteString ?? "root") }
    var scopeKey: String { locationKey + ":" + browseOptions.key }
    private(set) var browseOptions = BrowseOptions()
    private var directoryPreferences: [String: BrowseOptions] = [:]
    private(set) var folderSort: FolderSort = .nameAscending
    private var folderSortPreferences: [String: FolderSort] = [:]
    var bookmarks: [DirectoryBookmark] = []
    var canPinDirectory: Bool { selectedServer != nil && (selectedServer?.kind == .webDAV || !jellyPath.isEmpty) }
    var isDirectoryPinned: Bool { bookmarks.contains { $0.id == locationKey } }
    var loading = false
    var error: String?
    var total = 0
    var favorites: Set<String> = []
    var positions: [String: Double] = [:]
    var progressSnapshots: [String: ProgressSnapshot] = [:]
    var personalVideos: [String: PersonalVideo] = [:]
    var contentRevision: UUID { loadID }
    var selectedServer: MediaServer? { servers.first { $0.id == selectedID } }
    private var loadID = UUID()
    private var loadingMore = false
    init() {
        if let data = UserDefaults.standard.data(forKey: "directoryPreferences.v1") { directoryPreferences = (try? JSONDecoder().decode([String: BrowseOptions].self, from: data)) ?? [:] }
        if let data = UserDefaults.standard.data(forKey: "folderSortPreferences.v1") { folderSortPreferences = (try? JSONDecoder().decode([String: FolderSort].self, from: data)) ?? [:] }
        if let data = UserDefaults.standard.data(forKey: "directoryBookmarks.v1") { bookmarks = (try? JSONDecoder().decode([DirectoryBookmark].self, from: data)) ?? [] }

        if let data = UserDefaults.standard.data(forKey: "servers") { servers = (try? JSONDecoder().decode([MediaServer].self, from: data)) ?? [] }
        if let data = UserDefaults.standard.data(forKey: "personalVideos.v1") { personalVideos = (try? JSONDecoder().decode([String: PersonalVideo].self, from: data)) ?? [:] }
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
        positions = UserDefaults.standard.dictionary(forKey: "positions") as? [String: Double] ?? [:]
        if let data = UserDefaults.standard.data(forKey: "progressSnapshots.v1") { progressSnapshots = (try? JSONDecoder().decode([String: ProgressSnapshot].self, from: data)) ?? [:] }
        selectedID = UserDefaults.standard.string(forKey: "selectedServer").flatMap(UUID.init(uuidString:))
        if !servers.contains(where: { $0.id == selectedID }) { selectedID = nil }
        if selectedID == nil { showDemo() }
        else { restoreLocation(); restoreBrowseOptions() }
    }
    func showDemo() {
        browseOptions = BrowseOptions()
        folderSort = .nameAscending
        folderNextIndex = 0; folderTotal = 0
        selectedID = nil; path = []; jellyPath = []; folders = []; nextIndex = 0; directories = []; error = nil; loading = false; loadID = UUID()
        videos = [("静谧山野", "越过山脊，慢下来。"), ("落日海岸", "把日落留在这一刻。"), ("蓝色时分", "在夜色里，继续漫游。")].enumerated().compactMap { index, value in
            guard let url = Bundle.main.url(forResource: "demo\(index)", withExtension: "mp4") else { return nil }
            return Video(id: "demo-\(index)", title: value.0, subtitle: value.1, url: url, duration: 12, demoIndex: index)
        }
        total = videos.count
        UserDefaults.standard.removeObject(forKey: "selectedServer")
    }
    func persist() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: "servers") }
    }
    func add(name: String, kind: SourceKind, address: String, username: String, password: String) async throws {
        let url = try ServerURL.parse(address)
        var server = MediaServer(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (url.host ?? kind.title) : name, kind: kind, address: url, username: username)
        if kind == .jellyfin {
            let (token, userID) = try await MediaClient.shared.signIn(server: server, password: password)
            server.userID = userID
            try Task.checkCancellation()
            try Credentials.save(token, for: server.id)
        } else {
            _ = try await MediaClient.shared.webDAV(server: server, password: password)
            try Task.checkCancellation()
            try Credentials.save(password, for: server.id)
        }
        servers.append(server); persist()
        await select(server.id)
    }
    func remove(_ server: MediaServer) {
        DownloadStore.shared.removeServer(server.id)
        Task { await MediaCache.shared.clear(server: server); await ArtworkCache.shared.clear() }
        bookmarks.removeAll { $0.sourceID == server.id }
        directoryPreferences = directoryPreferences.filter { !$0.key.hasPrefix(server.id.uuidString + ":") }
        folderSortPreferences = folderSortPreferences.filter { !$0.key.hasPrefix(server.id.uuidString + ":") }
        persistDirectorySettings()
        Credentials.delete(server.id)
        UserDefaults.standard.removeObject(forKey: "jellyPath." + server.id.uuidString)
        UserDefaults.standard.removeObject(forKey: "davPath." + server.id.uuidString)
        let removedIDs = Set(personalVideos.values.filter { $0.video.sourceID == server.id }.map(\.id))
        personalVideos = personalVideos.filter { !removedIDs.contains($0.key) }
        favorites.subtract(removedIDs)
        positions = positions.filter { !removedIDs.contains($0.key) }
        progressSnapshots = progressSnapshots.filter { !removedIDs.contains($0.key) }; persistProgress()
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
        UserDefaults.standard.set(positions, forKey: "positions")
        persistPersonalVideos()
        servers.removeAll { $0.id == server.id }; persist()
        if selectedID == server.id { showDemo() }
    }
    func select(_ id: UUID?) async {
        guard let id else { showDemo(); return }
        selectedID = id; path = []; jellyPath = []; clearContents()
        UserDefaults.standard.set(id.uuidString, forKey: "selectedServer")
        restoreLocation(); restoreBrowseOptions()
        await reload()
    }
    func reload(directory: URL? = nil) async {
        guard let server = selectedServer else { showDemo(); return }
        let generation = UUID(); loadID = generation; loading = true; error = nil; loadingMore = false
        let parentID = jellyPath.last?.id
        let options = browseOptions
        let sort = folderSort
        defer { if generation == loadID { loading = false } }
        do {
            if server.kind == .jellyfin {
                // Refresh legacy saved locations that predate collection-type persistence.
                if let first = jellyPath.first, first.collectionType == nil {
                    let roots = try await MediaClient.shared.browse(server: server, parentID: nil, sort: sort)
                    guard generation == loadID else { return }
                    if let updated = roots.folders.first(where: { $0.id == first.id }) {
                        jellyPath[0] = updated; saveLocation()
                    }
                }
                async let folderPage = MediaClient.shared.browse(server: server, parentID: parentID, sort: sort)
                let preview: VideoPage?
                if let parentID, LibraryExperience(collectionType: jellyPath.first?.collectionType) == .home {
                    preview = try await MediaClient.shared.playbackVideos(server: server, parentID: parentID, start: 0, options: options)
                } else { preview = nil }
                let page = try await folderPage
                guard generation == loadID else { return }
                folders = page.folders; folderTotal = page.total; folderNextIndex = page.nextIndex
                videos = preview?.videos ?? []; total = preview?.total ?? 0; nextIndex = preview?.nextIndex ?? 0; directories = []
            } else {
                let entries = try await MediaClient.shared.webDAV(server: server, directory: directory ?? path.last)
                guard generation == loadID else { return }
                directories = entries.filter(\.isDirectory)
                let root = directory ?? path.last ?? server.address
                let descendants = try await ScopedQueueCollector.webDAV(root: root, recursive: options.includesDescendants, fetch: { url in
                    guard generation == self.loadID else { throw CancellationError() }
                    if url == root { return entries }
                    return try await MediaClient.shared.webDAV(server: server, directory: url)
                }, progress: { _ in })
                guard generation == loadID else { return }
                videos = descendants.map {
                    Video(id: server.id.uuidString + $0.id, title: $0.name, subtitle: server.name, sourceID: server.id, url: $0.url, addedAt: $0.displayDate)
                }
                videos = options.sort.sorted(videos)
                total = videos.count
            }
            remember(videos)
        } catch { if generation == loadID { self.error = error.localizedDescription } }
    }
    func enter(_ directory: URL) async { path.append(directory); saveLocation(); restoreBrowseOptions(); clearContents(); await reload() }
    func enter(_ folder: MediaFolder) async {
        jellyPath.append(folder); saveLocation(); restoreBrowseOptions(); clearContents(); await reload()
    }
    func back() async {
        if !jellyPath.isEmpty { jellyPath.removeLast() }
        else if !path.isEmpty { path.removeLast() }
        else { return }
        saveLocation(); restoreBrowseOptions(); clearContents(); await reload()
    }
    func jump(to depth: Int) async {
        jellyPath = Array(jellyPath.prefix(depth)); saveLocation(); restoreBrowseOptions(); clearContents(); await reload()
    }
    private func saveLocation() {
        guard let id = selectedID else { return }
        if let data = try? JSONEncoder().encode(jellyPath) { UserDefaults.standard.set(data, forKey: "jellyPath." + id.uuidString) }
        if let data = try? JSONEncoder().encode(path) { UserDefaults.standard.set(data, forKey: "davPath." + id.uuidString) }
    }
    private func restoreLocation() {
        guard let id = selectedID else { return }
        if let data = UserDefaults.standard.data(forKey: "jellyPath." + id.uuidString) { jellyPath = (try? JSONDecoder().decode([MediaFolder].self, from: data)) ?? [] }
        if let data = UserDefaults.standard.data(forKey: "davPath." + id.uuidString) { path = (try? JSONDecoder().decode([URL].self, from: data)) ?? [] }
    }
    private func clearContents() { videos = []; folders = []; directories = []; total = 0; nextIndex = 0; folderNextIndex = 0; folderTotal = 0; error = nil }

    func more() async {
        guard !loading, !loadingMore, hasMore, let server = selectedServer, server.kind == .jellyfin else { return }
        let generation = loadID
        let options = browseOptions
        loadingMore = true
        defer { if generation == loadID { loadingMore = false } }
        do {
            guard let parentID = jellyPath.last?.id else { return }
            let page = try await MediaClient.shared.playbackVideos(server: server, parentID: parentID, start: nextIndex, options: options)
            guard page.nextIndex > nextIndex else { throw MediaError.message("无法加载更多视频，请刷新后重试。") }
            guard generation == loadID else { return }
            let existing = Set(videos.map(\.id))
            videos += page.videos.filter { !existing.contains($0.id) }
            remember(page.videos)
            total = page.total; nextIndex = page.nextIndex
        } catch { if generation == loadID { self.error = error.localizedDescription } }
    }
    func moreFolders() async {
        guard !loading, !loadingMore, hasMoreFolders, let server = selectedServer else { return }
        let generation = loadID
        loadingMore = true
        defer { if generation == loadID { loadingMore = false } }
        do {
            let page = try await MediaClient.shared.browse(server: server, parentID: jellyPath.last?.id, start: folderNextIndex, sort: folderSort)
            guard generation == loadID else { return }
            guard page.nextIndex > folderNextIndex else { throw MediaError.message("无法加载更多目录，请刷新后重试。") }
            let known = Set(folders.map(\.id))
            folders += page.folders.filter { !known.contains($0.id) }
            folderTotal = page.total; folderNextIndex = page.nextIndex
        } catch { if generation == loadID { self.error = error.localizedDescription } }
    }
    /// Collect the complete playback queue independently of preview pagination.
    func collectPlaybackVideos(search: String = "", progress: (Int) -> Void) async throws -> [Video] {
        guard let server = selectedServer else { return videos }
        let options = browseOptions
        if server.kind == .jellyfin {
            guard let parentID = jellyPath.last?.id else { throw MediaError.message("请先选择一个媒体库或目录。") }
            return try await ScopedQueueCollector.pages(fetch: { start in
                try await MediaClient.shared.playbackVideos(server: server, parentID: parentID, start: start, search: search, options: options)
            }, progress: progress)
        }
        let root = path.last ?? server.address
        let entries = try await ScopedQueueCollector.webDAV(root: root, recursive: options.includesDescendants, fetch: { directory in
            try await MediaClient.shared.webDAV(server: server, directory: directory)
        }, progress: progress)
        return options.sort.sorted(entries.map { Video(id: server.id.uuidString + $0.id, title: $0.name, subtitle: server.name, sourceID: server.id, url: $0.url, addedAt: $0.displayDate) })
    }
    func setBrowseOptions(_ options: BrowseOptions) async {
        guard options != browseOptions else { return }
        browseOptions = options
        directoryPreferences[locationKey] = options
        persistDirectorySettings()
        clearContents()
        await reload()
    }
    func setFolderSort(_ sort: FolderSort) async {
        guard sort != folderSort else { return }
        folderSort = sort
        folderSortPreferences[locationKey] = sort
        persistDirectorySettings()
        await reload()
    }
    private func restoreBrowseOptions() {
        browseOptions = directoryPreferences[locationKey] ?? BrowseOptions()
        folderSort = folderSortPreferences[locationKey] ?? .nameAscending
    }
    func toggleDirectoryPin() {
        guard canPinDirectory, let sourceID = selectedID else { return }
        if isDirectoryPinned { bookmarks.removeAll { $0.id == locationKey } }
        else { bookmarks.append(DirectoryBookmark(sourceID: sourceID, name: currentDirectoryName, jellyPath: jellyPath, davPath: path)) }
        persistDirectorySettings()
    }
    func removeBookmark(_ bookmark: DirectoryBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }; persistDirectorySettings()
    }
    func openBookmark(_ bookmark: DirectoryBookmark) async {
        guard let server = servers.first(where: { $0.id == bookmark.sourceID }) else {
            error = "此固定目录的媒体来源已移除。"; return
        }
        if server.kind == .webDAV && !bookmark.davPath.allSatisfy({ DirectoryScope.contains(root: server.address, child: $0) }) {
            error = "固定目录超出了此来源的访问范围。"; return
        }
        selectedID = server.id
        jellyPath = server.kind == .jellyfin ? bookmark.jellyPath : []
        path = server.kind == .webDAV ? bookmark.davPath : []
        UserDefaults.standard.set(server.id.uuidString, forKey: "selectedServer")
        saveLocation(); restoreBrowseOptions(); clearContents(); await reload()
    }
    private func persistDirectorySettings() {
        if let data = try? JSONEncoder().encode(directoryPreferences) { UserDefaults.standard.set(data, forKey: "directoryPreferences.v1") }
        if let data = try? JSONEncoder().encode(folderSortPreferences) { UserDefaults.standard.set(data, forKey: "folderSortPreferences.v1") }
        if let data = try? JSONEncoder().encode(bookmarks) { UserDefaults.standard.set(data, forKey: "directoryBookmarks.v1") }
    }
    func toggleFavorite(_ video: Video) {
        if favorites.contains(video.id) { favorites.remove(video.id) } else { favorites.insert(video.id) }
        remember([video])
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
    }
    func savePosition(_ video: Video, time: Double) {
        guard time.isFinite else { return }
        positions[video.id] = max(0, time)
        progressSnapshots[video.id] = ProgressSnapshot(position: max(0, time), updatedAt: Date(), pending: video.remoteID != nil)
        persistProgress()
        var saved = PersonalVideo(video: video, lastPlayedAt: time > 1 ? Date() : personalVideos[video.id]?.lastPlayedAt)
        saved.video.resume = max(0, time)
        personalVideos[video.id] = saved
        persistPersonalVideos()
        UserDefaults.standard.set(positions, forKey: "positions")
    }
    func resumePosition(_ video: Video) -> Double { positions[video.id] ?? video.resume }
    var recentVideos: [Video] {
        personalVideos.values.filter {
            $0.lastPlayedAt != nil && isAvailable($0.video) && WatchProgress.canResume(position: resumePosition($0.video), duration: $0.video.duration)
        }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }.map { resolved($0.video) }
    }
    var favoriteVideos: [Video] {
        personalVideos.values.filter { favorites.contains($0.id) && isAvailable($0.video) }
            .map { resolved($0.video) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private func isAvailable(_ video: Video) -> Bool { video.sourceID == nil || servers.contains { $0.id == video.sourceID } }
    private func resolved(_ video: Video) -> Video {
        var result = video
        if let index = video.demoIndex { result.url = Bundle.main.url(forResource: "demo\(index)", withExtension: "mp4") }
        if let server = servers.first(where: { $0.id == video.sourceID }), let id = video.remoteID {
            result.artwork = ServerURL.endpoint(server.address, "Items/\(id)/Images/Primary", query: ["maxWidth": "700", "quality": "85"])
        }
        result.resume = resumePosition(video)
        return result
    }
    func remember(_ videos: [Video]) {
        for video in videos where favorites.contains(video.id) || resumePosition(video) > 1 {
            personalVideos[video.id] = personalVideos[video.id]?.updatingMetadata(video) ?? PersonalVideo(video: video)
        }
        persistPersonalVideos()
    }
    func removeHistory(_ video: Video) {
        personalVideos[video.id]?.lastPlayedAt = nil
        // Keep playback progress: removing a history entry does not reset the server's position.
        if !favorites.contains(video.id) { personalVideos.removeValue(forKey: video.id) }
        persistPersonalVideos()
    }
    private func persistPersonalVideos() {
        let recentIDs = Set(personalVideos.values.filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }.prefix(200).map(\.id))
        personalVideos = personalVideos.filter { favorites.contains($0.key) || recentIDs.contains($0.key) }
        if let data = try? JSONEncoder().encode(personalVideos) { UserDefaults.standard.set(data, forKey: "personalVideos.v1") }
    }
}


extension LibraryStore {
    func persistProgress() {
        if let data = try? JSONEncoder().encode(progressSnapshots) { UserDefaults.standard.set(data, forKey: "progressSnapshots.v1") }
    }
    func acknowledgeProgress(_ id: String, position: Double, capturedAt: Date) {
        guard var snapshot = progressSnapshots[id], snapshot.updatedAt <= capturedAt, abs(snapshot.position - position) < 1 else { return }
        snapshot.pending = false; progressSnapshots[id] = snapshot; persistProgress()
    }
    func mergedResume(_ video: Video, server: MediaServer) async -> Double {
        do {
            guard let remote = try await MediaClient.shared.freshProgress(video: video, server: server) else { return resumePosition(video) }
            try Task.checkCancellation()
            let date = remote.LastPlayedDate.flatMap { value -> Date? in
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
            }
            let position = remote.Played == true ? 0 : Double(remote.PlaybackPositionTicks ?? 0) / 10_000_000
            let merged = progressSnapshots[video.id]?.resolved(serverPosition: position, serverLastPlayed: date) ?? position
            positions[video.id] = merged
            UserDefaults.standard.set(positions, forKey: "positions")
            return merged
        } catch { return resumePosition(video) }
    }
    func reconnect(_ original: MediaServer, name: String, address: String, password: String) async throws {
        var candidate = original
        candidate.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original.name : name
        candidate.address = try ServerURL.parse(address)
        let secret: String
        if original.kind == .jellyfin {
            let (token, userID) = try await MediaClient.shared.signIn(server: candidate, password: password)
            guard userID == original.userID else { throw MediaError.message("这个地址对应不同账号。请添加为新来源，避免混合观看记录。") }
            secret = token
        } else {
            guard candidate.address == original.address else { throw MediaError.message("WebDAV 路径变更请添加为新来源。") }
            _ = try await MediaClient.shared.webDAV(server: candidate, password: password); secret = password
        }
        try Task.checkCancellation()
        guard let index = servers.firstIndex(where: { $0.id == original.id }) else { throw CancellationError() }
        try Credentials.save(secret, for: original.id)
        servers[index] = candidate; persist()
        await MediaCache.shared.clear(server: original); await ArtworkCache.shared.clear()
        if selectedID == original.id { await reload() }
    }
}
