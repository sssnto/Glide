#if DEBUG
import SwiftUI

@MainActor enum UnifiedLibraryFixtures {
    static var endpoint: URL { URL(string: UserDefaults.standard.string(forKey: "glideUnifiedFixtureAddress") ?? "http://127.0.0.1:8813")! }
    static func prepare(_ library: LibraryStore) throws {
        var servers = [MediaServer]()
        for (suffix, name, kind, number) in [("jellyfin", "原创 Jellyfin", SourceKind.jellyfin, "1"), ("emby", "原创 Emby", .emby, "2"), ("slow", "慢来源", .jellyfin, "3")] {
            let server = MediaServer(id: UUID(uuidString: "11300000-0000-0000-0000-00000000000" + number)!, name: name, kind: kind, address: endpoint.appendingPathComponent(suffix), username: "unified-fixture", userID: "fixture-user")
            try Credentials.save("unified1130-token", for: server.id); servers.append(server)
        }
        let localID = UUID(uuidString: "11300000-0000-0000-0000-000000000004")!
        let root = LocalMediaStore.managedDirectory(localID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<2 {
            let target = root.appendingPathComponent("原创本地 \(index + 1).mp4")
            if !FileManager.default.fileExists(atPath: target.path), let source = Bundle.main.url(forResource: "demo\(index)", withExtension: "mp4") { try FileManager.default.copyItem(at: source, to: target) }
        }
        servers.append(MediaServer(id: localID, name: "原创本地", kind: .local, address: root, username: ""))
        library.servers = servers
    }
}

struct UnifiedLibraryQAView: View {
    var library: LibraryStore
    @State private var ready = false
    @State private var error: String?
    var body: some View {
        Group {
            if let error { Text(error).padding() }
            else if !ready { ProgressView("准备原创片库…") }
            else if ProcessInfo.processInfo.arguments.contains("--glide-unified-probe") { UnifiedLibraryQAProbe(library: library) }
            else { NavigationStack { UnifiedLibraryView(library: library) } }
        }.task {
            do { try UnifiedLibraryFixtures.prepare(library); ready = true }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct UnifiedLibraryQAProbe: View {
    var library: LibraryStore
    @State private var playback = PlaybackController()
    @State private var session = UnifiedLibrarySession()
    @State private var status = "准备验证"
    @State private var checks = [String]()
    @State private var failure: String?
    @State private var running = false
    var body: some View {
        VStack(spacing: 16) {
            Text(status).accessibilityIdentifier("unified.probe.status")
            VideoSurface(presentation: playback.presentation, onLayer: playback.attachLayer, identity: playback.current?.id ?? "probe", title: "原创统一片库", frameReady: playback.frameReady, locked: true, filled: false, onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in }, subtitleSession: playback.subtitles, secondarySubtitleSession: playback.secondarySubtitles, subtitleClock: { playback.subtitleRenderTime }).frame(height: 240)
            Text("通过 \(checks.count) 项").accessibilityIdentifier("unified.probe.count")
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).accessibilityIdentifier("unified.probe.failure") }
            Button("重新验证") { Task { await run() } }.disabled(running)
        }.padding().task { UIApplication.shared.isIdleTimerDisabled = true; await run() }
            .onDisappear { playback.stop(); session.stop(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func record(_ value: Bool, _ name: String) throws {
        guard value else { throw MediaError.message("验证失败：" + name) }; checks.append(name)
    }
    private func wait(_ condition: @MainActor () -> Bool, seconds: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(80)) }
        guard condition() else { throw MediaError.message("等待超时：" + status) }
    }
    private func control(_ path: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: UnifiedLibraryFixtures.endpoint.appendingPathComponent(path))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    private func run() async {
        guard !running else { return }; running = true; checks = []; failure = nil
        defer { running = false; playback.stop(); session.stop(); save() }
        do {
            _ = try await control("control/reset")
            try record(DownloadStore.directory.lastPathComponent == "OfflineUnifiedQA", "isolated-download-storage")
            for entry in DownloadStore.shared.entries where entry.serverID.uuidString.hasPrefix("11300000-") { DownloadStore.shared.remove(entry.id) }
            for server in library.servers { try await UnifiedLibraryIndex.shared.merge([], replacing: UnifiedSource.binding(server)) }
            let jf = library.servers[0], emby = library.servers[1], local = library.servers[3]
            let selected = Set(library.servers.map(UnifiedSource.binding)).union(["offline"])
            status = "跨来源独立返回"
            await session.search("原创海岸", filter: .all, selected: selected, library: library)
            try await wait({ session.works.contains { $0.variants.count == 3 } }, seconds: 2.5)
            try record(session.searching.contains(UnifiedSource.binding(library.servers[2])), "fast-sources-publish-before-slow-source")
            try await wait { session.searching.isEmpty }
            try record(session.works.count == 2, "same-title-remake-remains-separate")
            try record(session.status[UnifiedSource.binding(library.servers[2])]?.contains("暂时") == true, "failed-source-keeps-other-results")
            let shared = session.works.first { $0.variants.count == 3 }!
            try record(Set(shared.variants.map(\.binding)).count == 2, "trusted-provider-id-groups-jellyfin-and-emby")
            let v2 = shared.variants.first { $0.mediaSource?.Id == "v2" }!
            try await UnifiedLibraryIndex.shared.prefer(work: shared.id, record: v2.id)
            let restored = try await UnifiedLibraryIndex().preferred(shared.id)
            try record(restored == v2.id, "preferred-version-persists-after-index-reopen")
            await session.search("无标识", filter: .all, selected: selected, library: library)
            try await wait { session.searching.isEmpty }
            try record(session.works.count == 2, "same-title-without-id-never-automerges")
            await session.search("原创海岸", filter: .all, selected: [UnifiedSource.binding(jf)], library: library)
            try await wait { session.searching.isEmpty }
            try record(session.works.flatMap(\.variants).allSatisfy { $0.binding == UnifiedSource.binding(jf) }, "source-filter-removes-unselected-source")
            status = "分页与取消"
            await session.search("分页", filter: .all, selected: selected, library: library)
            try await wait { session.searching.isEmpty }
            for _ in 0..<3 { session.loadMore(library: library); try await wait { session.searching.isEmpty } }
            try record(session.works.count == 75 && session.more.isEmpty, "all-pages-deduplicated-across-two-sources")
            await session.search("分页", filter: .all, selected: selected, library: library)
            await session.search("无标识", filter: .all, selected: selected, library: library)
            try await wait { session.searching.isEmpty }
            try record(session.works.count == 2 && session.works.allSatisfy { $0.title.contains("无标识") }, "cancelled-query-cannot-publish-stale-results")
            status = "本地与账号边界"
            await session.search("原创本地", filter: .videos, selected: selected, library: library)
            try await wait { session.searching.isEmpty }
            try record(session.works.count == 2, "authorized-local-directory-index-and-search")
            let localRecord = session.works[0].variants[0]
            let localSelection = try await UnifiedPlaybackResolver.resolve(localRecord, library: library)
            playback.inspectionMode = true
            playback.open(localSelection.video, library: library, recordsProgress: false)
            try await wait { playback.error != nil || playback.frameReady && playback.time > 0.2 }
            try record(playback.error == nil && playback.resource?.url.isFileURL == true, "local-search-result-actually-decodes")
            playback.stop()
            var changed = jf; changed.userID = "different-user"
            let file = DownloadStore.directory.appendingPathComponent("account-index.json")
            let accountIndex = UnifiedLibraryIndex(file: file)
            try await accountIndex.merge(shared.variants)
            let wrongAccount = try await accountIndex.records(active: [UnifiedSource.binding(changed)])
            try record(wrongAccount.isEmpty, "cached-metadata-is-account-and-address-bound")
            let originalServers = library.servers; library.servers = [changed]
            do { _ = try await UnifiedPlaybackResolver.resolve(v2, library: library); throw MediaError.message("错误账号可播放") }
            catch { try record(error.localizedDescription != "错误账号可播放", "changed-account-cannot-resolve-saved-version") }
            library.servers = originalServers
            let scope = try UnifiedSource.scope(v2, library: library)
            try record(scope.sourceID == jf.id && scope.key == "shared", "channel-action-binds-exact-selected-source")
            let channel = PrivateChannel(name: "统一片库原创频道", scopes: [scope])
            try DiscoveryStore.shared.save(channel)
            try record(DiscoveryStore().channels.contains { $0.id == channel.id }, "channel-action-persists-in-existing-channel-store")
            let show = UnifiedSource.records(item: try await MediaClient.shared.catalogDetail(server: jf, id: "show", refresh: true), server: jf)[0]
            let showScope = try UnifiedSource.scope(show, library: library)
            let trip = try await OfflineTripResolver.candidates(scopes: [showScope], channel: nil, library: library) { _ in }
            try record(OfflineTripPlanner.episodes(trip.candidates, count: 3, bytes: 1_000_000_000).items.map { $0.video.episodeNumber ?? 0 } == [1,2], "series-search-action-feeds-ordered-offline-planner")
            status = "真实版本播放"
            let detail = try await MediaClient.shared.catalogDetail(server: jf, id: "shared", refresh: true)
            try await DownloadStore.shared.enqueue(item: detail, server: jf, sourceID: nil)
            try await wait { DownloadStore.shared.localURL(videoID: detail.video(server: jf).id) != nil }
            try record(!DownloadStore.shared.canReuse(videoID: detail.video(server: jf).id, sourceID: "v2"), "downloaded-v1-cannot-shadow-selected-v2")
            for row in [v2, shared.variants.first { $0.binding == UnifiedSource.binding(emby) }!] {
                let selection = try await UnifiedPlaybackResolver.resolve(row, library: library)
                playback.tracks = selection.tracks
                playback.open(selection.video, library: library, recordsProgress: false)
                try await wait { playback.error != nil || playback.frameReady && playback.time > 0.2 }
                try record(playback.error == nil && playback.resource?.mediaSourceID == row.mediaSource?.Id && playback.resource?.url.isFileURL == false, "selected-version-actually-decodes-" + (row.mediaSource?.Id ?? "unknown"))
                playback.stop()
            }
            var removedVersion = v2; removedVersion.mediaSource?.Id = "removed-version"
            do { _ = try await UnifiedPlaybackResolver.resolve(removedVersion, library: library); throw MediaError.message("失效版本可播放") }
            catch { try record(error.localizedDescription != "失效版本可播放", "removed-version-is-rejected-before-playback") }
            let metrics = try await control("metrics")
            try record((metrics["streams"] as? [String])?.contains("v2") == true && (metrics["streams"] as? [String])?.contains("e1") == true, "server-observed-selected-media-source-ids")
            status = "离线搜索与播放"
            _ = try await control("control/freeze")
            await session.search("原创海岸", filter: .downloaded, selected: selected, library: library)
            try record(session.works.count == 1 && session.searching.isEmpty, "offline-filter-searches-without-server-query")
            let offline = session.works[0].variants[0]
            let offlineSelection = try await UnifiedPlaybackResolver.resolve(offline, library: library)
            playback.tracks = TrackSelection(); playback.open(offlineSelection.video, library: library, recordsProgress: false)
            try await wait { playback.error != nil || playback.frameReady && playback.time > 0.2 }
            try record(playback.error == nil && playback.resource?.url.isFileURL == true, "offline-search-result-actually-decodes")
            playback.seek(3); try await wait { !playback.isSeeking && abs(playback.time - 3) < 1 }
            let frozen = try await control("metrics")
            try record(frozen["afterFreeze"] as? Int == 0, "zero-network-requests-for-offline-search-play-and-seek")
            _ = try await control("control/reset")
            status = "验证通过"
            _ = local
        } catch { failure = error.localizedDescription; status = "验证失败" }
    }
    private func save() {
        let report: [String: Any] = ["version": PlaybackPreferences.appVersion, "passed": failure == nil, "failure": failure ?? NSNull(), "checks": checks, "timestamp": ISO8601DateFormatter().string(from: Date()), "scope":"Original video and authenticated Jellyfin/Emby contract fixture; production search/index/playback/download/channel/offline planner; not a private server matrix or airplane-mode observation"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]) { try? data.write(to: FileManager.default.urls(for: .documentDirectory,in:.userDomainMask)[0].appendingPathComponent("UnifiedLibraryQA.json"),options:.atomic) }
    }
}
#endif
