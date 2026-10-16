#if DEBUG
import SwiftUI

/// Device-side production-controller checks when the host XCTest service is unavailable.
/// Reads only authored fixtures in this QA app's fixed sandbox directory.
struct CompatibilityQAProbe: View {
    let library: LibraryStore
    @State private var playback = PlaybackController()
    @State private var stage = "准备主应用验证"
    @State private var results: [String] = []
    @State private var measurements: [String: Double] = [:]
    @State private var finished = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(presentation: playback.presentation, onLayer: { playback.attachLayer($0) },
                identity: playback.current?.id ?? "probe", title: playback.current?.title ?? "QA",
                frameReady: playback.frameReady, locked: true, filled: false,
                onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in })
            VStack {
                Text("Glide 兼容验证").font(.headline)
                Text(stage).font(.caption).multilineTextAlignment(.center)
                Text("已完成 \(results.count) 项").font(.caption.monospacedDigit())
                Spacer()
                Text(playback.time.mediaTime + " / " + playback.duration.mediaTime).font(.caption.monospacedDigit())
            }.padding(32).foregroundStyle(.white)
        }.task { await run() }
            .onDisappear { playback.stop(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    @MainActor private func wait(_ description: String, seconds: Double = 20, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime > deadline { throw MediaError.message(description + "超时；状态：" + playback.currentState) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    @MainActor private func open(_ name: String, engine: PlaybackEngineID) throws {
        guard let video = library.videos.first(where: { $0.title == name }) else { throw MediaError.message("缺少原创样例：" + name) }
        playback.stop()
        playback = PlaybackController()
        PlaybackPreferences.localEngine = engine
        stage = name + " · " + engine.rawValue
        playback.open(video, library: library, autoplay: true, recordsProgress: false)
    }
    @MainActor private func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw MediaError.message(description) }
    }
    @MainActor private func record(_ name: String) throws {
        results.append(name)
        try save(passed: false, error: nil)
    }
    @MainActor private func save(passed: Bool, error: String?) throws {
        let value: [String: Any] = ["version": PlaybackPreferences.appVersion, "passed": passed,
            "completed": finished, "checks": results, "measurements": measurements, "stage": stage, "error": error ?? "",
            "device": UIDevice.current.model, "os": UIDevice.current.systemVersion,
            "scope": "Main PlaybackController and production VideoSurface on authored local fixtures; no XCTest/settings gestures",
            "runtime": "MobileVLCKit 3.7.3", "timestamp": ISO8601DateFormatter().string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try data.write(to: root.appendingPathComponent("compatibility-main-probe.json"), options: .atomic)
    }
    @MainActor private func run() async {
        guard !finished else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        let previous = PlaybackPreferences.localEngine
        defer { PlaybackPreferences.localEngine = previous }
        do {
            try await library.prepareFormatFixtures()
            for name in ["03-h264-aac.mkv", "04-mpeg4-mp3.avi", "05-renamed-mkv.mp4"] {
                try open(name, engine: .vlc)
                try await wait("本地兼容首帧") { playback.frameReady }
                playback.pause()
                try check(playback.engineDescriptor.id == .vlc, "本地内核选择错误")
                try check(!playback.engineDescriptor.capabilities.contains(.pictureInPicture), "兼容能力声明错误")
                try record("frame:" + name)
            }
            try open("11-hd-dual-ass.mkv", engine: .vlc)
            try await wait("1080p 首帧") { playback.frameReady }
            playback.pause(); playback.seek(30)
            try await wait("1080p 暂停定位") { abs(playback.time - 30) < 0.8 }
            try await Task.sleep(for: .seconds(1))
            try check(!playback.isPlaying && abs(playback.time - 30) < 0.8, "暂停定位未保持")
            measurements["paused1080pTime"] = playback.time
            try await wait("双音轨") { playback.audioOptions.count == 2 }
            playback.selectAudio(playback.audioOptions[1])
            try await wait("选择音轨") { playback.selectedAudio == playback.audioOptions[1] }
            guard let subtitle = playback.subtitleOptions.first else { throw MediaError.message("缺少 ASS 轨道") }
            playback.selectSubtitle(subtitle)
            try await wait("选择 ASS") { playback.selectedSubtitle == subtitle }
            playback.selectSubtitle(nil)
            try await wait("关闭 ASS") { playback.selectedSubtitle == nil }
            playback.setRate(2); playback.toggle()
            try await wait("2× 时钟") { playback.time >= 33 && playback.time < 45 }
            measurements["resumed1080pTime"] = playback.time
            playback.pause()
            try record("1080p:seek-pause-audio-subtitle-rate")

            try open("08-multi-track.mp4", engine: .avPlayer)
            try await wait("系统首帧") { playback.frameReady }
            playback.pause(); playback.seek(4)
            try await wait("系统定位") { abs(playback.time - 4) < 0.5 }
            playback.switchEngine(to: .vlc)
            try await wait("暂停切换到兼容") { playback.frameReady && abs(playback.time - 4) < 1 && !playback.isPlaying }
            measurements["switchedVLCTime"] = playback.time
            try check(!playback.isPlaying, "兼容切换后意外播放")
            playback.switchEngine(to: .avPlayer)
            try await wait("暂停切回系统") { playback.frameReady && abs(playback.time - 4) < 1 && !playback.isPlaying }
            measurements["switchedNativeTime"] = playback.time
            try check(!playback.isPlaying, "系统切换后意外播放")
            try record("switch:paused-position-roundtrip")

            try open("03-h264-aac.mkv", engine: .avPlayer)
            try await wait("系统失败提示") { playback.error != nil }
            playback.switchEngine(to: .vlc)
            try await wait("失败后兼容重试") { playback.frameReady && playback.error == nil }
            try record("retry:native-failure-to-vlc")
            playback.stop()
            finished = true; stage = "主应用控制器验证通过"
            try save(passed: true, error: nil)
        } catch {
            playback.stop(); finished = true; stage = "验证未通过"
            try? save(passed: false, error: error.localizedDescription)
        }
    }
}
#endif
