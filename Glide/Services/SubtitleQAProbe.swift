#if DEBUG
import SwiftUI

enum SubtitleFixtures {
    static let title = "字幕验证样例"
    static var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SubtitleFixture", isDirectory: true) }
    static func srt(_ first: String, _ second: String? = nil) -> Data {
        Data("1\n00:00:00,000 --> 00:00:04,000\n\(first)\n\n2\n00:00:04,000 --> 00:00:12,000\n\(second ?? first)\n".utf8)
    }
    @MainActor static func prepare(_ library: LibraryStore) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Manual"), withIntermediateDirectories: true)
        for name in ["auto", "multi", "import", "change", "家庭甲/相同", "家庭乙/相同"] {
            let file = root.appendingPathComponent(name + ".mp4")
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: file.path) { try manager.copyItem(at: Bundle.main.url(forResource: "demo0", withExtension: "mp4")!, to: file) }
        }
        for (name, data) in [
            ("auto.srt", srt("自动匹配中文字幕", "暂停拖动字幕时钟")),
            ("multi.zh-Hans.srt", srt("选择简体中文字幕")),
            ("multi.en.vtt", Data("WEBVTT\n\n00:00.000 --> 00:12.000\nEnglish sidecar\n".utf8)),
            ("change.srt", srt("原始字幕内容")),
            ("家庭甲/相同.srt", srt("家庭甲的字幕")),
            ("家庭乙/相同.srt", srt("家庭乙的字幕")),
            ("Manual/selected.srt", srt("手动导入保留副本"))
        ] { let file = root.appendingPathComponent(name); if !manager.fileExists(atPath: file.path) { try data.write(to: file) } }
        if ProcessInfo.processInfo.arguments.contains("--glide-ass-fixture") {
            let file = root.appendingPathComponent("ass-fallback.mp4")
            if !manager.fileExists(atPath: file.path) { try manager.copyItem(at: Bundle.main.url(forResource: "demo0", withExtension: "mp4")!, to: file) }
            let first = #"{\fnOriginalFont\fs20\bord2\blur3\1c&HC8C8BF\shad1\b1}原创中文测试{\r}\N{\fnOriginalFont\fs14\bord2\1c&H3DA8DB&\b1}Original bilingual caption.{\r}"#
            let second = #"{\p1}m 0 0 l 100 100{\p0}{\b1}第二句字幕{\r}\NSecond caption."#
            try srt(first, second).write(to: root.appendingPathComponent("ass-fallback.srt"), options: .atomic)
        }
        if ProcessInfo.processInfo.arguments.contains("--glide-ass-style-fixture") {
            let report: [String: Any]
            do { report = try await ASSStyleQA.validate() }
            catch { report = ["passed": false, "error": error.localizedDescription] }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.deletingLastPathComponent().appendingPathComponent("ass-style-probe.json"), options: .atomic)
            let file = root.appendingPathComponent("ass-style.mp4")
            if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
            try manager.copyItem(at: Bundle.main.url(forResource: "ass-style-qa", withExtension: "mp4")!, to: file)
            try Data(ASSStyleQA.script.utf8).write(to: root.appendingPathComponent("ass-style.ass"), options: .atomic)
        }
        UserDefaults.standard.set("videos", forKey: "homeBrowseView")
        UserDefaults.standard.set("sequential", forKey: "playbackMode")
        if let server = library.servers.first(where: { $0.name == title && $0.kind == .local }) {
            UserDefaults.standard.removeObject(forKey: "localPath." + server.id.uuidString)
            await library.select(server.id)
        } else {
            try await library.mountLocalDirectory(root)
            if let i = library.servers.firstIndex(where: { $0.id == library.selectedID }) { library.servers[i].name = title; library.persist() }
        }
        if ProcessInfo.processInfo.arguments.contains("--glide-subtitle-reset"), let id = library.selectedID { try SubtitleSource.store.remove(sourceID: id) }
    }
    @MainActor static func prepareSMB(_ library: LibraryStore) async throws {
        let address = try SMBLocation.parse(address: UserDefaults.standard.string(forKey: "glideSMBFixtureAddress") ?? "127.0.0.1:1445", share: "media/字幕样例")
        if let existing = library.servers.first(where: { $0.name == "SMB 字幕验证" && $0.address == address }) {
            try Credentials.save("glide150-fixture", for: existing.id)
            await library.select(existing.id)
        } else { try await library.add(name: "SMB 字幕验证", kind: .smb, address: address.absoluteString, username: "glide", password: "glide150-fixture") }
        if ProcessInfo.processInfo.arguments.contains("--glide-subtitle-reset"), let id = library.selectedID { try SubtitleSource.store.remove(sourceID: id) }
    }
}

