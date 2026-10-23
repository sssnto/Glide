#if DEBUG
import SwiftUI
import AVFoundation

enum DualSubtitleFixtures {
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DualSubtitleFixture", isDirectory: true) }
    static let title = "双字幕原创验证"
    static var chinese: Data { SubtitleFixtures.srt("你好，世界。", "暂停定位仍然同步") }
    static var english: Data { Data("WEBVTT\n\n00:00.000 --> 00:04.000\nHello, world.\n\n00:04.000 --> 00:12.000\nPaused seek stays in sync.\n".utf8) }
    @MainActor static func prepare(_ library: LibraryStore) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Manual"), withIntermediateDirectories: true)
        for name in ["paired", "other/paired", "manual"] {
            let file = root.appendingPathComponent(name + ".mp4")
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file.path) { try fm.copyItem(at: Bundle.main.url(forResource: "demo0", withExtension: "mp4")!, to: file) }
        }
        for (name, data) in [("paired.zh-Hans.srt", chinese), ("paired.en.vtt", english), ("other/paired.zh-Hans.srt", SubtitleFixtures.srt("另一个目录的字幕")), ("other/paired.en.vtt", english), ("Manual/chinese.srt", chinese), ("Manual/english.vtt", english)] {
            try data.write(to: root.appendingPathComponent(name), options: .atomic)
        }
        UserDefaults.standard.set("videos", forKey: "homeBrowseView")
        if let server = library.servers.first(where: { $0.name == title && $0.kind == .local }) {
            UserDefaults.standard.removeObject(forKey: "localPath." + server.id.uuidString); await library.select(server.id)
        } else {
            try await library.mountLocalDirectory(root)
            if let i = library.servers.firstIndex(where: { $0.id == library.selectedID }) { library.servers[i].name = title; library.persist() }
        }
        if ProcessInfo.processInfo.arguments.contains("--glide-dual-subtitle-reset"), let id = library.selectedID { try SubtitleSource.store.remove(sourceID: id) }
    }
}

