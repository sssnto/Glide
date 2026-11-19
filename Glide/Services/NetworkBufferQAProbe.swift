#if DEBUG
import SwiftUI

/// Fixed loopback fixture only; exercises production AVPlayer and controller.
struct NetworkBufferQAProbe: View {
    let library: LibraryStore
    @State private var playback: PlaybackController
    @State private var native: NativePlaybackEngine
    @State private var stage = "准备 4K 网络验证"
    @State private var report = ""
    @State private var checks: [String] = []
    @State private var measures: [String: Double] = [:]
    @State private var firstDiagnostic: String?
    @State private var holdingDiagnostic: String?
    @State private var scenarioDiagnostics: [String: String] = [:]

    init(library: LibraryStore) {
        self.library = library
        let engine = NativePlaybackEngine()
        engine.player.isMuted = true
        _native = State(initialValue: engine)
        _playback = State(initialValue: PlaybackController(engine: engine))
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(presentation: playback.presentation, onLayer: playback.attachLayer,
                identity: "network-probe", title: "原创 4K 验证", frameReady: playback.frameReady, locked: true, filled: false,
                onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in })
            VStack {
                Text(stage).accessibilityIdentifier("network.probe.status")
                Text("已完成 \(checks.count) 项").font(.caption)
                Spacer()
                Text(playback.time.mediaTime + " / " + playback.duration.mediaTime).font(.caption.monospacedDigit())
                if !report.isEmpty {
                    Text("验证报告已生成").font(.caption)
                        .accessibilityLabel(report).accessibilityIdentifier("network.probe.report")
                }
            }.padding(32).foregroundStyle(.white)
        }.task { await run() }
            .onDisappear { playback.stop(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    @MainActor private func wait(_ description: String, seconds: Double = 25, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try Task.checkCancellation()
            if let error = playback.error { throw MediaError.message(description + "：" + error) }
            if ProcessInfo.processInfo.systemUptime > deadline { throw MediaError.message(description + "超时；" + playback.currentState) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    @MainActor private func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw MediaError.message(description) }
        checks.append(description)
    }
    @MainActor private func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        if ProcessInfo.processInfo.arguments.contains("--glide-transport-recovery") { await runTransport(); return }
        do {
            try await library.prepareJellyfinFixture()
            guard let server = library.servers.first(where: { $0.name == "Glide Recovery Fixture" && $0.address.host == "127.0.0.1" }) else {
                throw MediaError.message("缺少固定 loopback QA 来源")
            }
            let item = try await MediaClient.shared.catalogDetail(server: server, id: "buffer4k", refresh: true)
            let video = item.video(server: server)
            stage = "验证原画 4K 续播缓存"
            playback.open(video, library: library, recordsProgress: false)
            try await wait("4K 首帧") { playback.frameReady }
            try await wait("缓冲等待期间诊断持续更新", seconds: 35) {
                (playback.diagnostic.rebufferElapsedSeconds ?? 0) >= 1 &&
                (playback.diagnostic.activeBufferingSeconds ?? 0) >= 0.5
            }
            holdingDiagnostic = playback.diagnostic.export
            try check(playback.diagnostic.nativeTimeControlStatus == "paused" && playback.isPlaybackRequested,
                "refill:holding-with-playback-requested")
            try await wait("实际缓存填充续播", seconds: 45) { (native.snapshot.lastResumeBufferedAhead ?? 0) >= 2 }
            measures["resumeBufferedAhead"] = native.snapshot.lastResumeBufferedAhead
            try check(native.snapshot.lastResumeBufferedAhead! >= 2, "refill:useful-cache-before-resume")
            try await wait("原画继续推进", seconds: 35) { playback.time >= 12 }
            try check(playback.resource?.delivery == .direct && playback.engineDescriptor.id == .avPlayer, "route:original-native-direct")
            try check(native.snapshot.width == 2160 && native.snapshot.height == 3840, "output:actual-portrait-4k")
            try check(playback.diagnostic.recoveryCount == 0, "route:no-video-conversion")
            try check(playback.diagnostic.events.contains("network_rebuffer_preroll"), "refill:preroll-requested")
            try check(playback.diagnostic.rebufferElapsedSeconds == nil && (playback.diagnostic.lastRebufferSeconds ?? 0) > 0,
                "refill:completed-wait-recorded")
            measures["sourceFrameRate"] = playback.diagnostic.sourceFrameRate
            measures["lastRebufferSeconds"] = playback.diagnostic.lastRebufferSeconds
            firstDiagnostic = playback.diagnostic.export

            playback.stop()
            stage = "验证缓冲期间暂停与拖动"
            playback.open(video, library: library, recordsProgress: false)
            try await wait("第二次 4K 首帧") { playback.frameReady }
            try await wait("第二次填充等待") { native.snapshot.phase == .waiting && (native.snapshot.rebufferCount ?? 0) > 0 }
            playback.pause()
            let paused = native.snapshot.time
            try await Task.sleep(for: .seconds(NativeRebufferPolicy.maximumHold + 0.5))
            try check(!playback.isPlaybackRequested && native.player.rate == 0 && abs(native.snapshot.time - paused) < 0.3, "intent:pause-cancels-delayed-resume")
            playback.seek(20)
            try await wait("暂停拖动") { abs(playback.time - 20) < 0.6 }
            try check(!playback.isPlaybackRequested && native.player.rate == 0, "intent:seek-preserves-pause")
            playback.play()
            try await wait("拖动后继续", seconds: 30) { playback.time >= 22 }
            try check(playback.isPlaybackRequested, "intent:resume-after-seek")
            playback.pause()
            measures["finalTime"] = playback.time
            stage = "4K 网络验证通过"
            try save(passed: true, firstDiagnostic: firstDiagnostic ?? "{}", error: nil)
        } catch {
            let diagnostic = playback.diagnostic.export
            playback.pause(); stage = "4K 网络验证未通过"
            try? save(passed: false, firstDiagnostic: firstDiagnostic ?? diagnostic, error: error.localizedDescription)
        }
    }
    @MainActor private func runTransport() async {
        do {
            try await library.prepareJellyfinFixture()
            guard let server = library.servers.first(where: { $0.name == "Glide Recovery Fixture" && $0.address.host == "127.0.0.1" }) else {
                throw MediaError.message("缺少固定 loopback QA 来源")
            }
            let item = try await MediaClient.shared.catalogDetail(server: server, id: "buffer4k", refresh: true)
            let video = item.video(server: server)
            defer { DownloadStore.shared.remove(video.id) }
            DownloadStore.shared.remove(video.id)
            stage = "验证开播即使用原画分段"
            playback.tracks = TrackSelection(mediaSourceID: "buffer4k-preferred")
            playback.open(video, library: library, resumeAt: 3)
            try await wait("自动原画分段首帧") { playback.resource?.delivery == .remux && playback.frameReady }
            try check(playback.engineDescriptor.id == .avPlayer && native.snapshot.width == 2160 && native.snapshot.height == 3840,
                "auto:same-native-portrait-4k")
            try check(playback.time >= 2.4 && playback.time < 6 && playback.resource?.mediaSourceID == "buffer4k-preferred",
                "auto:position-and-source-preserved")
            measures["initialResumePosition"] = playback.time
            try await wait("越过开播六秒并持续播放") { playback.time >= 15 }
            try check(playback.diagnostic.recoveryCount == 0 && playback.diagnostic.requestedQuality == "compatible",
                "auto:original-transport-before-any-recovery")
            try check(playback.diagnostic.directStreamFlag == false && playback.diagnostic.originalTransportOutcome == "active" &&
                playback.diagnostic.originalTransportAttempts == 1, "false-flag:actual-copy-url-enables-original-transport")
            try check(!playback.diagnostic.events.contains("resource_ready_direct") &&
                !playback.diagnostic.events.contains("network_rebuffer_hold") && (native.snapshot.nativeStalls ?? 0) == 0,
                "auto:no-direct-item-or-startup-stall")
            let initialMetrics = try await MediaClient.shared.request(URL(string: "http://127.0.0.1:8768/debug/metrics")!)
            try check(try JSONDecoder().decode([String: Int].self, from: initialMetrics)["four_k_direct_requests", default: 0] == 0,
                "auto:no-progressive-media-request")
            firstDiagnostic = playback.diagnostic.export

            stage = "验证再次打开与暂停起播"
            playback.stop()
            playback.tracks = TrackSelection(mediaSourceID: "buffer4k-unknown")
            playback.open(video, library: library, resumeAt: 20, autoplay: false)
            try await wait("暂停原画分段首帧") { playback.frameReady }
            try check(playback.resource?.delivery == .remux && !playback.isPlaybackRequested && native.player.rate == 0 &&
                abs(native.snapshot.time - 20) < 0.6, "reopen:preferred-route-keeps-paused-resume")
            try check(playback.resource?.mediaSourceID == "buffer4k-unknown" &&
                playback.diagnostic.events.contains("transport_preferred_original"), "unknown-capability:verified-copy-before-playback")
            playback.play()
            try await wait("暂停后继续") { playback.time >= 22 }
            scenarioDiagnostics["pausedReopen"] = playback.diagnostic.export

            stage = "验证暂停时手动切换传输"
            playback.stop(); playback.tracks = TrackSelection(mediaSourceID: "buffer4k-manual")
            playback.open(video, library: library, resumeAt: 0.5, recordsProgress: false)
            try await wait("手动对照首帧") { playback.frameReady }
            try check(playback.resource?.delivery == .direct && playback.canTryOriginalTransport,
                "unknown:keeps-direct-and-manual-entry")
            playback.pause()
            let pausedAt = native.snapshot.time
            // The download may complete while an online item remains open.
            // A transport retry must still request the server in that case.
            try await DownloadStore.shared.enqueue(item: item, server: server, sourceID: nil)
            try await wait("原创样例下载", seconds: 45) { DownloadStore.shared.localURL(videoID: video.id) != nil }
            playback.tryOriginalTransport()
            try await wait("暂停时原画分段就绪") { playback.resource?.delivery == .remux && playback.frameReady }
            try await Task.sleep(for: .seconds(1))
            try check(!playback.isPlaybackRequested && native.player.rate == 0 && abs(native.snapshot.time - pausedAt) < 0.6,
                "manual:pause-and-position-preserved")
            scenarioDiagnostics["manualAfterDownload"] = playback.diagnostic.export

            stage = "验证离线文件保留与在线播放"
            playback.stop()
            playback.tracks = TrackSelection()
            playback.open(video, library: library, recordsProgress: false)
            try await wait("本地样例首帧") { playback.frameReady && playback.canPlayOnline }
            playback.pause()
            playback.seek(12)
            try await wait("离线定位") { abs(native.snapshot.time - 12) < 0.6 }
            let offlineAt = native.snapshot.time
            measures["offlineToOnlinePosition"] = offlineAt
            playback.playOnline()
            try await wait("切回网络原画") { playback.resource?.url.isFileURL == false && playback.frameReady }
            try check(DownloadStore.shared.localURL(videoID: video.id) != nil, "online:download-preserved")
            try check(!playback.isPlaybackRequested && native.player.rate == 0 && abs(native.snapshot.time - offlineAt) < 0.6,
                "online:pause-and-position-preserved")
            try check(playback.resource?.delivery == .remux && playback.diagnostic.events.contains("transport_preferred_original"),
                "online:preferred-original-segments")
            scenarioDiagnostics["onlineWithDownload"] = playback.diagnostic.export

            stage = "验证服务器拒绝时返回原画"
            playback.stop(); DownloadStore.shared.remove(video.id)
            playback.tracks = TrackSelection(mediaSourceID: "buffer4k-reject")
            playback.open(video, library: library, resumeAt: 0.5, autoplay: false)
            try await wait("拒绝场景原画首帧") { playback.frameReady }
            try await wait("恢复直放", seconds: 30) {
                playback.diagnostic.events.contains("transport_return_to_direct") && playback.resource?.delivery == .direct && playback.frameReady
            }
            try check(!playback.isPlaybackRequested && native.player.rate == 0 && playback.canTryOriginalTransport,
                "failure:paused-direct-keeps-manual-retry")
            try check(!playback.diagnostic.events.contains("attempt_hd1080") && !playback.diagnostic.events.contains("attempt_hd720"),
                "failure:no-quality-downgrade")
            try check(playback.resource?.mediaSourceID == "buffer4k-reject" && abs(native.snapshot.time - 0.5) < 0.6,
                "failure:negotiation-retains-source-and-position")
            scenarioDiagnostics["rejectedNegotiation"] = playback.diagnostic.export
            try await Task.sleep(for: .seconds(2))
            try check(playback.diagnostic.originalTransportAttempts == 1 &&
                playback.diagnostic.originalTransportOutcome == "returned_to_direct" &&
                playback.diagnostic.originalTransportFailure == [PlaybackFailure(domain: "GlideTransportError", code: 2)],
                "failure:persistent-reason-without-automatic-loop")
            playback.tryOriginalTransport()
            try await wait("自动失败后手动重试成功") { playback.resource?.delivery == .remux && playback.frameReady }
            try check(playback.diagnostic.originalTransportAttempts == 2 && playback.originalTransportActive &&
                !playback.isPlaybackRequested && abs(native.snapshot.time - 0.5) < 0.6,
                "retry:manual-overrides-automatic-budget-and-keeps-position")
            scenarioDiagnostics["manualRetryAfterAutomaticFailure"] = playback.diagnostic.export

            stage = "验证不接受视频编码响应"
            playback.stop(); playback.tracks = TrackSelection(mediaSourceID: "buffer4k-encode")
            playback.open(video, library: library, resumeAt: 1, autoplay: false)
            try await wait("拒绝非复制视频") { playback.frameReady && playback.resource?.delivery == .direct }
            try check(playback.canTryOriginalTransport && playback.diagnostic.originalTransportOutcome == "returned_to_direct" &&
                playback.diagnostic.originalTransportFailure == [PlaybackFailure(domain: "GlideTransportError", code: 3)],
                "encode:refused-with-manual-entry-retained")
            scenarioDiagnostics["rejectedVideoEncoding"] = playback.diagnostic.export

            stage = "验证分段加载失败回到直放"
            playback.stop(); playback.tracks = TrackSelection(mediaSourceID: "buffer4k-bad-hls")
            playback.open(video, library: library, resumeAt: 1, autoplay: false)
            try await wait("无效 HLS 回到直放", seconds: 35) {
                playback.frameReady && playback.resource?.delivery == .direct &&
                playback.diagnostic.events.contains("transport_return_to_direct")
            }
            try check(!playback.isPlaybackRequested && native.player.rate == 0 && abs(native.snapshot.time - 1) < 0.6 &&
                playback.resource?.mediaSourceID == "buffer4k-bad-hls", "load-failure:paused-source-and-position-preserved")
            try check(playback.diagnostic.events.filter { $0 == "attempt_compatible" }.count == 1 &&
                playback.canTryOriginalTransport && !playback.diagnostic.events.contains("attempt_hd1080") &&
                !playback.diagnostic.events.contains("attempt_hd720"), "load-failure:no-loop-or-video-conversion")
            scenarioDiagnostics["failedHLSLoad"] = playback.diagnostic.export

            stage = "验证无效蓄缓存不会重复"
            playback.stop(); playback.tracks = TrackSelection(mediaSourceID: "buffer4k-no-remux")
            playback.open(video, library: library, recordsProgress: false)
            try await wait("不支持分段的原画首帧") { playback.frameReady }
            try await wait("第二次网络停顿", seconds: 70) {
                (playback.diagnostic.nativeStalls ?? 0) >= 2 &&
                playback.diagnostic.events.contains("network_rebuffer_unproductive") && native.snapshot.phase == .waiting
            }
            try await Task.sleep(for: .seconds(6))
            try check(native.snapshot.rebufferCount == 1 && native.snapshot.rebufferElapsedSeconds == nil,
                "refill:subsequent-stall-does-not-repeat-hold")
            try check(playback.diagnostic.recoveryCount == 0 && playback.canTryOriginalTransport &&
                playback.diagnostic.originalTransportAttempts == 1 && playback.diagnostic.originalTransportOutcome == "returned_to_direct",
                "unsupported:one-automatic-trial-keeps-manual-entry")
            playback.pause()
            let metrics = try await MediaClient.shared.request(URL(string: "http://127.0.0.1:8768/debug/metrics")!)
            let values = try JSONDecoder().decode([String: Int].self, from: metrics)
            try check(values["four_k_copy_negotiations"] == 9, "server:nine-bounded-copy-negotiations")
            try check(values["/mock/jellyfin/streams/encoded.m3u8", default: 0] == 0, "server:never-fetches-unconfirmed-video-encoding")
            measures["finalTime"] = playback.time
            stage = "4K 网络验证通过"
            try save(passed: true, firstDiagnostic: firstDiagnostic ?? "{}", error: nil)
        } catch {
            let diagnostic = playback.diagnostic.export
            playback.pause(); stage = "4K 网络验证未通过"
            try? save(passed: false, firstDiagnostic: firstDiagnostic ?? diagnostic, error: error.localizedDescription)
        }
    }
    @MainActor private func save(passed: Bool, firstDiagnostic: String, error: String?) throws {
        let value: [String: Any] = ["passed": passed, "version": PlaybackPreferences.appVersion,
            "checks": checks, "measurements": measures, "error": error ?? "",
            "scenarios": try scenarioDiagnostics.mapValues { try JSONSerialization.jsonObject(with: Data($0.utf8)) },
            "firstDiagnostic": try JSONSerialization.jsonObject(with: Data(firstDiagnostic.utf8)),
            "holdingDiagnostic": try JSONSerialization.jsonObject(with: Data((holdingDiagnostic ?? "{}").utf8)),
            "finalDiagnostic": try JSONSerialization.jsonObject(with: Data(playback.diagnostic.export.utf8))]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        report = String(decoding: data, as: UTF8.self)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try data.write(to: root.appendingPathComponent("network-buffer-probe.json"), options: .atomic)
    }
}
#endif