struct SubtitleQAProbe: View {
    let library: LibraryStore
    @State private var playback = PlaybackController()
    @State private var stage = "字幕验证准备中"
    @State private var checks: [String] = []
    @State private var failure: String?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(presentation: playback.presentation, onLayer: { playback.attachLayer($0) }, identity: playback.current?.id ?? "subtitle-qa", title: "Subtitle QA", frameReady: playback.frameReady, locked: true, filled: false, onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in }, subtitleSession: playback.subtitles, secondarySubtitleSession: playback.secondarySubtitles,
                subtitleClock: { playback.subtitleRenderTime }, subtitleVideoMatrix: playback.subtitleVideoMatrix, subtitleSourceSize: playback.subtitleVideoSize)
                PlayerSubtitleOverlay(playback: playback, cues: playback.subtitles.overlayCues, delay: playback.subtitles.delay, bottomInset: geometry.size.height * 0.18)
                VStack { Text(stage).accessibilityIdentifier("subtitle.probe.status"); Text("通过 \(checks.count) 项"); if let failure { Text(failure) }; Spacer() }.foregroundStyle(.white).padding(36)
            }
        }.task { await run() }.onDisappear { playback.close(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    @MainActor private func save(passed: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "stage": stage, "error": failure ?? "", "version": PlaybackPreferences.appVersion, "device": UIDevice.current.model, "os": UIDevice.current.systemVersion, "scope": ProcessInfo.processInfo.arguments.contains("--glide-subtitle-smb-probe") ? "Production local/native/VLC and authored Samba subtitle flows" : "Production local/native/VLC subtitle flows", "timestamp": ISO8601DateFormatter().string(from: Date())], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: SubtitleFixtures.root.deletingLastPathComponent().appendingPathComponent("subtitle-probe.json"), options: .atomic)
    }
    @MainActor private func record(_ name: String) throws { checks.append(name); try save() }
    @MainActor private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw MediaError.message(message) } }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while !condition() {
            try Task.checkCancellation()
            if let error = playback.error { throw MediaError.message(error) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MediaError.message("等待超时：" + stage) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    @MainActor private func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        do {
            try await SubtitleFixtures.prepare(library)
            guard let server = library.selectedServer else { throw MediaError.message("缺少验证目录") }
            try SubtitleSource.store.remove(sourceID: server.id)
            UserDefaults.standard.set("", forKey: "preferredSubtitleLanguage")
            UserDefaults.standard.set(false, forKey: "forcedSubtitlesOnly")
            func video(_ path: String) throws -> Video {
                guard let value = library.videos.first(where: { $0.localRelativePath == path }) else { throw MediaError.message("缺少样例：" + path) }
                return value
            }
            let auto = try video("auto.mp4"), multi = try video("multi.mp4"), imported = try video("import.mp4"), changed = try video("change.mp4")
            let first = try video("家庭甲/相同.mp4"), second = try video("家庭乙/相同.mp4")
            for engine in [PlaybackEngineID.avPlayer, .vlc] {
                stage = "\(engine.rawValue) 自动匹配与字幕时钟"
                PlaybackPreferences.localEngine = engine
                playback.open(auto, library: library, autoplay: false)
                try await wait { playback.frameReady && !playback.subtitles.discovering && !playback.subtitles.cues.isEmpty }
                try require(playback.engineDescriptor.id == engine, "内核不符")
                playback.seek(5.5)
                try await wait { abs(playback.time - 5.5) < 0.8 }
                try require(SubtitleCue.visible(playback.subtitles.cues, time: playback.time, delay: playback.subtitles.delay) == "暂停拖动字幕时钟", "定位字幕时钟错误")
                playback.subtitles.setDelay(2)
                try require(SubtitleCue.visible(playback.subtitles.cues, time: playback.time, delay: playback.subtitles.delay) == "自动匹配中文字幕", "字幕延迟未生效")
                try record("clock:\(engine.rawValue)-paused-seek-delay")
                playback.stop(); playback.open(auto, library: library, autoplay: false)
                try await wait { !playback.subtitles.discovering && !playback.subtitles.cues.isEmpty }
                try require(playback.subtitles.delay == 2, "延迟没有恢复")
                playback.subtitles.selectEmbedded(nil, engine: engine)
                playback.stop(); playback.open(auto, library: library, autoplay: false)
                try await wait { !playback.subtitles.discovering }
                try require(playback.subtitles.choice == .off && playback.subtitles.cues.isEmpty, "关闭状态未被记住")
                playback.subtitles.forget(); playback.stop()
                try record("memory:\(engine.rawValue)-delay-off-clear")
            }
            stage = "多语言选择与重建会话"
            let session = SubtitleSession()
            session.prepare(video: multi, server: server)
            try await wait { !session.discovering }
            try require(session.candidates.count == 2 && session.cues.isEmpty, "多候选被任意选择")
            let chinese = session.candidates.first { $0.language == "zh-Hans" }!
            session.choose(chinese); try await wait { !session.reading }
            session.setDelay(-1.5)
            let restored = SubtitleSession(); restored.prepare(video: multi, server: server)
            try await wait { !restored.discovering && !restored.cues.isEmpty }
            try require(restored.delay == -1.5 && restored.activeName == chinese.name, "选择记忆没有恢复")
            try record("memory:multi-language-selection-new-session")
            for (value, delay) in [(first, 1.5), (second, -0.5)] {
                session.prepare(video: value, server: server); try await wait { !session.discovering && !session.cues.isEmpty }; session.setDelay(delay)
            }
            session.prepare(video: first, server: server); try await wait { !session.discovering && !session.cues.isEmpty }
            try require(session.delay == 1.5 && session.cues.first?.text == "家庭甲的字幕", "同名字幕串用")
            try record("identity:same-name-different-directory")
            stage = "管理副本与文件失效"
            let original = SubtitleFixtures.root.appendingPathComponent("Manual/selected.srt")
            try SubtitleFixtures.srt("手动导入保留副本").write(to: original)
            session.prepare(video: imported, server: server); try await wait { !session.discovering }
            session.importFile(original); try await wait { !session.reading }
            try require(!session.cues.isEmpty, "导入失败")
            try FileManager.default.removeItem(at: original)
            restored.prepare(video: imported, server: server); try await wait { !restored.discovering && !restored.cues.isEmpty }
            try require(restored.cues.first?.text == "手动导入保留副本", "原文件移除后副本无法恢复")
            try record("import:managed-copy-after-source-deleted")
            restored.selectEmbedded(nil, engine: .vlc)
            session.prepare(video: imported, server: server); try await wait { !session.discovering }
            try require(session.choice == .off && session.importedCopy != nil, "关闭后丢失导入副本")
            session.useImportedCopy(); try await wait { !session.reading }
            try require(session.cues.first?.text == "手动导入保留副本", "关闭后不能重新启用副本")
            try record("import:off-restart-reenable-managed-copy")
            let subtitleFile = SubtitleFixtures.root.appendingPathComponent("change.srt")
            try SubtitleFixtures.srt("原始字幕内容").write(to: subtitleFile)
            session.prepare(video: changed, server: server); try await wait { !session.discovering && !session.cues.isEmpty }
            try SubtitleFixtures.srt("变化后的字幕内容").write(to: subtitleFile)
            restored.prepare(video: changed, server: server); try await wait { !restored.discovering && restored.message?.contains("变化") == true }
            try require(restored.cues.isEmpty, "字幕变化后使用了旧内容")
            restored.choose(restored.candidates[0]); try await wait { !restored.reading }
            try require(restored.cues.first?.text == "变化后的字幕内容", "重新选择未读取新字幕")
            try record("invalidated:sidecar-content-change-and-reselect")
            try FileManager.default.removeItem(at: subtitleFile)
            session.prepare(video: changed, server: server); try await wait { !session.discovering && session.message?.contains("删除") == true }
            try require(session.cues.isEmpty, "字幕删除后仍显示")
            try record("invalidated:sidecar-deleted")
            try SubtitleFixtures.srt("恢复后的字幕").write(to: subtitleFile)
            session.forget(); session.prepare(video: changed, server: server); try await wait { !session.discovering && !session.cues.isEmpty }
            let videoURL = SubtitleFixtures.root.appendingPathComponent("change.mp4")
            let oldDate = try videoURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
            try FileManager.default.setAttributes([.modificationDate: oldDate.addingTimeInterval(10)], ofItemAtPath: videoURL.path)
            restored.prepare(video: changed, server: server); try await wait { !restored.discovering && restored.message?.contains("视频文件已变化") == true }
            try require(restored.cues.isEmpty, "视频变化后仍恢复旧选择")
            try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: videoURL.path)
            try record("invalidated:media-revision-change")
            try SubtitleFixtures.srt("旧视频导入任务").write(to: original)
            session.prepare(video: first, server: server)
            session.importFile(original)
            session.prepare(video: second, server: server)
            try await wait { !session.discovering && !session.cues.isEmpty }
            try await Task.sleep(for: .milliseconds(500))
            try require(session.cues.first?.text == "家庭乙的字幕" && session.delay == -0.5, "旧字幕回调覆盖新视频")
            try record("cancel:discovery-import-switch-does-not-cross-video")
            if ProcessInfo.processInfo.arguments.contains("--glide-subtitle-smb-probe") {
                stage = "SMB 同目录字幕"
                try await SubtitleFixtures.prepareSMB(library)
                let smb = library.selectedServer!
                try Credentials.save("glide150-fixture", for: smb.id)
                try SubtitleSource.store.remove(sourceID: smb.id)
                let item = library.videos.first { $0.title == "auto.mp4" }!
                playback.open(item, library: library, autoplay: false)
                try await wait { playback.frameReady && !playback.subtitles.cues.isEmpty }
                try require(playback.engineDescriptor.id == .vlc && playback.subtitles.activeName == "auto.srt", "SMB 字幕匹配错误")
                playback.seek(5.5); try await wait { abs(playback.time - 5.5) < 0.8 }
                try require(SubtitleCue.visible(playback.subtitles.cues, time: playback.time, delay: playback.subtitles.delay) == "暂停拖动字幕时钟", "SMB 字幕定位错误")
                try record("smb:production-stream-sidecar-seek")
            }
            playback.stop(); session.cancel(); restored.cancel()
            stage = "字幕验证通过"; try save(passed: true)
        } catch { failure = error.localizedDescription; stage = "字幕验证未通过"; playback.stop(); try? save() }
    }
}
#endif
