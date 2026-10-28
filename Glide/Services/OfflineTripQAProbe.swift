#if DEBUG
import SwiftUI

struct OfflineTripQAProbe: View {
    var library: LibraryStore
    @State private var playback = PlaybackController()
    @State private var status = "准备验证"
    @State private var running = false
    @State private var checks = [String]()
    @State private var failure: String?
    private var endpoint: URL { URL(string: UserDefaults.standard.string(forKey: "glideTripFixtureAddress") ?? "http://127.0.0.1:8799")! }
    var body: some View {
        VStack(spacing: 16) {
            Text("Glide 1.12.0 离线验证").font(.headline)
            Text(status).accessibilityIdentifier("trip.probe.status")
            VideoSurface(presentation: playback.presentation, onLayer: playback.attachLayer, identity: playback.current?.id ?? "probe", title: playback.current?.title ?? "原创视频", frameReady: playback.frameReady, locked: true, filled: false, onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in }, subtitleSession: playback.subtitles, secondarySubtitleSession: playback.secondarySubtitles, subtitleClock: { playback.subtitleRenderTime })
                .frame(height: 260)
            Text("已通过 \(checks.count) 项").accessibilityIdentifier("trip.probe.count")
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            Button("重新验证") { Task { await run() } }.disabled(running)
        }.padding().task {
            UIApplication.shared.isIdleTimerDisabled = true
            await run()
        }.onDisappear { playback.stop(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func record(_ value: Bool, _ name: String) throws {
        guard value else { throw MediaError.message("验证失败：" + name) }
        checks.append(name)
    }
    private func control(_ path: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: endpoint.appendingPathComponent(path))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    private func waitFor(_ predicate: @MainActor () -> Bool, seconds: Double = 45) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard predicate() else { throw MediaError.message("验证等待超时：" + status) }
    }
    private func run() async {
        guard !running else { return }
        running = true; checks = []; failure = nil
        defer { running = false; playback.stop(); save() }
        do {
            _ = try await control("control/reset")
            let downloads = DownloadStore.shared
            // This probe is only reachable with --glide-trip-fixture; never clear production downloads.
            try record(DownloadStore.directory.lastPathComponent == "OfflineTravelQA", "isolated-production-download-store")
            for entry in downloads.entries { downloads.remove(entry.id) }
            let jellyfin = MediaServer(id: UUID(uuidString: "11200000-0000-0000-0000-000000000001")!, name: "原创 JF 合约", kind: .jellyfin, address: endpoint.appendingPathComponent("jellyfin"), username: "offline1120", userID: "fixture-user")
            var emby = jellyfin; emby.id = UUID(uuidString: "11200000-0000-0000-0000-000000000002")!; emby.kind = .emby; emby.address = endpoint.appendingPathComponent("emby")
            try Credentials.save("offline1120-token", for: jellyfin.id); try Credentials.save("offline1120-token", for: emby.id)
            library.servers.removeAll { $0.id == jellyfin.id || $0.id == emby.id }
            library.servers += [jellyfin, emby]
            defer { library.servers.removeAll { $0.id == jellyfin.id || $0.id == emby.id }; Credentials.delete(jellyfin.id); Credentials.delete(emby.id) }
            var originals = [Video]()
            for (server, id) in [(jellyfin, "mp4"), (emby, "mkv"), (jellyfin, "retry"), (jellyfin, "slow"), (jellyfin, "pgs")] {
                status = "准备下载 " + id
                let detail = try await MediaClient.shared.catalogDetail(server: server, id: id, refresh: true)
                try await downloads.enqueue(item: detail, server: server, sourceID: nil)
                let video = detail.video(server: server)
                if id == "slow" {
                    await downloads.pause(video.id)
                    try record(downloads.entries.first { $0.id == video.id }?.state == "已暂停", "download-pause-preserves-queue-entry")
                    await downloads.resume(video.id, library: library)
                }
                if id == "retry" {
                    try await waitFor { downloads.entries.first { $0.id == video.id }?.state == "下载失败" }
                    // Resume resolves the authenticated source from the library. Keep it ephemeral.
                    await downloads.resume(video.id, library: library)
                }
                try await waitFor { downloads.localURL(videoID: video.id) != nil }
                originals.append(video)
                try record(downloads.entries.first { $0.id == video.id }?.state == "已完成", "download-" + server.kind.rawValue + "-" + id)
            }
            try record(downloads.entries.count == 5, "deduplicated-completed-downloads")
            let scope = DiscoveryScope(kind: .catalog, sourceID: jellyfin.id, accountID: jellyfin.userID, key: "library", name: "原创剧集")
            let candidates = try await OfflineTripResolver.candidates(scopes: [scope], channel: nil, library: library) { _ in }
            let next = OfflineTripPlanner.episodes(candidates.candidates, count: 3, bytes: 1024 * 1024 * 1024)
            try record(next.items.map { $0.video.remoteID ?? "" } == ["mp4", "mkv"], "remote-series-resolution-and-episode-order")
            var blockedScope = scope; blockedScope.key = "library-blocked"
            let blocked = try await OfflineTripResolver.candidates(scopes: [blockedScope], channel: nil, library: library) { _ in }
            try record(blocked.candidates.contains { $0.video.remoteID == "unavailable" && $0.bytes == 0 } &&
                       OfflineTripPlanner.episodes(blocked.candidates, count: 3, bytes: 1024 * 1024 * 1024).items.isEmpty,
                       "unavailable-episode-blocks-later-remote-episodes")
            guard let ass = downloads.entries.first(where: { $0.id == originals[0].id }), let assFile = ass.subtitles?.first?.file else { throw MediaError.message("原始 ASS 未保存。") }
            let raw = try OfflineCompanions.read(assFile, filename: ass.filename)
            try record(ASSDocument.recognizes(raw) && String(data: raw, encoding: .utf8)!.contains("\\fad"), "raw-ass-effects-and-attached-font-preserved")
            try record(await downloads.companionIssues(ass).isEmpty, "selected-subtitle-and-font-files-complete")
            try record(ass.chapters?.count == 2, "server-chapters-cached-with-current-version")
            var otherAccount = jellyfin; otherAccount.username = "other-account"
            do {
                let detail = try await MediaClient.shared.catalogDetail(server: jellyfin, id: "mp4", refresh: true)
                try await downloads.enqueue(item: detail, server: otherAccount, sourceID: nil)
                throw MediaError.message("账号隔离未生效。")
            } catch { try record(error.localizedDescription != "账号隔离未生效。", "different-account-cannot-reuse-saved-download") }
            let file = DownloadStore.directory.appendingPathComponent("probe-trips.json")
            let store = OfflineTripStore(file: file)
            for trip in store.trips { try store.remove(trip.id, includingFiles: false) }
            var trip = OfflineTrip(name: "原创离线行程", videoIDs: Array(originals.prefix(2)).map(\.id), targetSeconds: 24, maximumBytes: 1024 * 1024 * 1024)
            trip.videos = Array(originals.prefix(2)).map { PersonalVideo(video: $0).video }
            try store.save(trip)
            var shared = trip; shared.id = UUID(); shared.name = "共用样例"
            try store.save(shared); try store.remove(shared.id, includingFiles: true)
            try record(downloads.localURL(videoID: originals[0].id) != nil, "removing-pack-retains-shared-files")
            try record(OfflineTripStore(file: file).trips.first?.videoIDs == trip.videoIDs, "pack-snapshot-relaunch-restores-order")
            // Download metadata/artwork tasks are bounded; finish them before freezing transport.
            try await Task.sleep(for: .seconds(1))
            _ = try await control("control/freeze")
            playback.inspectionMode = true
            for video in originals.filter({ ["mp4", "mkv", "pgs"].contains($0.remoteID ?? "") }) {
                status = "离线试播 " + video.title
                let local = try downloads.offlineVideo(video.id)
                playback.open(local, library: library, resumeAt: 0, recordsProgress: false)
                try await waitFor { playback.error != nil || playback.frameReady && playback.time >= 0.25 }
                try record(playback.error == nil && playback.frameReady, "offline-actual-frame-" + (video.remoteID ?? ""))
                if video.remoteID == "mkv" { try record(playback.engineDescriptor.id == .vlc, "mkv-uses-compatibility-decoder") }
                try record(!playback.supportsTranscoding && !playback.canPlayOnline, "offline-no-online-fallback-" + (video.remoteID ?? ""))
                await playback.subtitles.waitUntilPrepared()
                try record(!playback.subtitles.cues.isEmpty || playback.subtitles.hasBitmap, "offline-subtitle-" + (video.remoteID ?? ""))
                if video.remoteID == "pgs" {
                    try await waitFor { playback.subtitles.bitmapFrame != nil }
                    try record(playback.subtitles.hasBitmap, "offline-pgs-raster-displayed")
                }
                if video.remoteID == "mp4" { try record(playback.subtitles.hasASS, "offline-original-ass-renderer-installed") }
                playback.seek(4)
                try await waitFor { !playback.isSeeking && abs(playback.time - 4) < 1 }
                try record(playback.error == nil, "offline-seek-" + (video.remoteID ?? ""))
                try await downloads.recordPlaybackCheck(video.id, engine: playback.engineDescriptor.id)
                let entry = downloads.entries.first { $0.id == video.id }!
                try record(downloads.checked(entry), "actual-frame-check-persisted-" + (video.remoteID ?? ""))
                if video.remoteID == "mp4", let resource = playback.resource {
                    let before = try await MomentResolver.reference(video: local, library: library, resource: resource)
                    let sources = library.servers; library.servers = []
                    let after = try await MomentResolver.reference(video: local, library: library, resource: resource)
                    library.servers = sources
                    try record(before == after, "offline-navigation-identity-survives-removed-source")
                }
                playback.stop()
            }
            let entry = downloads.entries.first { $0.id == originals[0].id }!
            let path = try OfflineCompanions.url(assFile, filename: entry.filename)
            try Data("changed".utf8).write(to: path)
            let changedIssues = await downloads.companionIssues(entry)
            try record(!downloads.checked(entry) && !changedIssues.isEmpty, "changed-subtitle-invalidates-offline-check")
            try raw.write(to: path)
            let metrics = try await control("metrics")
            try record(metrics["requestsAfterFreeze"] as? Int == 0, "zero-server-requests-during-offline-playback-seek-and-switch")
            try OfflineTripStore.shared.save(trip)
            status = "验证通过"
        } catch { failure = error.localizedDescription; status = "验证失败" }
    }
    private func save() {
        let report: [String: Any] = ["passed": failure == nil, "checks": checks, "failure": failure ?? NSNull(), "version": PlaybackPreferences.appVersion, "timestamp": ISO8601DateFormatter().string(from: Date()), "scope": "Authored MP4/MKV with controlled Jellyfin/Emby contract endpoints, production DownloadStore/PlaybackController, frozen HTTP transport; not a real private media-server or airplane-mode acceptance"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineTripQA.json"), options: .atomic)
        }
    }
}
#endif