#if DEBUG
/// Authored loopback media only. Measures the production controller, loader and AVPlayer handoff.
struct FeedWarmupQAProbe: View {
    let library: LibraryStore
    @State private var playback = PlaybackController()
    @State private var status = "准备相邻视频预加载验证"
    @State private var checks: [String] = []
    @State private var metrics: [String: Double] = [:]
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(presentation: playback.presentation, onLayer: playback.attachLayer,
                identity: playback.current?.id ?? "feed-warmup", title: "原创预加载验证", frameReady: playback.frameReady,
                locked: true, filled: false, onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in })
            VStack { Text(status).accessibilityIdentifier("feed.probe.status"); Text("通过 \(checks.count) 项"); Spacer() }.foregroundStyle(.white).padding(32)
        }.task { await run() }.onDisappear { playback.close(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    @MainActor private func wait(_ name: String, seconds: Double = 20, _ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            if let error = playback.error { throw MediaError.message(name + ": " + error) }
            guard ProcessInfo.processInfo.systemUptime < end else { throw MediaError.message(name + "超时") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    @MainActor private func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw MediaError.message(label) }; checks.append(label)
    }
    @MainActor private func save(_ passed: Bool, error: String? = nil) {
        let result: [String: Any] = ["passed": passed, "checks": checks, "metrics": metrics, "error": error ?? "", "scope": "Authored loopback fixture; not a private NAS measurement", "delivery": playback.resource?.delivery.rawValue ?? "", "events": playback.diagnostic.events]
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("feed-warmup-report.json")
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: file)
    }
    @MainActor private func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        do {
            let server = MediaServer(name: "Glide Feed Warmup QA", kind: .jellyfin, address: URL(string: "http://127.0.0.1:8797")!, username: "fixture", userID: "fixture-user")
            try Credentials.save("authored-feed-only", for: server.id)
            library.servers.append(server)
            func video(_ id: String) -> Video { Video(id: server.id.uuidString + id, title: id, subtitle: "原创 loopback 素材", sourceID: server.id, remoteID: id, duration: 20, mediaType: "Video") }
            let cold = video("cold"), direct = video("direct"), segmented = video("segmented"), extra = video("extra")
            status = "测量未预加载的起播"
            let before = ProcessInfo.processInfo.systemUptime
            playback.open(cold, library: library, recordsProgress: false)
            try await wait("冷启动首帧") { playback.frameReady }
            metrics["coldFirstFrameSeconds"] = ProcessInfo.processInfo.systemUptime - before
            playback.pause()
            let cold4kStart = ProcessInfo.processInfo.systemUptime
            playback.open(video("segmented-cold"), library: library, recordsProgress: false)
            try await wait("未预加载 4K 首帧") { playback.frameReady }
            metrics["coldCopyFirstFrameSeconds"] = ProcessInfo.processInfo.systemUptime - cold4kStart
            playback.pause()
            status = "预加载三个相邻视频"
            playback.prepareAdjacent([direct, extra, segmented], library: library)
            try await wait("分段读取预加载") { playback.warmupEvidence(direct, library: library).bytes > 0 }
            metrics["directCachedBytes"] = Double(playback.warmupEvidence(direct, library: library).bytes)
            let warmStart = ProcessInfo.processInfo.systemUptime
            playback.tracks = TrackSelection(); playback.open(direct, library: library, recordsProgress: false)
            try await wait("已预加载首帧") { playback.frameReady }
            metrics["warmDirectFirstFrameSeconds"] = ProcessInfo.processInfo.systemUptime - warmStart
            try check(playback.diagnostic.events.contains("warmup_startup_bytes"), "direct:consumed_actual_startup_bytes")
            try check((metrics["warmDirectFirstFrameSeconds"] ?? 99) < (metrics["coldFirstFrameSeconds"] ?? 0), "direct:less_wait_than_cold")
            status = "预加载原画兼容 4K 路线"
            playback.prepareAdjacent([segmented, extra], library: library)
            try await wait("原画分段预热完成") { playback.warmupEvidence(segmented, library: library).copyPrimed }
            let evidence = playback.warmupEvidence(segmented, library: library)
            try check(evidence.players == 1 && evidence.paused, "4k:one_muted_paused_speculative_player")
            let copyStart = ProcessInfo.processInfo.systemUptime
            playback.tracks = TrackSelection(); playback.open(segmented, library: library, recordsProgress: false)
            try await wait("分段复用首帧") { playback.frameReady }
            metrics["warmCopyFirstFrameSeconds"] = ProcessInfo.processInfo.systemUptime - copyStart
            try check(playback.resource.map { [.remux, .audioConversion].contains($0.delivery) } == true && playback.diagnostic.events.contains("warmup_original_segments"), "4k:reused_copy_route_without_direct_detour")
            if case .native(let player) = playback.presentation {
                let size = player.currentItem?.presentationSize ?? .zero
                try check(Int(size.width) == 3840 && Int(size.height) == 2160, "4k:actual_3840x2160_frames")
            }
            try check((metrics["warmCopyFirstFrameSeconds"] ?? 99) < (metrics["coldCopyFirstFrameSeconds"] ?? 0), "4k:less_wait_than_same_format_cold")
            try check(playback.diagnostic.recoveryCount == 0, "4k:no_video_reencoding_recovery")
            let next4k = video("segmented-next")
            playback.prepareAdjacent([next4k], library: library)
            try await wait("播放 4K 时准备下一条 4K") { playback.warmupEvidence(next4k, library: library).copyPrimed }
            let runningAt = playback.time
            try await Task.sleep(for: .seconds(1.2))
            try check(playback.time > runningAt + 0.3 && playback.diagnostic.recoveryCount == 0,
                "4k:current_progresses_while_next_4k_primes")
            playback.pause()
            try check(playback.warmupEvidence(next4k, library: library).players == 0, "pause:releases_unselected_segment_player")
            playback.seek(3)
            try await wait("暂停定位保留") { abs(playback.time - 3) < 0.5 }
            try check(!playback.isPlaybackRequested, "handoff:pause_and_seek_preserved")
            do {
                _ = try await StartupRangeRead.fetch(url: URL(string: "http://127.0.0.1:8797/ignore-range")!, headers: [:], offset: 0, count: 16)
                throw MediaError.message("忽略 Range 的响应被错误接受")
            } catch let error as URLError { try check(error.code == .badServerResponse, "network:range_ignored_refused_without_full_download") }
            playback.prepareAdjacent([extra], library: library)
            playback.cancelWarmup()
            try check(playback.warmupEvidence(extra, library: library).bytes == 0, "exit:unused_work_canceled")
            playback.close(); status = "相邻视频预加载验证通过"; save(true)
        } catch { playback.close(); status = "预加载验证失败：" + error.localizedDescription; save(false, error: error.localizedDescription) }
    }
}
#endif

#if DEBUG
struct FeedWarmupUIFixture: View {
    let library: LibraryStore
    @State private var ready = false
    @State private var server = MediaServer(name: "Glide Feed UI QA", kind: .jellyfin, address: URL(string: "http://127.0.0.1:8797")!, username: "fixture", userID: "fixture-user")
    private var videos: [Video] {
        ["cold", "direct", "extra"].map { Video(id: server.id.uuidString + $0, title: $0, subtitle: "原创测试队列", sourceID: server.id, remoteID: $0, duration: 18, mediaType: "Video") }
    }
    var body: some View {
        Group {
            if ready { PlayerView(library: library, queue: PlaybackQueue(videos: videos, mode: .sequential, startID: videos[0].id), scopeName: "原创滑动验证") }
            else { ProgressView("准备原创片库") }
        }.task {
            guard !ready else { return }
            do {
                try Credentials.save("authored-feed-only", for: server.id)
                library.servers.append(server); ready = true
            } catch { library.error = error.localizedDescription }
        }
    }
}
#endif