struct DualSubtitleQAProbe: View {
    let library: LibraryStore
    @State private var playback = PlaybackController()
    @State private var stage = "双字幕验证准备中"
    @State private var checks: [String] = []
    @State private var failure: String?
    @State private var seekSamples: [[String: Any]] = []
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(presentation: playback.presentation, onLayer: { playback.attachLayer($0) }, identity: playback.current?.id ?? "dual-qa", title: "Dual Subtitle QA", frameReady: playback.frameReady, locked: true, filled: false, onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in })
                PlayerSubtitleOverlay(playback: playback, cues: playback.subtitles.cues, delay: playback.subtitles.delay, bottomInset: geometry.size.height * 0.18, secondaryCues: playback.secondarySubtitles.cues, secondaryDelay: playback.secondarySubtitles.delay)
                VStack { Text(stage).accessibilityIdentifier("dual.probe.status"); Text("通过 \(checks.count) 项"); if let failure { Text(failure) }; Spacer() }.padding(36).foregroundStyle(.white)
            }
        }.task { await run() }.onDisappear { playback.close(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    @MainActor private func save(_ passed: Bool = false) throws {
        let object: [String: Any] = ["passed": passed, "checks": checks, "seekSamples": seekSamples, "events": playback.diagnostic.events, "stage": stage, "error": failure ?? "", "version": PlaybackPreferences.appVersion, "device": UIDevice.current.model, "os": UIDevice.current.systemVersion, "scope": "Production local native/VLC playback, paired external subtitle sessions and managed storage; authored media only", "timestamp": ISO8601DateFormatter().string(from: Date())]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: DualSubtitleFixtures.root.deletingLastPathComponent().appendingPathComponent("dual-subtitle-probe.json"), options: .atomic)
    }
    @MainActor private func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw MediaError.message(message) } }
    @MainActor private func record(_ name: String) throws { checks.append(name); try save() }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !condition() || playback.isSeeking {
            try Task.checkCancellation()
            if let error = playback.error { throw MediaError.message(error) }
            if ProcessInfo.processInfo.systemUptime > deadline { throw MediaError.message("等待超时：\(stage) · engine=\(playback.engineDescriptor.id.rawValue) frame=\(playback.frameReady) time=\(playback.time) seeking=\(playback.isSeeking) reading=\(playback.subtitles.reading)/\(playback.secondarySubtitles.reading)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    @MainActor private func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        let oldEngine = PlaybackPreferences.localEngine
        let defaults = UserDefaults.standard
        let oldLanguage = defaults.object(forKey: "preferredSubtitleLanguage"), oldForced = defaults.object(forKey: "forcedSubtitlesOnly")
        defer {
            PlaybackPreferences.localEngine = oldEngine
            if let oldLanguage { defaults.set(oldLanguage, forKey: "preferredSubtitleLanguage") } else { defaults.removeObject(forKey: "preferredSubtitleLanguage") }
            if let oldForced { defaults.set(oldForced, forKey: "forcedSubtitlesOnly") } else { defaults.removeObject(forKey: "forcedSubtitlesOnly") }
        }
        do {
            try await DualSubtitleFixtures.prepare(library)
            guard let server = library.selectedServer,
                  let pair = library.videos.first(where: { $0.localRelativePath == "paired.mp4" }),
                  let other = library.videos.first(where: { $0.localRelativePath == "other/paired.mp4" }),
                  let manual = library.videos.first(where: { $0.localRelativePath == "manual.mp4" }) else { throw MediaError.message("原创素材目录不完整") }
            try SubtitleSource.store.remove(sourceID: server.id)
            defaults.set("zh", forKey: "preferredSubtitleLanguage"); defaults.set(false, forKey: "forcedSubtitlesOnly")
            playback.open(pair, library: library, autoplay: false)
            try await wait { playback.frameReady && !playback.subtitles.discovering && !playback.secondarySubtitles.discovering }
            try require(!playback.subtitles.cues.isEmpty && playback.secondarySubtitles.cues.isEmpty, "第二字幕不应自动重复匹配主字幕")
            playback.close(); defaults.set("", forKey: "preferredSubtitleLanguage")
            try record("default:secondary-off-preserves-primary-auto-match")
            for engine in [PlaybackEngineID.avPlayer, .vlc] {
                let tolerance = engine == .vlc ? 0.8 : 0.4
                stage = "验证 \(engine.rawValue) 双字幕"
                PlaybackPreferences.localEngine = engine
                stage = "\(engine.rawValue) 首帧与记忆"
                playback.open(pair, library: library, autoplay: false)
                try await wait { playback.frameReady && !playback.subtitles.discovering && !playback.secondarySubtitles.discovering }
                try require(playback.engineDescriptor.id == engine, "播放器内核未匹配")
                let first = playback.subtitles, second = playback.secondarySubtitles
                guard let zh = first.candidates.first(where: { $0.name.hasSuffix("zh-Hans.srt") }), let en = second.candidates.first(where: { $0.name.hasSuffix("en.vtt") }) else { throw MediaError.message("双语候选不完整") }
                stage = "\(engine.rawValue) 读取两路候选"
                first.choose(zh); second.choose(en)
                try await wait { !first.reading && !second.reading && !first.cues.isEmpty && !second.cues.isEmpty }
                first.setDelay(0); second.setDelay(0)
                stage = "\(engine.rawValue) 暂停定位 1 秒"
                playback.seek(1); try await wait { abs(playback.time - 1) < tolerance }
                seekSamples.append(["engine": engine.rawValue, "target": 1, "actual": playback.time, "tolerance": tolerance])
                try require(SubtitleCue.visible(first.cues, time: playback.time, delay: first.delay) == "你好，世界。" && SubtitleCue.visible(second.cues, time: playback.time, delay: second.delay) == "Hello, world.", "两路字幕没有使用同一时钟")
                try record("playback:\(engine.rawValue)-two-external-tracks-frame-and-paused-seek")
                first.setDelay(2); second.setDelay(-1)
                stage = "\(engine.rawValue) 连续暂停定位 4.5 秒"
                playback.seek(4.5); try await wait { abs(playback.time - 4.5) < tolerance }
                seekSamples.append(["engine": engine.rawValue, "target": 4.5, "actual": playback.time, "tolerance": tolerance])
                try require(!playback.isPlaybackRequested && SubtitleCue.visible(first.cues, time: playback.time, delay: first.delay) == "你好，世界。" && SubtitleCue.visible(second.cues, time: playback.time, delay: second.delay) == "Paused seek stays in sync.", "独立正负偏移或暂停意图错误")
                try record("clock:\(engine.rawValue)-independent-positive-negative-offsets")
                stage = "\(engine.rawValue) 往返暂停定位"
                for target in [2.0, 7.0, 2.0, 7.0] {
                    playback.seek(target); try await wait { abs(playback.time - target) < tolerance && !playback.isPlaying }
                    seekSamples.append(["engine": engine.rawValue, "target": target, "actual": playback.time, "tolerance": tolerance, "repeatedPausedSeek": true, "paused": !playback.isPlaying])
                    try require(!playback.isPlaybackRequested, "往返定位后丢失暂停意图")
                }
                try record("clock:\(engine.rawValue)-repeated-forward-backward-paused-seeks")
                first.setDelay(0); second.setDelay(0); playback.seek(1); try await wait { abs(playback.time - 1) < tolerance }
                playback.setRate(2); playback.toggle(); try await wait { playback.time > 3 }; playback.pause()
                try require(playback.rate == 2 && !playback.isPlaybackRequested, "倍速暂停意图错误")
                try record("clock:\(engine.rawValue)-double-speed-shared-clock")
                first.setDelay(0.3); second.setDelay(-0.7)
                playback.close(); playback.open(pair, library: library, autoplay: false)
                try await wait { playback.frameReady && !first.discovering && !second.discovering && !first.cues.isEmpty && !second.cues.isEmpty }
                try require(abs(first.delay - 0.3) < 0.001 && abs(second.delay + 0.7) < 0.001 && first.activeName == zh.name && second.activeName == en.name, "两路记忆未独立恢复")
                try record("memory:\(engine.rawValue)-reopen-choices-and-offsets")
                second.selectEmbedded(nil, engine: engine)
                playback.close(); playback.open(pair, library: library, autoplay: false)
                try await wait { !first.discovering && !second.discovering && !first.cues.isEmpty }
                try require(second.choice == .off && second.cues.isEmpty && abs(first.delay - 0.3) < 0.001, "关闭第二字幕影响主字幕")
                try record("memory:\(engine.rawValue)-secondary-off-reopen-primary-retained")
                playback.close()
            }
            stage = "验证导入副本与独立恢复"
            let first = playback.subtitles, second = playback.secondarySubtitles
            playback.open(manual, library: library, autoplay: false)
            try await wait { playback.frameReady && !first.discovering && !second.discovering }
            let mainFile = DualSubtitleFixtures.root.appendingPathComponent("Manual/chinese.srt"), secondaryFile = DualSubtitleFixtures.root.appendingPathComponent("Manual/english.vtt")
            first.importFile(mainFile); second.importFile(secondaryFile)
            try await wait { !first.reading && !second.reading && !first.cues.isEmpty && !second.cues.isEmpty }
            try FileManager.default.removeItem(at: mainFile); try FileManager.default.removeItem(at: secondaryFile)
            playback.close(); playback.open(manual, library: library, autoplay: false)
            try await wait { playback.frameReady && !first.discovering && !second.discovering && !first.cues.isEmpty && !second.cues.isEmpty }
            try require(first.importedCopy != nil && second.importedCopy != nil, "两路导入副本未保留")
            playback.closeExternalSubtitles(); first.useImportedCopy(); second.useImportedCopy()
            try await wait { !first.reading && !second.reading && !first.cues.isEmpty && !second.cues.isEmpty }
            try record("imports:two-managed-copies-off-reenable-originals-deleted")
            stage = "验证文件变化与取消隔离"
            playback.close(); playback.open(pair, library: library, autoplay: false)
            try await wait { !first.discovering && !second.discovering }
            let enFile = DualSubtitleFixtures.root.appendingPathComponent("paired.en.vtt")
            second.choose(second.candidates.first { $0.name.hasSuffix("en.vtt") }!); try await wait { !second.reading && !second.cues.isEmpty }
            try SubtitleFixtures.srt("changed").write(to: enFile)
            playback.close(); playback.open(pair, library: library, autoplay: false)
            try await wait { !first.discovering && !second.discovering }
            try require(!first.cues.isEmpty && second.cues.isEmpty && second.message?.contains("变化") == true, "第二字幕失效覆盖了主字幕")
            try DualSubtitleFixtures.english.write(to: enFile)
            try record("invalidated:secondary-content-change-keeps-primary")
            second.choose(second.candidates.first { $0.name.hasSuffix("en.vtt") }!); try await wait { !second.reading && !second.cues.isEmpty }
            let mediaFile = DualSubtitleFixtures.root.appendingPathComponent("paired.mp4")
            let oldDate = try mediaFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
            playback.close()
            try FileManager.default.setAttributes([.modificationDate: oldDate.addingTimeInterval(10)], ofItemAtPath: mediaFile.path)
            playback.open(pair, library: library, autoplay: false)
            try await wait { !first.discovering && !second.discovering }
            try require(first.cues.isEmpty && second.cues.isEmpty && first.message?.contains("视频文件已变化") == true && second.message?.contains("视频文件已变化") == true, "视频变化后仍恢复旧双字幕")
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: mediaFile.path)
            try record("invalidated:media-revision-suspends-both-lanes")

            try DualSubtitleFixtures.chinese.write(to: mainFile)
            first.importFile(mainFile)
            await Task.yield()
            second.prepare(video: pair, server: server); second.choose(second.candidates.first ?? SidecarSubtitle(url: enFile, name: "paired.en.vtt", language: "en", forced: false))
            playback.close(); playback.open(other, library: library, autoplay: false)
            try await wait { playback.frameReady && !first.discovering && !second.discovering }
            try await Task.sleep(for: .milliseconds(400))
            try require(first.activeName != "paired.zh-Hans.srt" && second.cues.isEmpty, "旧视频回调覆盖了新视频")
            try record("cancel:both-lanes-old-import-or-discovery-cannot-overwrite-new-video")
            first.choose(first.candidates.first { $0.name.hasSuffix("zh-Hans.srt") }!); second.choose(second.candidates.first { $0.name.hasSuffix("en.vtt") }!)
            try await wait { !first.reading && !second.reading && !first.cues.isEmpty && !second.cues.isEmpty }
            let beforeClear = try SubtitleSource.store.load().value
            try require(beforeClear.values.filter { $0.videoID == other.id }.count == 2, "清除前两路记忆未保存")
            playback.forgetSubtitles()
            let memory = try SubtitleSource.store.load().value
            try require(!memory.values.contains(where: { $0.videoID == other.id }), "清除遗漏了第二字幕记忆")
            try record("cleanup:clear-both-lanes-for-current-video")
            playback.close(); PlaybackPreferences.localEngine = .avPlayer
            playback.open(pair, library: library, autoplay: false)
            try await wait { playback.frameReady && !first.discovering && !second.discovering }
            first.choose(first.candidates.first { $0.name.hasSuffix("zh-Hans.srt") }!); second.choose(second.candidates.first { $0.name.hasSuffix("en.vtt") }!)
            try await wait { !first.reading && !second.reading && !first.cues.isEmpty && !second.cues.isEmpty }
            first.setDelay(0); second.setDelay(0); playback.seek(1); try await wait { abs(playback.time - 1) < 0.4 }
            stage = "双字幕验证通过"; try save(true)
        } catch { failure = error.localizedDescription; stage = "双字幕验证未完成"; playback.close(); try? save() }
    }
}
#endif
