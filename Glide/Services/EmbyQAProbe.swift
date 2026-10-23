#if DEBUG
import SwiftUI
import AVFoundation

/// Uses an isolated official Emby server and authored media through production services.
struct EmbyQAProbe: View {
    var library: LibraryStore
    @State private var playback = PlaybackController()
    @State private var checks: [String] = []
    @State private var stage = "Emby 验证准备中"
    @State private var failure: String?
    @State private var longGOPSeek: [String: String] = [:]
    private var address: String { UserDefaults.standard.string(forKey: "glideEmbyFixtureAddress") ?? "http://127.0.0.1:8772/emby" }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(presentation: playback.presentation, onLayer: { playback.attachLayer($0) }, identity: playback.current?.id ?? "emby-qa", title: "Emby QA", frameReady: playback.frameReady, locked: true, filled: false, onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in })
            VStack { Text(stage).accessibilityIdentifier("emby.probe.status"); Text("通过 \(checks.count) 项"); if let failure { Text(failure) }; Spacer() }.padding(36).foregroundStyle(.white)
        }.task { await run() }.onDisappear { playback.close(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    @MainActor private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw MediaError.message(message) }
    }
    @MainActor private func save(_ passed: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "nativeAndServiceChecks": checks.filter { !$0.hasPrefix("contract:") }.count, "injectedContractChecks": checks.filter { $0.hasPrefix("contract:") }.count, "longGOPSeek": longGOPSeek, "stage": stage, "error": failure ?? "", "version": PlaybackPreferences.appVersion, "device": UIDevice.current.model, "os": UIDevice.current.systemVersion, "scope": "Official Emby service and native playback; contract-prefixed check separately injects decoder seek result into production controller", "timestamp": ISO8601DateFormatter().string(from: Date())], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("emby-probe.json"), options: .atomic)
    }
    @MainActor private func record(_ name: String) throws { checks.append(name); try save() }
    @MainActor private func wait(timeout: Double = 40, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() || playback.isSeeking {
            try Task.checkCancellation()
            if let error = playback.error { throw MediaError.message(error) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MediaError.message("等待超时：" + stage) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    @MainActor private func open(_ video: Video, progress: Bool = false, tracks: TrackSelection = TrackSelection()) async throws {
        playback.tracks = tracks
        playback.open(video, library: library, resumeAt: 0, autoplay: false, recordsProgress: progress)
        if case .native(let player) = playback.presentation { player.isMuted = true }
        try await wait { playback.frameReady && playback.duration > 600 }
    }
    @MainActor private func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        do {
            let client = MediaClient.shared
            for source in library.servers where source.name.hasPrefix("1.7 QA Emby") { library.remove(source, includingDownloads: true) }
            stage = "验证认证失败与独立来源"
            var rejected = false
            do { try await library.add(name: "1.7 QA Emby rejected", kind: .emby, address: address, username: "glide-fixture", password: "invalid-fixture") }
            catch { rejected = true }
            try require(rejected && !library.servers.contains { $0.name == "1.7 QA Emby rejected" }, "失败登录留下来源")
            try await library.add(name: "1.7 QA Emby", kind: .emby, address: address, username: "glide-fixture", password: "glide170-fixture")
            guard let server = library.selectedServer, server.kind == .emby, let token = Credentials.read(server.id) else { throw MediaError.message("来源未保存") }
            try require(LibraryStore().servers.contains { $0 == server }, "来源未能从快照恢复")
            try record("auth:wrong-password-no-source-valid-login-keychain-snapshot")
            rejected = false
            do { try await library.reconnect(server, name: "bad", address: address, password: "invalid-fixture") }
            catch { rejected = true }
            try require(rejected && Credentials.read(server.id) == token && library.selectedServer == server, "失败重连覆盖凭据")
            try record("auth:failed-reconnect-preserves-working-credential")

            stage = "验证三类媒体库与目录"
            let roots = try await client.browse(server: server, parentID: nil)
            guard let movies = roots.folders.first(where: { $0.collectionType == "movies" }),
                  let shows = roots.folders.first(where: { $0.collectionType == "tvshows" }),
                  let home = roots.folders.first(where: { $0.collectionType == "homevideos" }) else { throw MediaError.message("三类片库未返回") }
            let moviePage = try await client.catalogPage(server: server, parentID: movies.id, type: "Movie", start: 0, refresh: true)
            guard let movie = moviePage.Items.first(where: { $0.Name == "Glide 原创电影" }) else { throw MediaError.message("电影为空") }
            let detail = try await client.catalogDetail(server: server, id: movie.id, refresh: true)
            try require(detail.Name == "Glide 原创电影" && detail.MediaSources?.first?.Container == "mp4", "电影详情不完整")
            let search = try await client.catalogPage(server: server, parentID: movies.id, type: "Movie", start: 0, search: "原创", refresh: true)
            try require(search.Items.contains { $0.id == movie.id }, "范围搜索未匹配")
            if let art = detail.video(server: server).artwork { _ = try await ArtworkCache.shared.image(server: server, url: art, pixels: 320) }
            try record("catalog:official-views-movie-detail-search-authenticated-poster")
            let next = try await client.catalogPage(server: server, parentID: movies.id, type: "Movie", start: moviePage.Items.count, refresh: true)
            try require(moviePage.Items.count == 60 && !next.Items.isEmpty && Set(moviePage.Items.map(\.id)).isDisjoint(with: next.Items.map(\.id)) && moviePage.Items.count + next.Items.count == moviePage.TotalRecordCount, "分页重复或遗漏")
            try record("catalog:official-pagination-60-plus-remainder-no-duplicates")
            let programs = try await client.catalogItems(server: server, parentID: shows.id, type: "Series", refresh: true)
            guard let program = programs.first else { throw MediaError.message("节目为空") }
            let seasons = try await client.catalogItems(server: server, parentID: program.id, type: "Season", refresh: true)
            let episodes = try await client.catalogItems(server: server, parentID: program.id, type: "Episode", refresh: true)
            try require(seasons.count == 1 && episodes.map(\.IndexNumber) == [1, 2] && episodes.allSatisfy { $0.SeriesId == program.id }, "季集排序或节目身份错误")
            let homePage = try await client.playbackVideos(server: server, parentID: home.id, start: 0)
            let homeDirectory = try await client.browse(server: server, parentID: home.id)
            try require(homePage.videos.count == 1 && homePage.videos[0].title == "家庭原创片段" && !homeDirectory.folders.isEmpty, "家庭视频递归或目录为空")
            try record("catalog:series-season-ordered-episodes-chinese-home-recursion")

            stage = "验证原文件首帧、暂停定位与播放"
            let video = detail.video(server: server)
            try await open(video)
            try require(playback.resource?.delivery == .direct && playback.resource?.sessionID != nil, "未使用原文件会话")
            playback.seek(12); try await wait { abs(playback.time - 12) < 0.4 }
            try require(!playback.isPlaybackRequested, "暂停定位改变播放意图")
            playback.toggle(); try await wait { playback.time > 13.5 }; playback.pause()
            try record("native:direct-first-frame-paused-seek-and-play")

            stage = "验证原画兼容 HLS 与定位"
            let previous = playback.resource?.sessionID
            try require(playback.canTryOriginalTransport, "原画兼容入口不可用")
            playback.tryOriginalTransport()
            try await wait { playback.frameReady && playback.resource?.sessionID != previous && playback.resource?.isTranscoding == true }
            try require(playback.resource?.delivery == .remux || playback.resource?.delivery == .audioConversion, "兼容模式未确认视频复制")
            playback.seek(24); try await wait { abs(playback.time - 24) <= 0.51 }
            try require(!playback.isPlaybackRequested, "HLS 定位改变暂停")
            let hls = playback.resource
            playback.close()
            if let hls { try await client.stopTranscoding(server: server, resource: hls) }
            try record("native:official-video-copy-hls-first-frame-paused-seek-stop")

            stage = "验证长 GOP 定位偏差恢复"
            let seekPage = try await client.catalogPage(server: server, parentID: movies.id, type: "Movie", start: 0, search: "ZZZ Long GOP", refresh: true)
            guard let seekItem = seekPage.Items.first else { throw MediaError.message("长 GOP 回归素材不存在") }
            let seekDetail = try await client.catalogDetail(server: server, id: seekItem.id, refresh: true)
            let seekVideo = seekDetail.video(server: server)
            try await open(seekVideo)
            playback.seek(12); try await wait { abs(playback.time - 12) < 0.4 }
            playback.toggle(); try await wait { playback.time > 13.5 }; playback.pause()
            let originalSession = playback.resource?.sessionID
            playback.tryOriginalTransport()
            try await wait { playback.frameReady && playback.resource?.sessionID != originalSession }
            playback.seek(24)
            try await wait { playback.frameReady && abs(playback.time - 24) < 0.2 }
            try require(!playback.isPlaybackRequested, "长 GOP 定位改变暂停")
            longGOPSeek = ["requested": "24", "actual": String(playback.time), "delivery": playback.resource?.delivery.rawValue ?? "", "recoveryTriggered": String(playback.diagnostic.events.contains("emby_seek_return_to_original"))]
            playback.close()
            try record("native:long-gop-authored-file-paused-seek-accurate-or-recovered")
            stage = "验证控制器定位偏差恢复契约"
            try await verifySeekRecovery(seekVideo)
            try record("contract:injected-seek-mismatch-production-controller-original-recovery-preserves-intent")

            stage = "验证双音轨与服务器字幕协商"
            let streams = detail.MediaSources?.first?.MediaStreams ?? []
            let audio = streams.filter { $0.Type == "Audio" }
            guard audio.count == 2, let alternate = audio.last, let subtitle = streams.first(where: { $0.Type == "Subtitle" }) else { throw MediaError.message("双音轨字幕样例未识别") }
            try await open(video, tracks: TrackSelection(audioIndex: alternate.Index, subtitleIndex: -1))
            try require(playback.resource?.isTranscoding == true, "备用音轨未由服务器协商")
            let query = URLComponents(url: playback.resource!.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            try require(query.contains { $0.name.lowercased() == "audiostreamindex" && $0.value == String(alternate.Index) }, "HLS 音轨索引丢失")
            playback.toggle(); try await wait { playback.time > 1.5 }; playback.pause(); playback.close()
            try await open(video, tracks: TrackSelection(mediaSourceID: detail.MediaSources?.first?.Id, subtitleIndex: subtitle.Index))
            try require(playback.resource?.delivery == .videoConversion, "字幕未按服务器烧录路径播放")
            playback.seek(5); try await wait { abs(playback.time - 5) <= 0.51 }
            try require(!playback.isPlaybackRequested, "字幕烧录流定位改变暂停")
            playback.close()
            try record("tracks:official-alternate-audio-subtitles-off-and-burned-subtitle-frame")

            stage = "验证播放上报、续播与已看同步"
            let direct = try await client.playback(video: video, server: server, quality: .original)
            try await client.report("", video: video, server: server, resource: direct, position: 0, paused: false)
            try await client.report("Progress", video: video, server: server, resource: direct, position: 120, paused: true)
            try await client.report("Stopped", video: video, server: server, resource: direct, position: 120, paused: true)
            let progress = try await client.freshProgress(video: video, server: server)
            try require(progress?.PlaybackPositionTicks == 1_200_000_000, "服务器未保存 120 秒续播")
            library.toggleFavorite(video); library.savePosition(video, time: 120)
            let restored = LibraryStore()
            try require(restored.favorites.contains(video.id) && restored.positions[video.id] == 120, "本机收藏／续播未恢复")
            try await client.setWatched(true, video: video, server: server)
            let watched = try await client.freshProgress(video: video, server: server)
            try require(watched?.Played == true, "已看未同步")
            try await client.setWatched(false, video: video, server: server)
            try record("progress:official-start-pause-stop-resume-watched-and-local-favorite")

            stage = "验证 Emby 节目跳过与字幕记忆"
            let first = episodes[0].video(server: server), second = episodes[1].video(server: server)
            try await open(first)
            var rule = PlaybackSkipRule(); rule.intro = 4
            try require(!playback.skips.supportsServerMarkers && !playback.skips.loading, "Emby 错用 Jellyfin 标记")
            try playback.skips.save(rule, series: true, duration: playback.duration)
            playback.seek(1); try await wait { playback.time < 1.5 }
            guard let segment = playback.activeSkip else { throw MediaError.message("手动跳过不可用") }
            playback.skip(segment); try await wait { playback.time >= 3.8 }
            try require(!playback.isPlaybackRequested, "跳过改变暂停")
            let srt = FileManager.default.temporaryDirectory.appendingPathComponent("emby-qa.srt")
            try Data("1\n00:00:00,000 --> 00:00:10,000\nEmby 中文字幕验证\n".utf8).write(to: srt)
            playback.subtitles.importFile(srt)
            try await wait { !playback.subtitles.reading && !playback.subtitles.cues.isEmpty }
            playback.subtitles.setDelay(0.5)
            try FileManager.default.removeItem(at: srt)
            try await open(first)
            try await wait { !playback.subtitles.cues.isEmpty }
            try require(playback.subtitles.delay == 0.5, "字幕延迟未恢复")
            try await open(second)
            try await wait { !playback.subtitles.discovering }
            try require(playback.skips.usesSeries && playback.skips.rule.intro == 4 && playback.subtitles.cues.isEmpty, "跨集规则或字幕隔离错误")
            playback.close()
            try record("reuse:manual-series-skip-preserves-pause-imported-subtitle-memory-isolated")

            stage = "验证原文件下载与离线首帧"
            try await DownloadStore.shared.enqueue(item: detail, server: server, sourceID: nil)
            try await wait(timeout: 90) { DownloadStore.shared.localURL(videoID: video.id) != nil || DownloadStore.shared.entries.first(where: { $0.id == video.id })?.state == "下载失败" }
            guard let local = DownloadStore.shared.localURL(videoID: video.id) else { throw MediaError.message(DownloadStore.shared.entries.first { $0.id == video.id }?.message ?? "下载未完成") }
            var offline = video; offline.sourceID = nil; offline.remoteID = nil; offline.url = local; offline.id += ":offline"
            try await open(offline)
            playback.seek(30); try await wait { abs(playback.time - 30) < 0.4 }; playback.close()
            try record("offline:authenticated-original-download-validation-frame-paused-seek")

            stage = "验证移除后的凭据和个人记录清理"
            library.remove(server, includingDownloads: true)
            try require(Credentials.read(server.id) == nil && !library.servers.contains { $0.id == server.id } && !library.favorites.contains(video.id) && library.positions[video.id] == nil && DownloadStore.shared.localURL(videoID: video.id) == nil, "移除未清理关联状态")
            try record("remove:keychain-source-favorite-progress-and-offline-cleanup")
            stage = "Emby 验证通过"; try save(true)
        } catch {
            failure = error.localizedDescription + "；位置 \(playback.time) / \(playback.duration)；\(playback.currentState)；画面 \(playback.frameReady)；定位中 \(playback.isSeeking)；传输 \(playback.resource?.delivery.rawValue ?? "none")；事件 " + playback.diagnostic.events.suffix(8).joined(separator: ",")
            playback.close(); stage = "Emby 验证未完成"; try? save()
        }
    }

    /// Injects only the decoder's seek result, separately from native playback evidence.
    @MainActor private func verifySeekRecovery(_ video: Video) async throws {
        let engine = EmbySeekContractEngine()
        let subject = PlaybackController(engine: engine)
        defer { subject.close() }
        func until(_ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while !condition() || subject.isSeeking {
                if let error = subject.error { throw MediaError.message(error) }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw MediaError.message("定位契约超时") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        for autoplay in [false, true] {
            subject.open(video, library: library, autoplay: autoplay, recordsProgress: false)
            try await until { subject.frameReady && subject.resource?.delivery == .direct }
            subject.tryOriginalTransport()
            try await until { subject.frameReady && subject.resource?.isTranscoding == true }
            subject.seek(24)
            try await until { subject.frameReady && subject.resource?.delivery == .direct && abs(subject.time - 24) < 0.01 }
            try require(subject.isPlaybackRequested == autoplay && subject.diagnostic.events.contains("emby_seek_return_to_original"), "定位恢复破坏播放意图")
            try require(engine.lastSeekTolerance == 0, "原文件恢复未精确定位")
            subject.close()
        }
    }
}

/// Contract double: supplies a misindexed HLS completion; never claimed as decoded video.
@MainActor private final class EmbySeekContractEngine: PlaybackEngine {
    let descriptor = PlaybackEngineDescriptor.native
    let player = AVPlayer()
    var presentation: PlaybackPresentation { .native(player) }
    var snapshot = PlaybackEngineSnapshot()
    var tracks: [PlaybackTrack] { [] }
    var selectedAudioID: String? { nil }
    var selectedSubtitleID: String? { nil }
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    private var resource: PlaybackResource?
    private(set) var lastSeekTolerance: Double?
    func load(_ resource: PlaybackResource, preload: (any PlaybackPreload)?, options: PlaybackEngineOptions) async throws {
        self.resource = resource
        snapshot = PlaybackEngineSnapshot(hasItem: true, ready: true, phase: .paused, duration: 660, frameReady: true)
        onEvent?(.installed); onEvent?(.ready); onEvent?(.frameReady)
    }
    func play(rate: Float) { snapshot.phase = .playing; onEvent?(.stateChanged) }
    func pause() { snapshot.phase = .paused }
    func setRate(_ rate: Float, playing: Bool) { snapshot.phase = playing ? .playing : .paused }
    func seek(to time: Double, tolerance: Double, completion: @escaping (Bool, Double) -> Void) {
        lastSeekTolerance = tolerance
        snapshot.time = resource?.isTranscoding == true ? time + 4.4 : time
        completion(true, snapshot.time)
    }
    func cancelPendingSeeks() {}
    func setForwardBuffer(_ seconds: Double) {}
    func selectTrack(_ id: String?, kind: PlaybackTrack.Kind) {}
    func inspectOutput() {}
    func preview(at: Double) async -> UIImage? { nil }
    func stop() { resource = nil; snapshot = PlaybackEngineSnapshot() }
}
#endif
