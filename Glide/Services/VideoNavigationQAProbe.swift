#if DEBUG
import SwiftUI

/// Original bundled media, an isolated moment store and the production decoder.
struct VideoNavigationQAProbe: View {
    var library: LibraryStore
    @State private var playback = PlaybackController()
    @State private var session = VideoNavigationSession()
    @State private var checks: [String] = []
    @State private var stage = "内容地图验证准备中"
    @State private var failure: String?
    @State private var evidence: [String: Double] = [:]
    @State private var video = Video(id: "navigation-qa-demo", title: "原创画面导航验证", subtitle: "", demoIndex: 0)
    private let expected = 14
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VideoSurface(presentation: playback.presentation, onLayer: { playback.attachLayer($0) }, identity: video.id, title: video.title,
                         frameReady: playback.frameReady, locked: true, filled: false,
                         onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in })
            VStack { Text(stage).accessibilityIdentifier("map.probe.status"); Text("通过 \(checks.count) 项").accessibilityIdentifier("map.probe.count"); if let failure { Text(failure) } }
                .font(.caption).foregroundStyle(.white).padding(30).allowsHitTesting(false)
        }.task { await run() }
            .onChange(of: playback.frameReady) { _, _ in mute() }
            .onDisappear { playback.close(); session.cancel(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func mute() { if case .native(let player) = playback.presentation { player.isMuted = true } }
    private func record(_ passed: Bool, _ name: String) throws { guard passed else { throw MediaError.message(name) }; checks.append(name) }
    private func waitFor(_ condition: () -> Bool, timeout: Double = 15) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { mute(); try await Task.sleep(for: .milliseconds(80)) }
        guard condition() else { throw MediaError.message(playback.error ?? "等待真实播放超时") }
    }
    private func save(_ passed: Bool) {
        let report: [String: Any] = ["passed": passed, "checks": checks, "expectedChecks": expected, "stage": stage, "error": failure ?? "", "measurements": evidence,
            "version": PlaybackPreferences.appVersion, "system": UIDevice.current.systemVersion,
            "timestamp": ISO8601DateFormatter().string(from: Date()), "scope": "Authored bundled MP4, production map frame generator/cache, isolated recoverable moment store, actual PlaybackController/decoder seeking and changed-revision rejection; no private servers or watch progress"]
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("video-navigation-qa-report.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: file, options: .atomic) }
    }
    @MainActor private func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NavigationQA-" + UUID().uuidString)
        defer { playback.close(); session.cancel(); try? FileManager.default.removeItem(at: root) }
        do {
            guard let url = Bundle.main.url(forResource: "demo0", withExtension: "mp4") else { throw MediaError.message("原创素材缺失") }
            video.url = url
            let resource = PlaybackResource(url: url, delivery: .local)
            let reference = try await MomentResolver.reference(video: video, library: library, resource: resource)
            try record(reference.kind == .demo, "identity:stable-authored-source")
            await session.prepare(video: video, library: library, resource: resource, duration: 12)
            try record(session.ready && session.hasMap, "map:actual-local-asset-ready")
            let overview = ContentMapPlan.segments(duration: 12)
            try record(overview.count == 12 && overview.last?.end == 12, "map:bounded-whole-video-plan")
            let fine = ContentMapPlan.segments(duration: 12, range: overview[4])
            try record(!fine.isEmpty && fine.allSatisfy { $0.start >= 4 && $0.end <= 5 }, "map:refinement-remains-in-selected-window")
            stage = "实际取图与缓存验证"; save(false)
            let start = ProcessInfo.processInfo.systemUptime
            let frame = try await session.frame(at: 6)
            evidence["firstFrameGenerationSeconds"] = ProcessInfo.processInfo.systemUptime - start
            evidence["actualFrameTime"] = frame.time
            try record(frame.image.size.width > 0 && abs(frame.time - 6) <= 0.3, "map:actual-image-and-labelled-time")
            let cached = try await session.frame(at: 6)
            try record(cached.time == frame.time && cached.image.size == frame.image.size, "cache:actual-time-preserved-on-reload")
            let store = MomentStore(file: root.appendingPathComponent("moments.json"))
            var moment = try MediaMoment(video: video, reference: reference, position: 6, duration: 12, name: "原创六秒时刻").validated()
            try store.save(moment)
            try record(MomentStore(file: root.appendingPathComponent("moments.json")).moments.first == moment, "moments:save-and-reload")
            moment.name = "重命名时刻"; try store.save(moment)
            try record(store.moments.count == 1 && store.moments.first?.id == moment.id, "moments:rename-preserves-identity")
            video = try MomentResolver.resolve(moment, library: library)
            try record(video.url?.isFileURL == true, "moments:resolve-from-stable-identity")
            stage = "真实播放器恢复收藏时间点"; save(false)
            playback.pendingMomentReference = reference
            playback.open(video, library: library, resumeAt: moment.position, recordsProgress: false)
            try await waitFor { playback.frameReady && playback.time >= 5.5 }
            playback.pause(); evidence["actualResumeTime"] = playback.navigationPosition ?? -1
            try record((playback.navigationPosition ?? -1) >= 5.5 && (playback.navigationPosition ?? 99) < 8, "player:actual-frame-at-saved-position-without-history")
            playback.seek(2)
            try await waitFor { playback.navigationPosition != nil && abs((playback.navigationPosition ?? -100) - 2) <= 0.6 }
            evidence["actualSeekTime"] = playback.navigationPosition
            try record(abs((playback.navigationPosition ?? -100) - 2) <= 0.6 && playback.error == nil, "player:map-time-uses-real-seek")
            playback.close()
            var changed = reference; changed.revision = "changed-revision"
            playback.pendingMomentReference = changed
            playback.open(video, library: library, resumeAt: moment.position, recordsProgress: false)
            try await waitFor { playback.error != nil }
            try record(!playback.frameReady && playback.error?.contains("版本已变化") == true, "player:changed-file-blocked-before-first-frame")
            try store.remove(moment.id)
            try record(store.moments.isEmpty && FileManager.default.fileExists(atPath: url.path), "moments:delete-keeps-original-video")
            try record(library.servers.allSatisfy { $0.name != "NavigationQA" }, "privacy:no-test-server-or-personal-history-created")
            stage = "内容地图与时刻验证通过"; save(checks.count == expected)
        } catch { failure = error.localizedDescription; stage = "内容地图验证未完成"; save(false) }
    }
}
#endif
