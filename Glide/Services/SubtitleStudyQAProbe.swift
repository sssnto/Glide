#if DEBUG
import SwiftUI

struct SubtitleStudyQAProbe: View {
    let library: LibraryStore
    @State private var playback = PlaybackController()
    @State private var stage = "字幕导航验证准备中"
    @State private var checks: [String] = []
    @State private var samples: [[String: Any]] = []
    @State private var failure: String?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(presentation: playback.presentation, onLayer: { playback.attachLayer($0) }, identity: playback.current?.id ?? "study-qa", title: "Subtitle Study QA", frameReady: playback.frameReady, locked: true, filled: false, onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in })
                PlayerSubtitleOverlay(playback: playback, cues: playback.subtitles.cues, delay: playback.subtitles.delay, bottomInset: geometry.size.height * 0.18, secondaryCues: playback.secondarySubtitles.cues, secondaryDelay: playback.secondarySubtitles.delay)
                VStack { Text(stage).accessibilityIdentifier("study.probe.status"); Text("通过 \(checks.count) 项"); if let failure { Text(failure) }; Spacer() }.padding(36).foregroundStyle(.white)
            }
        }.task { await run() }.onDisappear { playback.close(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    @MainActor private func save(_ passed: Bool = false) throws {
        let object: [String: Any] = ["passed": passed, "checks": checks, "samples": samples, "error": failure ?? "", "stage": stage, "events": playback.diagnostic.events, "duration": playback.duration, "requestedPlaying": playback.isPlaybackRequested, "playing": playback.isPlaying, "clock": playback.qaLoopClock,
            "version": PlaybackPreferences.appVersion, "device": UIDevice.current.model, "os": UIDevice.current.systemVersion,
            "scope": "Real local AVPlayer/VLC with production subtitle navigation, sentence replay and A-B loop controller; authored media; no decoder substitution",
            "timestamp": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted,.sortedKeys]).write(to: DualSubtitleFixtures.root.deletingLastPathComponent().appendingPathComponent("subtitle-study-probe.json"), options: .atomic)
    }
    @MainActor private func require(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw MediaError.message(message) } }
    @MainActor private func record(_ name: String) throws { checks.append(name); try save() }
    @MainActor private func sample(_ engine: PlaybackEngineID, _ name: String, target: Double? = nil) {
        var value: [String: Any] = ["engine": engine.rawValue, "name": name, "actual": playback.time, "playing": playback.isPlaying, "requestedPlaying": playback.isPlaybackRequested, "loops": playback.loopCount, "completed": playback.completedCount, "rate": playback.rate]
        if let target { value["target"] = target }; samples.append(value)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while !condition() {
            try Task.checkCancellation()
            if let error = playback.error { throw MediaError.message(error) }
            if ProcessInfo.processInfo.systemUptime > deadline { throw MediaError.message("等待超时：\(stage)，time=\(playback.time)，seeking=\(playback.isSeeking)，loop=\(playback.loopCount)，message=\(playback.loopMessage ?? "")") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    @MainActor private func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        let oldEngine = PlaybackPreferences.localEngine
        let defaults = UserDefaults.standard, oldLanguage = UserDefaults.standard.object(forKey: "preferredSubtitleLanguage")
        defer { PlaybackPreferences.localEngine = oldEngine; if let oldLanguage { defaults.set(oldLanguage, forKey: "preferredSubtitleLanguage") } else { defaults.removeObject(forKey: "preferredSubtitleLanguage") } }
        do {
            try await DualSubtitleFixtures.prepare(library)
            guard let server = library.selectedServer, let pair = library.videos.first(where: { $0.localRelativePath == "paired.mp4" }), let other = library.videos.first(where: { $0.localRelativePath == "other/paired.mp4" }) else { throw MediaError.message("原创样例缺失") }
            try SubtitleSource.store.remove(sourceID: server.id)
            defaults.set("zh", forKey: "preferredSubtitleLanguage")
            for engine in [PlaybackEngineID.avPlayer, .vlc] {
                playback.close(); playback = PlaybackController()
                PlaybackPreferences.localEngine = engine
                stage = "\(engine.rawValue) 首帧与主字幕"
                playback.open(pair, library: library, autoplay: false)
                try await wait { playback.frameReady && !playback.subtitles.discovering && !playback.subtitles.cues.isEmpty }
                try require(playback.engineDescriptor.id == engine, "内核不一致")
                let first = playback.subtitles.cues[0]
                playback.subtitles.setDelay(0.75)
                stage = "\(engine.rawValue) 偏移台词定位"
                playback.seekToSubtitle(first)
                try await wait { !playback.isSeeking && abs(playback.time - 0.75) < (engine == .vlc ? 0.8 : 0.4) && !playback.isPlaying }
                sample(engine, "delay-aware-navigation", target: 0.75); try record("\(engine.rawValue):subtitle-navigation-includes-positive-delay-and-pause")
                stage = "\(engine.rawValue) 单句重播"
                try require(playback.replaySubtitle(first), "未开启单句重播")
                try await wait { playback.loop == nil && !playback.isSeeking && !playback.isPlaybackRequested && !playback.isPlaying }
                try require(abs(playback.time - 4.75) < 0.8 && playback.completedCount == 0, "句尾没有暂停或误切下一条")
                sample(engine, "sentence-stopped", target: 4.75); try record("\(engine.rawValue):sentence-replay-stops-at-shifted-end")
                stage = "\(engine.rawValue) 倍速连续循环"
                playback.setRate(2)
                try require(playback.setLoop(start: 2, end: 3.5), "未开启循环")
                try await wait { playback.loopCount >= 3 && !playback.isSeeking }
                try require(playback.loop != nil && playback.rate == 2 && playback.isPlaybackRequested && playback.completedCount == 0, "循环、倍速或队列意图错误")
                sample(engine, "three-repeat-boundaries"); try record("\(engine.rawValue):three-ab-repeats-at-double-speed-no-next-video")
                playback.pause(); try await wait { !playback.isSeeking && !playback.isPlaying }
                let count = playback.loopCount, pausedTime = playback.time
                try await Task.sleep(for: .seconds(1))
                try require(playback.loopCount == count && abs(playback.time - pausedTime) < 0.5, "暂停时仍循环")
                try record("\(engine.rawValue):pause-freezes-loop")
                playback.seek(8); try await wait { !playback.isSeeking && abs(playback.time - 8) < 0.8 }
                try require(playback.loop == nil && playback.loopStart == nil && !playback.isPlaybackRequested, "手动越界未退出循环")
                try record("\(engine.rawValue):outside-seek-exits-loop-preserving-pause")
                stage = "\(engine.rawValue) A/B 标记与区间内定位"
                playback.seek(2); try await wait { !playback.isSeeking && abs(playback.time - 2) < 0.8 }
                playback.markLoopStart()
                playback.seek(1); try await wait { !playback.isSeeking && abs(playback.time - 1) < 0.8 }
                playback.markLoopEnd(); try require(playback.loop == nil && playback.loopStart != nil, "无效 B 不应开启循环")
                try require(playback.setLoop(start: 2, end: 8), "无法开始有效区间")
                try await wait { !playback.isSeeking }; playback.pause(); playback.seek(5)
                try await wait { !playback.isSeeking && abs(playback.time - 5) < 0.8 }
                try require(playback.loop != nil && !playback.isPlaybackRequested, "区间内手动定位不应退出")
                try record("\(engine.rawValue):invalid-b-rejected-and-inside-seek-retains-loop")
                stage = "\(engine.rawValue) 同片内核切换保留区间"
                let alternate: PlaybackEngineID = engine == .avPlayer ? .vlc : .avPlayer
                playback.switchEngine(to: alternate)
                try await wait { playback.engineDescriptor.id == alternate && playback.frameReady && !playback.isSeeking }
                try require(playback.loop?.start == 2 && playback.loop?.end == 8 && !playback.isPlaybackRequested, "同片切内核丢失区间或暂停意图")
                playback.switchEngine(to: engine)
                try await wait { playback.engineDescriptor.id == engine && playback.frameReady && !playback.isSeeking }
                try record("\(engine.rawValue):same-video-engine-switch-preserves-loop-and-pause")
                stage = "\(engine.rawValue) 片尾与跳过优先级"
                playback.setRate(1)
                var rule = PlaybackSkipRule(); rule.automatic = true; rule.outro = 3
                try playback.skips.save(rule, series: false, duration: playback.duration)
                try require(playback.setLoop(start: 10, end: playback.duration), "无法设置片尾循环")
                try await wait { playback.loopCount >= 2 && !playback.isSeeking }
                try require(playback.completedCount == 0 && playback.activeSkip == nil && playback.loop != nil, "片尾循环被自动跳过或下一条打断")
                sample(engine, "tail-loop-priority"); playback.pause(); playback.clearLoop(); try playback.skips.clear()
                try record("\(engine.rawValue):tail-loop-overrides-auto-outro-and-next")
                stage = "\(engine.rawValue) 切片清理"
                try require(playback.setLoop(start: 2, end: 4), "切片前循环未开启")
                playback.open(other, library: library, autoplay: false)
                try await wait { playback.frameReady && !playback.isSeeking }
                try require(playback.loop == nil && playback.loopStart == nil && playback.loopCount == 0, "跨视频遗留循环")
                try record("\(engine.rawValue):video-switch-clears-range-and-count")
                playback.close()
            }
            stage = "验证关闭后的状态"
            try require(playback.loop == nil && playback.loopStart == nil, "关闭时循环未清理")
            try record("lifecycle:close-clears-loop")
            stage = "字幕导航验证通过"; try save(true)
        } catch { failure = error.localizedDescription; stage = "字幕导航验证未完成"; try? save(); playback.close() }
    }
}
#endif
