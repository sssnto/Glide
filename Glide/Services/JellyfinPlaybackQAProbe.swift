#if DEBUG
import SwiftUI
import AVFoundation

/// Explicitly launched after user authorization. Credentials and private media
/// identity remain in the app; the report contains format/timing/error codes only.
struct JellyfinPlaybackQAProbe: View {
    let library: LibraryStore
    @State private var engine = NativePlaybackEngine()
    @State private var playback = PlaybackController()
    @State private var stage = "Jellyfin 原片诊断准备中"
    @State private var results: [[String: Any]] = []
    @State private var errors: [[String: Any]] = []
    @State private var output: [String: Any] = [:]
    @State private var context: [String: Any] = [:]
    @State private var audioOwner = UUID()
    @State private var firstVariantURL: URL?
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(presentation: UserDefaults.standard.bool(forKey: "glideInvestigationProduction") ? playback.presentation : engine.presentation, onLayer: { layer in
                if UserDefaults.standard.bool(forKey: "glideInvestigationProduction") { playback.attachLayer(layer) } else { engine.attachLayer(layer) }
            }, identity: "jellyfin-investigation", title: "Jellyfin QA", frameReady: playback.frameReady || engine.snapshot.frameReady, locked: true, filled: false, onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in }, subtitleSession: playback.subtitles, secondarySubtitleSession: playback.secondarySubtitles,
                subtitleClock: { playback.subtitleRenderTime }, subtitleVideoMatrix: playback.subtitleVideoMatrix, subtitleSourceSize: playback.subtitleVideoSize)
            PlayerPGSOverlay(session: playback.subtitles).ignoresSafeArea()
            PlayerSubtitleOverlay(playback: playback, cues: playback.subtitles.overlayCues, delay: playback.subtitles.delay,
                                  bottomInset: 40, secondaryCues: playback.secondarySubtitles.overlayCues, secondaryDelay: playback.secondarySubtitles.delay)
            VStack {
                Text(stage); Text("已检查 \(results.count) 条路线")
                if UserDefaults.standard.bool(forKey: "glideInvestigationSubtitleDiagnosis"),
                   let caption = SubtitleCue.visible(playback.subtitles.cues, time: playback.time, delay: playback.subtitles.delay) {
                    Text(caption).font(.body).foregroundStyle(.yellow).padding(.top, 8)
                }
                Spacer()
            }.foregroundStyle(.white).padding(36)
        }.task { await run() }.onDisappear { playback.close(); engine.stop(); PlaybackAudioSession.release(owner: audioOwner); UIApplication.shared.isIdleTimerDisabled = false }
    }
    @MainActor private func save() {
        let value: [String: Any] = ["stage": stage, "results": results, "context": context,
            "version": PlaybackPreferences.appVersion, "system": UIDevice.current.systemVersion,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "scope": "Authorized in-app recent-item metadata and short real AVPlayer trials; no credentials, host, URL, title, item identifier or media bytes exported"]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("jellyfin-playback-investigation.json"), options: .atomic)
        }
    }
    private func chain(_ error: Error) -> [[String: Any]] {
        PlaybackFailure.chain(error).map { ["domain": $0.domain, "code": $0.code] }
    }
    @MainActor private func trial(_ resource: PlaybackResource, name: String) async {
        engine.stop(); errors = []; output = [:]
        engine.onEvent = { event in
            switch event {
            case .installed: engine.player.isMuted = true; engine.play(rate: 1)
            case .failed(let error): errors = chain(error)
            case .output(let value):
                output = ["codec": value.codec ?? "unknown", "transfer": value.transfer ?? "unknown",
                    "primaries": value.primaries ?? "unknown", "matrix": value.matrix ?? "unknown", "evidence": value.source ?? "unknown"]
            default: break
            }
        }
        stage = "检查 " + name; save()
        let started = ProcessInfo.processInfo.systemUptime
        let inspectColor = !UserDefaults.standard.bool(forKey: "glideInvestigationDisableColorProbe")
        let options = PlaybackEngineOptions(allowsCellular: PlaybackPreferences.cellularPlayback, subtitleScale: 100, forwardBuffer: 2, peakBitrate: 0, inspectWideColor: inspectColor)
        let loading = Task { @MainActor in
            do { try await engine.load(resource, preload: nil, options: options) }
            catch { if !Task.isCancelled { errors = chain(error) } }
        }
        engine.player.isMuted = true
        var frameAt: Double?
        while !Task.isCancelled && errors.isEmpty && ProcessInfo.processInfo.systemUptime - started < 60 {
            if engine.snapshot.frameReady, frameAt == nil {
                frameAt = ProcessInfo.processInfo.systemUptime - started; engine.inspectOutput()
            }
            if frameAt != nil, engine.snapshot.time >= 2 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let snapshot = engine.snapshot
        var result: [String: Any] = ["route": name, "delivery": resource.delivery.rawValue,
            "frameReady": snapshot.frameReady, "actualTime": snapshot.time,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "errors": errors, "output": output, "firstHDRVariantRequested": resource.prefersFirstHDRVariant]
        result["wideColorInspectionEnabled"] = inspectColor
        result["ready"] = snapshot.ready; result["phase"] = String(describing: snapshot.phase)
        result["duration"] = snapshot.duration
        result["subtitleTrackCount"] = engine.tracks.filter { $0.kind == .subtitle }.count
        result["subtitleSelected"] = engine.selectedSubtitleID != nil
        if let selected = engine.tracks.first(where: { $0.id == engine.selectedSubtitleID }), let language = selected.language { result["selectedSubtitleLanguage"] = language }
        result["nativeErrorCodes"] = engine.player.currentItem?.errorLog()?.events.map { ["domain": PlaybackDiagnostic.token($0.errorDomain) ?? "unknown", "code": $0.errorStatusCode] as [String: Any] } ?? []
        let request = NativeColorPolicy.outputOptions(resource.url)
        if let codec = request.codec { result["requestedCodec"] = codec }
        if let range = request.range { result["requestedRange"] = range }
        if let frameAt { result["firstFrameSeconds"] = frameAt }
        results.append(result); loading.cancel(); engine.stop(); save()
    }
    @MainActor private func productionTrial(_ video: Video, selection: TrackSelection) async {
        let switches = UserDefaults.standard.bool(forKey: "glideInvestigationSubtitleSwitch") || UserDefaults.standard.bool(forKey: "glideInvestigationMediaTracks") || UserDefaults.standard.bool(forKey: "glideInvestigationSubtitleDiagnosis") || ProcessInfo.processInfo.arguments.contains("--glide-ass-investigation")
        var memories: [(String, SubtitleMemory?)] = []
        var leases: [SubtitleImportLease] = []
        if switches, let server = library.servers.first(where: { $0.id == video.sourceID }) {
            do {
                let key = try SubtitleSource.key(video: video, server: server), values = try SubtitleSource.store.load().value
                memories = [key, SubtitleLane.secondary.memoryKey(key)].map { ($0, values[$0]) }
                for (_, memory) in memories {
                    if let file = memory?.importedCopy?.file ?? memory?.choice.managedFile { leases.append(SubtitleImportLease(file: try SubtitleSource.store.importedURL(file))) }
                }
            } catch { stage = "字幕记忆保护准备失败"; save(); return }
        }
        defer {
            playback.close()
            if switches {
                do {
                    for (key, memory) in memories { try SubtitleSource.store.set(memory, for: key) }
                    context["subtitleMemoryRestored"] = true
                } catch { context["subtitleMemoryRestored"] = false }
                withExtendedLifetime(leases) {}; save()
            }
        }
        stage = "完整生产流程验证"; save()
        playback.tracks = selection
        playback.open(video, library: library, resumeAt: 0, autoplay: true, recordsProgress: false)
        if case .native(let player) = playback.presentation { player.isMuted = true }
        let started = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled && playback.error == nil && ProcessInfo.processInfo.systemUptime - started < 90 {
            if playback.frameReady, playback.time >= 2 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let diagnostic = (try? JSONSerialization.jsonObject(with: Data(playback.diagnostic.export.utf8))) ?? [:]
        results.append(["route": "production-controller", "frameReady": playback.frameReady, "actualTime": playback.time,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started, "failed": playback.error != nil,
            "subtitleTrackCount": playback.subtitleOptions.count, "selectedSubtitleLanguage": playback.selectedSubtitle?.language ?? "unknown", "diagnostic": diagnostic])
        results[results.count - 1]["subtitleSelected"] = playback.selectedSubtitle != nil
        results[results.count - 1]["subtitleLanguages"] = playback.subtitleOptions.map { $0.language ?? "unknown" }
        results[results.count - 1]["rememberedSubtitleSuppressesNative"] = playback.subtitles.choice?.suppressesEmbedded ?? false
        results[results.count - 1]["externalSubtitleCueCount"] = playback.subtitles.cues.count + playback.secondarySubtitles.cues.count
        results[results.count - 1]["globalSubtitlePreferenceOff"] = PlaybackPreferences.subtitlesOff
        if ProcessInfo.processInfo.arguments.contains("--glide-ass-investigation") {
            let styled = ProcessInfo.processInfo.arguments.contains("--glide-ass-style-investigation")
            let passed = styled ? await assStyleTrial(video) : await assSubtitleTrial(video)
            guard playback.frameReady, playback.error == nil, passed else { stage = "ASS 字幕验证未完成"; save(); return }
        }
        if UserDefaults.standard.bool(forKey: "glideInvestigationSubtitleDiagnosis") {
            context["negotiation"] = MediaClient.qaNegotiationReport
            results[results.count - 1]["serverSubtitleCount"] = playback.serverSubtitleOptions.count
            results[results.count - 1]["selectedServerSubtitleIndex"] = playback.selectedServerSubtitleIndex ?? -1
            results[results.count - 1]["bitmapCueCount"] = playback.subtitles.bitmap?.cues.count ?? 0
            results[results.count - 1]["chineseCueCount"] = playback.subtitles.cues.filter { hasChinese($0.text) }.count
            results[results.count - 1]["letterCueCount"] = playback.subtitles.cues.filter { $0.text.unicodeScalars.contains(where: CharacterSet.letters.contains) }.count
            results[results.count - 1]["whitespaceOnlyCueCount"] = playback.subtitles.cues.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            results[results.count - 1]["subtitleMemoryPresent"] = playback.subtitles.hasMemory
            results[results.count - 1]["subtitleChoice"] = choiceKind(playback.subtitles.choice)
            results[results.count - 1]["clientCaptionVisibleAtCurrentClock"] = SubtitleCue.visible(playback.subtitles.cues, time: playback.time, delay: playback.subtitles.delay) != nil
            guard playback.frameReady, playback.error == nil, await defaultSubtitleTrial(video) else { stage = "默认字幕验证未完成"; save(); return }
        }
        if UserDefaults.standard.bool(forKey: "glideInvestigationSubtitleSwitch") {
            guard playback.frameReady, playback.error == nil, await subtitleSwitchTrial(video) else { stage = "字幕切换验证未完成"; save(); return }
        }
        if UserDefaults.standard.bool(forKey: "glideInvestigationMediaTracks") {
            guard playback.frameReady, playback.error == nil, await mediaTracksTrial(video) else { stage = "PGS 与音轨验证未完成"; save(); return }
        }
        if playback.frameReady, playback.error == nil, UserDefaults.standard.bool(forKey: "glideInvestigationControls") {
            var checks: [String] = []
            playback.pause()
            try? await Task.sleep(for: .milliseconds(400))
            let frozen = playback.time
            try? await Task.sleep(for: .milliseconds(700))
            if !playback.isPlaying, abs(playback.time - frozen) < 0.3 { checks.append("pause-freezes-clock") }
            let caption = playback.subtitles.cues.first { $0.start >= 30 && $0.end - $0.start >= 2 && hasChinese($0.text) }
            let target = caption.map { $0.start + min(1, ($0.end - $0.start) / 2) } ?? 30
            results[results.count - 1]["captionSeekTarget"] = target
            playback.seek(target)
            var deadline = ProcessInfo.processInfo.systemUptime + 25
            while playback.isSeeking && playback.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if !playback.isSeeking, abs(playback.time - target) <= 0.6, !playback.isPlaybackRequested { checks.append("paused-seek-to-caption-keeps-pause") }
            if let visible = SubtitleCue.visible(playback.subtitles.cues, time: playback.time, delay: playback.subtitles.delay), hasChinese(visible) { checks.append("chinese-caption-active-at-real-clock") }
            playback.play(); deadline = ProcessInfo.processInfo.systemUptime + 40
            while playback.time < target + 1 && playback.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            if playback.time >= target + 1, playback.isPlaying { checks.append("resume-advances-clock") }
            results[results.count - 1]["resumeActualTime"] = playback.time
            results[results.count - 1]["resumeDiagnostic"] = (try? JSONSerialization.jsonObject(with: Data(playback.diagnostic.export.utf8))) ?? [:]
            if playback.originalTransportActive { checks.append("original-transport-already-active") }
            if playback.canTryOriginalTransport {
                playback.tryOriginalTransport(); deadline = ProcessInfo.processInfo.systemUptime + 40
                while (!playback.frameReady || playback.isSeeking || !playback.isPlaying) && playback.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(100)) }
                if playback.frameReady, playback.isPlaying, playback.originalTransportActive, playback.resource?.delivery == .audioConversion || playback.resource?.delivery == .remux { checks.append("manual-original-transport-preserves-video-and-playing") }
            }
            results.append(["route": "production-controls", "checks": checks, "expectedChecks": 5, "actualTime": playback.time,
                "frameReady": playback.frameReady, "failed": playback.error != nil, "diagnostic": (try? JSONSerialization.jsonObject(with: Data(playback.diagnostic.export.utf8))) ?? [:]])
        }
        stage = "完整生产流程验证结束"; save()
    }

    @MainActor private func assStyleTrial(_ video: Video) async -> Bool {
        var checks = [String](), checkpoint = "authored-libass-effects", passed = false
        func check(_ value: Bool, _ name: String) throws {
            checkpoint = name
            guard value else { throw MediaError.message("ASS 原样检查未通过") }
            checks.append(name)
        }
        func canvases(_ view: UIView) -> [ASSCanvasView] {
            (view as? ASSCanvasView).map { [$0] } ?? view.subviews.flatMap(canvases)
        }
        func rendered() -> Bool {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                .flatMap(canvases).contains { !$0.isHidden && $0.window != nil && $0.presentedLayerCount > 0 }
        }
        func wait(_ predicate: () -> Bool, seconds: Double = 25) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while !predicate(), playback.error == nil, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(80)) }
        }
        do {
            let authored = try await ASSStyleQA.validate()
            results.append(["route": "authored-ass-original-effects", "report": authored])
            try check(authored["passed"] as? Bool == true, "authored-libass-effects")
            playback.pause()
            guard let selected = playback.serverSubtitleOptions.first(where: { ["ass", "ssa"].contains($0.Codec?.lowercased() ?? "") }) else { throw MediaError.message("无 ASS 轨道") }
            if !playback.subtitles.hasASS || playback.selectedServerSubtitleIndex != selected.Index { playback.chooseServerSubtitle(selected) }
            try await wait { playback.serverSubtitlePendingIndex == nil && playback.subtitles.hasASS }
            try check(playback.subtitles.hasASS && playback.selectedServerSubtitleIndex == selected.Index, "production-original-ass-track-selected")
            guard let ass = playback.subtitles.ass else { throw MediaError.message("原始 ASS 未载入") }
            let text = String(data: ass.document.data, encoding: .utf8) ?? ""
            try check(text.contains("[V4+ Styles]") && ASSPlainText.hasOverrides(text), "original-style-table-and-overrides-reach-libass")
            try check(ass.cues.contains { hasChinese($0.text) && $0.text.contains("\n") }, "bilingual-dialogue-and-transcript-retained")
            guard let cue = ass.cues.first(where: { hasChinese($0.text) && $0.end - $0.start > 0.5 }) else { throw MediaError.message("没有中文字幕") }
            let target = cue.start + min(0.5, (cue.end - cue.start) / 2)
            playback.seek(target)
            try await wait { !playback.isSeeking && abs(playback.time - target) < 0.7 }
            try check(playback.frameReady && !playback.isSeeking && abs(playback.time - target) < 0.7, "real-decoder-seek-to-original-dialogue")
            try await wait({ rendered() }, seconds: 12)
            try check(rendered(), "production-libass-pixels-visible-at-decoder-clock")
            try check(playback.subtitles.overlayCues.isEmpty, "ordinary-text-overlay-suppressed-for-ass")
            let session = playback.resource?.sessionID, position = playback.time
            let workerTask = Task.detached { try ASSRenderWorker(subtitle: ass) }
            let worker = try await workerTask.value
            let missing = worker.missingFonts
            _ = await worker.render(time: position, width: 1280, height: 720, source: playback.subtitleVideoSize, matrix: playback.subtitleVideoMatrix)
            let matched = await worker.matchedProvidedFontCount
            if !ass.document.requestedFonts.isEmpty && missing.isEmpty, await worker.providedFontCount > 0 { try check(matched > 0, "provided-original-font-selected-by-libass") }
            results.append(["route": "ass-original-visual-checkpoint", "actualTime": position, "target": target,
                "assByteCount": ass.document.data.count, "eventCount": await worker.eventCount, "fontAttachmentCount": ass.fonts.count,
                "requestedFontCount": ass.document.requestedFonts.count, "missingFontCount": missing.count, "matchedProvidedFontCount": matched, "rendered": rendered()])
            stage = "ASS 原字体、颜色与特效画面复核"; save()
            try await Task.sleep(for: .seconds(18))
            playback.closeExternalSubtitles()
            try await wait({ !rendered() }, seconds: 3)
            try check(!playback.subtitles.hasASS && !rendered() && playback.resource?.sessionID == session, "subtitle-off-clears-original-layer-without-video-reopen")
            if let plain = playback.serverSubtitleOptions.first(where: { ["srt", "subrip", "vtt"].contains($0.Codec?.lowercased() ?? "") }) {
                playback.chooseServerSubtitle(plain)
                try await wait { playback.serverSubtitlePendingIndex == nil && !playback.subtitles.cues.isEmpty }
                try check(!playback.subtitles.hasASS && !playback.subtitles.overlayCues.isEmpty && playback.resource?.sessionID == session, "switch-ass-to-plain-text-preserves-video")
            } else { try check(true, "switch-ass-to-plain-text-unavailable") }
            playback.chooseServerSubtitle(selected)
            try await wait { playback.serverSubtitlePendingIndex == nil && playback.subtitles.hasASS }
            try check(playback.subtitles.hasASS && playback.resource?.sessionID == session && !playback.isPlaybackRequested && abs(playback.time - position) < 0.3, "switch-back-restores-ass-and-pause-clock")
            try await wait({ rendered() }, seconds: 12)
            try check(rendered(), "original-styled-pixels-reappear-after-switch")
            playback.play()
            try await wait({ playback.time > position + 1 }, seconds: 12)
            try check(playback.error == nil && playback.time > position + 1 && playback.resource?.sessionID == session, "styled-ass-plays-in-original-video-session")
            passed = true
        } catch {}
        results.append(["route": "production-ass-original-style", "passed": passed, "failed": !passed, "checks": checks,
            "expectedChecks": checks.contains("provided-original-font-selected-by-libass") ? 13 : 12, "failedCheck": passed ? "none" : checkpoint, "actualTime": playback.time])
        save(); return passed
    }

    @MainActor private func assSubtitleTrial(_ video: Video) async -> Bool {
        var checks: [String] = [], checkpoint = "identify-actual-override-track", passed = false
        func check(_ value: Bool, _ name: String) throws {
            checkpoint = name
            guard value else { throw MediaError.message("ASS 字幕检查未通过") }
            checks.append(name)
        }
        do {
            playback.pause()
            guard let server = library.servers.first(where: { $0.id == video.sourceID }), let sourceID = playback.resource?.mediaSourceID else { throw MediaError.message("没有生产播放版本") }
            let inventory = playback.serverSubtitleOptions
            var selected: CatalogItem.Stream?
            let ordered = inventory.sorted { ($0.Index == playback.selectedServerSubtitleIndex ? 0 : 1) < ($1.Index == playback.selectedServerSubtitleIndex ? 0 : 1) }
            for stream in ordered.prefix(16) where CatalogSubtitlePolicy.textCodecs.contains(stream.Codec?.lowercased() ?? "") {
                if MediaClient.qaASSReports[stream.Index] == nil { _ = try await MediaClient.shared.serverSubtitle(video: video, server: server, sourceID: sourceID, stream: stream) }
                if MediaClient.qaASSReports[stream.Index]?["rawContainsOverrides"] as? Bool == true { selected = stream; break }
            }
            guard let selected else { throw MediaError.message("未找到包含 ASS 标签的实际字幕") }
            try check(true, "raw-server-conversion-retains-ass-overrides")
            if playback.selectedServerSubtitleIndex != selected.Index { playback.chooseServerSubtitle(selected) }
            var deadline = ProcessInfo.processInfo.systemUptime + 25
            while (playback.serverSubtitlePendingIndex != nil || playback.subtitles.cues.isEmpty) && playback.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try check(playback.selectedServerSubtitleIndex == selected.Index && !playback.subtitles.cues.isEmpty, "production-selected-original-track")
            try check(playback.subtitles.cues.allSatisfy { !ASSPlainText.hasOverrides($0.text) }, "no-control-blocks-in-entire-rendered-track")
            try check(playback.subtitles.cues.contains { hasChinese($0.text) && $0.text.contains("\n") }, "chinese-and-multiline-dialogue-preserved")
            let start = MediaClient.qaASSCheckpoints[selected.Index] ?? 15
            guard let cue = playback.subtitles.cues.first(where: { abs($0.start - start) < 0.01 }) else { throw MediaError.message("缺少原标签对应的字幕") }
            let target = cue.start + min(0.5, (cue.end - cue.start) / 2)
            playback.seek(target); deadline = ProcessInfo.processInfo.systemUptime + 25
            while (playback.isSeeking || abs(playback.time - target) > 0.7) && playback.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try check(playback.frameReady && playback.error == nil && !playback.isSeeking && abs(playback.time - target) <= 0.7, "actual-decoder-seek-to-previously-tagged-caption")
            let visible = SubtitleCue.visible(playback.subtitles.cues, time: playback.time, delay: playback.subtitles.delay)
            try check(visible?.contains("\\") == false && visible?.contains("{") == false && visible.map(hasChinese) == true, "clean-chinese-caption-active-at-real-clock")
            let session = playback.resource?.sessionID, position = playback.time
            results.append(["route": "ass-caption-visual-checkpoint", "actualTime": position, "target": target,
                "captionActive": true, "containsOverrides": false, "extraction": MediaClient.qaASSReports[selected.Index] ?? [:]])
            stage = "ASS 字幕画面复核"; save()
            try await Task.sleep(for: .seconds(18))
            playback.closeExternalSubtitles()
            try check(playback.subtitles.cues.isEmpty && playback.resource?.sessionID == session, "subtitle-off-clears-without-reopening-video")
            playback.chooseServerSubtitle(selected); deadline = ProcessInfo.processInfo.systemUptime + 25
            while (playback.serverSubtitlePendingIndex != nil || playback.subtitles.cues.isEmpty) && playback.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try check(playback.selectedServerSubtitleIndex == selected.Index && playback.resource?.sessionID == session && !playback.isPlaybackRequested && abs(playback.time - position) < 0.3, "subtitle-reenable-preserves-session-clock-and-pause")
            try check(SubtitleCue.visible(playback.subtitles.cues, time: playback.time, delay: playback.subtitles.delay) == visible, "clean-caption-survives-track-switch")
            playback.play(); deadline = ProcessInfo.processInfo.systemUptime + 12
            while playback.time < position + 1 && playback.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try check(playback.time >= position + 1 && playback.error == nil && playback.resource?.sessionID == session, "playback-continues-with-original-video-session")
            passed = true
        } catch {}
        results.append(["route": "production-ass-plaintext", "checks": checks, "expectedChecks": 10,
            "failed": !passed, "failedCheck": passed ? "none" : checkpoint, "actualTime": playback.time,
            "cueCount": playback.subtitles.cues.count, "sourceReports": MediaClient.qaASSReports.values.map { $0 }])
        save(); return passed
    }

    @MainActor private func defaultSubtitleTrial(_ video: Video) async -> Bool {
        var checks: [String] = [], checkpoint = "automatic-default-client-caption-loaded", passed = false
        func check(_ value: Bool, _ name: String) throws {
            checkpoint = name
            guard value else { throw MediaError.message("默认字幕检查未通过") }
            checks.append(name)
        }
        do {
            guard let index = playback.selectedServerSubtitleIndex,
                  let selected = playback.serverSubtitleOptions.first(where: { $0.Index == index }),
                  !playback.subtitles.cues.isEmpty else { throw MediaError.message("默认字幕未加载") }
            try check(true, "automatic-default-client-caption-loaded")
            playback.pause(); try await Task.sleep(for: .milliseconds(500))
            let frozen = playback.time, session = playback.resource?.sessionID
            try await Task.sleep(for: .milliseconds(700))
            try check(!playback.isPlaying && abs(playback.time - frozen) < 0.3, "pause-freezes-clock")
            checkpoint = "seek-to-real-caption"
            guard let cue = playback.subtitles.cues.first(where: { $0.start >= 15 && $0.end - $0.start >= 2 }) else { throw MediaError.message("缺少可定位的字幕") }
            let target = cue.start + min(1, (cue.end - cue.start) / 2) + playback.subtitles.delay
            playback.seek(target)
            var deadline = ProcessInfo.processInfo.systemUptime + 25
            while (playback.isSeeking || abs(playback.time - target) > 0.7) && playback.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try check(!playback.isSeeking && abs(playback.time - target) <= 0.7 && !playback.isPlaybackRequested, "paused-seek-keeps-clock-and-pause")
            try check(SubtitleCue.visible(playback.subtitles.cues, time: playback.time, delay: playback.subtitles.delay) != nil, "caption-active-at-real-clock")
            results.append(["route": "default-subtitle-caption-checkpoint", "actualTime": playback.time, "target": target,
                "clientSubtitleCueCount": playback.subtitles.cues.count, "selectedServerSubtitleIndex": index,
                "captionActive": true, "chineseCaptionActive": hasChinese(cue.text)])
            stage = "默认字幕显示复核"; save()
            try await Task.sleep(for: .seconds(40))
            playback.closeExternalSubtitles()
            try check(playback.subtitles.cues.isEmpty && playback.selectedServerSubtitleIndex == nil && playback.resource?.sessionID == session, "off-clears-overlay-without-reopening-video")
            checkpoint = "reenable-after-off"
            playback.chooseServerSubtitle(selected); deadline = ProcessInfo.processInfo.systemUptime + 25
            while (playback.serverSubtitlePendingIndex != nil || playback.subtitles.cues.isEmpty) && playback.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try check(playback.selectedServerSubtitleIndex == index && playback.resource?.sessionID == session && !playback.isPlaybackRequested
                && SubtitleCue.visible(playback.subtitles.cues, time: playback.time, delay: playback.subtitles.delay) != nil, "reenable-restores-caption-with-session-clock-and-pause")
            playback.play(); deadline = ProcessInfo.processInfo.systemUptime + 20
            while playback.time < target + 1 && playback.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try check(playback.time >= target + 1 && playback.isPlaying && playback.resource?.sessionID == session, "resume-advances-original-video-session")
            playback.close(); playback.tracks = TrackSelection()
            playback.open(video, library: library, resumeAt: 0, autoplay: true, recordsProgress: false)
            if case .native(let player) = playback.presentation { player.isMuted = true }
            deadline = ProcessInfo.processInfo.systemUptime + 60
            while (!playback.frameReady || playback.time < 2 || playback.subtitles.cues.isEmpty) && playback.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try check(playback.frameReady && playback.error == nil && playback.selectedServerSubtitleIndex == index && !playback.subtitles.cues.isEmpty, "subtitle-restores-after-player-reopen")
            passed = true
        } catch { }
        results.append(["route": "production-default-subtitle", "checks": checks, "expectedChecks": 8,
            "failed": !passed, "failedCheck": passed ? "none" : checkpoint,
            "actualTime": playback.time, "clientSubtitleCueCount": playback.subtitles.cues.count,
            "selectedServerSubtitleIndex": playback.selectedServerSubtitleIndex ?? -1])
        save(); return passed
    }
    @MainActor private func subtitleSwitchTrial(_ video: Video) async -> Bool {
        var checks: [String] = [], checkpoint = "inventory"
        let inventory = playback.serverSubtitleOptions
        func check(_ value: Bool, _ name: String) throws {
            checkpoint = name
            guard value else { throw MediaError.message("字幕切换检查未通过") }
            checks.append(name)
        }
        func selected(_ index: Int) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while playback.serverSubtitlePendingIndex != nil || playback.selectedServerSubtitleIndex != index || playback.subtitles.cues.isEmpty {
                guard !Task.isCancelled, playback.error == nil, ProcessInfo.processInfo.systemUptime < deadline else { throw MediaError.message("字幕切换等待未完成") }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        var passed = false
        do {
            let text = inventory.filter { CatalogSubtitlePolicy.textCodecs.contains($0.Codec?.lowercased() ?? "") }
            let chinese = text.filter { LanguagePreference.normalized($0.Language) == "zh" }
            guard let english = text.first(where: { LanguagePreference.normalized($0.Language) == "en" }), chinese.count >= 2 else { throw MediaError.message("缺少多轨字幕样例") }
            try check(inventory.count >= 4, "full-server-inventory-survives-video-only-stream")
            playback.pause(); try await Task.sleep(for: .milliseconds(600))
            let frozen = playback.time, session = playback.resource?.sessionID
            checkpoint = "english-selection"
            playback.chooseServerSubtitle(english); try await selected(english.Index)
            try check(playback.resource?.sessionID == session && !playback.isPlaybackRequested && abs(playback.time - frozen) < 0.3, "english-switch-keeps-video-session-clock-and-pause")
            checkpoint = "chinese-variant-selection"
            playback.chooseServerSubtitle(chinese.last!); try await selected(chinese.last!.Index)
            try check(playback.resource?.sessionID == session && !playback.isPlaybackRequested, "same-language-variant-is-individually-selectable")
            playback.closeExternalSubtitles()
            try check(playback.subtitles.cues.isEmpty && playback.selectedServerSubtitleIndex == nil && playback.resource?.sessionID == session, "off-clears-overlay-without-reopening-video")
            checkpoint = "reenable-after-off"
            playback.chooseServerSubtitle(chinese[0]); try await selected(chinese[0].Index)
            try check(playback.resource?.sessionID == session && !playback.isPlaybackRequested, "off-then-chinese-restores-client-caption-and-pause")
            checkpoint = "rapid-switch"
            playback.chooseServerSubtitle(english); playback.chooseServerSubtitle(chinese[0])
            try await selected(chinese[0].Index); try await Task.sleep(for: .milliseconds(500))
            try check(playback.selectedServerSubtitleIndex == chinese[0].Index && playback.subtitles.serverTrack?.language == chinese[0].Language, "rapid-switch-last-request-wins")
            playback.play()
            var deadline = ProcessInfo.processInfo.systemUptime + 20
            while playback.time < frozen + 1 && playback.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try check(playback.time >= frozen + 1 && playback.resource?.sessionID == session, "resume-after-subtitle-switch-advances-original-session")
            playback.close(); playback.tracks = TrackSelection()
            playback.open(video, library: library, resumeAt: 0, autoplay: true, recordsProgress: false)
            if case .native(let player) = playback.presentation { player.isMuted = true }
            deadline = ProcessInfo.processInfo.systemUptime + 60
            while (!playback.frameReady || playback.time < 2 || playback.subtitles.cues.isEmpty) && playback.error == nil && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try check(playback.frameReady && playback.error == nil && playback.selectedServerSubtitleIndex == chinese[0].Index && !playback.subtitles.cues.isEmpty, "server-choice-restores-after-player-reopen")
            try check(playback.serverSubtitleOptions.count == inventory.count, "full-inventory-remains-after-choice-restoration")
            passed = true
        } catch { }
        results.append(["route": "production-subtitle-switch", "checks": checks, "expectedChecks": 9, "failed": !passed,
            "failedCheck": passed ? "none" : checkpoint, "serverSubtitleCount": inventory.count,
            "formats": inventory.map { ["index": $0.Index, "codec": PlaybackDiagnostic.token($0.Codec) ?? "unknown", "language": PlaybackDiagnostic.token($0.Language) ?? "unknown"] as [String: Any] },
            "selectedServerSubtitleIndex": playback.selectedServerSubtitleIndex ?? -1,
            "clientSubtitleCueCount": playback.subtitles.cues.count,
            "diagnostic": (try? JSONSerialization.jsonObject(with: Data(playback.diagnostic.export.utf8))) ?? [:]])
        save(); return passed
    }
    @MainActor private func mediaTracksTrial(_ video: Video) async -> Bool {
        var checks: [String] = [], checkpoint = "inventory", passed = false
        let audio = playback.serverAudioOptions, inventory = playback.serverSubtitleOptions
        var bitmapBytes = 0, bitmapCues = 0, layers = 0
        func check(_ value: Bool, _ name: String) throws {
            checkpoint = name
            guard value else { throw MediaError.message("媒体轨道检查未通过") }
            checks.append(name); stage = "PGS 与音轨：" + name; save()
        }
        func wait(_ name: String, timeout: Double = 60, until predicate: () -> Bool) async throws {
            checkpoint = name
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while !predicate() {
                guard !Task.isCancelled, playback.error == nil, ProcessInfo.processInfo.systemUptime < deadline else { throw MediaError.message("媒体轨道等待未完成") }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        func requestedAudio(_ index: Int) -> Bool {
            guard let resource = playback.resource else { return false }
            return URLComponents(url: resource.url, resolvingAgainstBaseURL: false)?.queryItems?
                .last(where: { $0.name.lowercased() == "audiostreamindex" })?.value == String(index)
        }
        do {
            try check(audio.count >= 2 && inventory.contains { CatalogSubtitlePolicy.pgsCodecs.contains($0.Codec?.lowercased() ?? "") }, "original-audio-and-pgs-inventory-visible")
            let pgs = inventory.first { CatalogSubtitlePolicy.pgsCodecs.contains($0.Codec?.lowercased() ?? "") }!
            let originalAudio = playback.selectedServerAudioIndex
            let alternate = audio.first { $0.Index != originalAudio }!
            playback.pause(); try await Task.sleep(for: .milliseconds(600))
            let session = playback.resource?.sessionID, position = playback.time
            playback.chooseServerSubtitle(pgs)
            try await wait("pgs-extraction", timeout: 120) { playback.subtitles.hasBitmap && playback.serverSubtitlePendingIndex == nil }
            bitmapBytes = playback.subtitles.bitmap?.compressedBytes ?? 0; bitmapCues = playback.subtitles.bitmap?.cues.count ?? 0
            try check(playback.selectedServerSubtitleIndex == pgs.Index && playback.resource?.sessionID == session && !playback.isPlaybackRequested && abs(playback.time - position) < 0.5, "pgs-select-keeps-video-session-position-and-pause")
            guard let cue = playback.subtitles.bitmap?.cues.first(where: { $0.start >= 30 && $0.end.isFinite && $0.end - $0.start >= 1 }) else { throw MediaError.message("缺少 PGS 定位样例") }
            let target = cue.start + min(0.5, (cue.end - cue.start) / 2)
            playback.seek(target)
            try await wait("pgs-seek-image") { !playback.isSeeking && playback.subtitles.bitmapFrame != nil }
            layers = playback.subtitles.bitmapFrame?.layers.count ?? 0
            try check(layers > 0 && abs(playback.time - target) < 0.8 && !playback.isPlaybackRequested, "pgs-raster-visible-at-paused-real-clock")
            playback.closeExternalSubtitles()
            try check(!playback.subtitles.hasBitmap && playback.subtitles.bitmapFrame == nil && playback.resource?.sessionID == session, "pgs-off-clears-without-video-reload")
            playback.chooseServerSubtitle(pgs)
            try await wait("pgs-reenable") { playback.subtitles.hasBitmap && playback.subtitles.bitmapFrame != nil && playback.serverSubtitlePendingIndex == nil }
            try check(playback.resource?.sessionID == session && playback.selectedServerSubtitleIndex == pgs.Index, "pgs-reenable-restores-actual-image")
            let audioPosition = playback.time
            playback.chooseServerAudio(alternate)
            if case .native(let player) = playback.presentation { player.isMuted = true }
            try await wait("audio-switch-paused") { playback.frameReady && !playback.isSeeking && playback.selectedServerAudioIndex == alternate.Index }
            try check(requestedAudio(alternate.Index) && abs(playback.time - audioPosition) < 0.8 && !playback.isPlaybackRequested, "audio-switch-negotiates-index-and-preserves-paused-position")
            try await wait("pgs-after-audio") { playback.subtitles.bitmapFrame != nil }
            try check(playback.selectedServerSubtitleIndex == pgs.Index && playback.subtitles.hasBitmap && playback.serverAudioOptions.count == audio.count, "audio-switch-retains-pgs-and-full-audio-inventory")
            playback.play(); let resume = playback.time
            try await wait("audio-clock") { playback.time > resume + 1 && playback.isPlaying }
            try check(playback.frameReady && playback.error == nil, "alternate-audio-video-resumes-with-clock")
            if let original = audio.first(where: { $0.Index == originalAudio }) {
                let before = playback.time
                playback.chooseServerAudio(original)
                if case .native(let player) = playback.presentation { player.isMuted = true }
                try await wait("audio-switch-playing") { playback.frameReady && playback.isPlaying && !playback.isSeeking && playback.selectedServerAudioIndex == original.Index && playback.time >= before }
                try check(requestedAudio(original.Index) && playback.isPlaybackRequested && playback.time < before + 15, "audio-switch-back-preserves-playing-position")
            }
            playback.pause(); playback.close(); playback.tracks = TrackSelection()
            playback.open(video, library: library, resumeAt: target, autoplay: true, recovering: true, recordsProgress: false)
            if case .native(let player) = playback.presentation { player.isMuted = true }
            try await wait("pgs-memory-restore", timeout: 90) { playback.frameReady && playback.subtitles.hasBitmap && playback.subtitles.bitmapFrame != nil }
            try check(playback.selectedServerSubtitleIndex == pgs.Index && playback.serverSubtitleOptions.count == inventory.count, "pgs-choice-restores-after-reopen")
            if let text = inventory.first(where: { CatalogSubtitlePolicy.textCodecs.contains($0.Codec?.lowercased() ?? "") }) {
                let keepSession = playback.resource?.sessionID
                playback.chooseServerSubtitle(text)
                try await wait("pgs-to-text") { !playback.subtitles.cues.isEmpty && playback.serverSubtitlePendingIndex == nil }
                try check(!playback.subtitles.hasBitmap && playback.subtitles.bitmapFrame == nil && playback.resource?.sessionID == keepSession, "pgs-to-text-removes-image-without-video-reload")
            }
            passed = checks.count == 11
        } catch { }
        results.append(["route": "production-pgs-audio-switch", "checks": checks, "expectedChecks": 11, "failed": !passed,
            "failedCheck": passed ? "none" : checkpoint, "originalAudioCount": audio.count,
            "audioFormats": audio.map { ["index": $0.Index, "codec": PlaybackDiagnostic.token($0.Codec) ?? "unknown", "language": PlaybackDiagnostic.token($0.Language) ?? "unknown"] as [String: Any] },
            "pgsCompressedBytes": bitmapBytes, "pgsCueCount": bitmapCues, "renderedLayers": layers,
            "subtitleMessagePresent": playback.subtitles.message != nil, "actualTime": playback.time,
            "diagnostic": (try? JSONSerialization.jsonObject(with: Data(playback.diagnostic.export.utf8))) ?? [:]])
        save(); return passed
    }
    private func hasChinese(_ value: String) -> Bool { value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
    @MainActor private func latestDate(_ value: PersonalVideo) -> Date {
        library.progressSnapshots[value.id]?.updatedAt ?? value.lastPlayedAt ?? Date.distantPast
    }
    @MainActor private func inspectNetwork(_ resource: PlaybackResource, server: MediaServer) async -> [String: Any] {
        guard let token = Credentials.read(server.id) else { return ["credentialAvailable": false] }
        let auth = MediaClient.shared.authorization(token, server: server)
        func status(_ url: URL, authenticated: Bool) async -> Int {
            var request = URLRequest(url: url); request.timeoutInterval = 10
            request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
            if authenticated { request.setValue(auth, forHTTPHeaderField: "Authorization") }
            do { let (_, response) = try await MediaClient.shared.session.data(for: request); return (response as? HTTPURLResponse)?.statusCode ?? 0 }
            catch { return (error as NSError).code }
        }
        func hasKey(_ url: URL) -> Bool {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { ["apikey", "api_key"].contains($0.name.lowercased()) } == true
        }
        var result: [String: Any] = ["masterHasAPIKey": hasKey(resource.url), "resourceHasHeaders": !resource.headers.isEmpty]
        do {
            let master = try await MediaClient.shared.request(resource.url, headers: ["Authorization": auth])
            guard let text = String(data: master, encoding: .utf8) else { return result }
            var awaitingURI = false
            var variant: URL?
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("#EXT-X-STREAM-INF:") { awaitingURI = true }
                else if awaitingURI, !line.isEmpty, !line.hasPrefix("#") { variant = URL(string: line, relativeTo: resource.url)?.absoluteURL; break }
            }
            guard let variant, ServerURL.sameOrigin(resource.url, variant) else { return result }
            firstVariantURL = variant
            result["variantHasAPIKey"] = hasKey(variant)
            result["variantStatusWithoutHeader"] = await status(variant, authenticated: false)
            let media = try await MediaClient.shared.request(variant, headers: ["Authorization": auth])
            if let playlist = String(data: media, encoding: .utf8) {
                var mediaURLs: [(String, URL)] = []
                for raw in playlist.split(whereSeparator: \.isNewline) {
                    let line = String(raw)
                    if line.hasPrefix("#EXT-X-MAP:"), let begin = line.range(of: "URI=\"")?.upperBound,
                       let end = line[begin...].firstIndex(of: "\""), let url = URL(string: String(line[begin..<end]), relativeTo: variant)?.absoluteURL {
                        mediaURLs.append(("initialization", url))
                    } else if !line.isEmpty, !line.hasPrefix("#"), let url = URL(string: line, relativeTo: variant)?.absoluteURL {
                        mediaURLs.append(("firstSegment", url)); break
                    }
                }
                for (label, url) in mediaURLs where ServerURL.sameOrigin(resource.url, url) {
                    result[label + "HasAPIKey"] = hasKey(url)
                    result[label + "StatusWithoutHeader"] = await status(url, authenticated: false)
                    result[label + "StatusWithHeader"] = await status(url, authenticated: true)
                }
            }
        } catch { result["errors"] = chain(error) }
        return result
    }
    @MainActor private func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        do {
            try await PlaybackAudioSession.activate(owner: audioOwner)
            context["audioSessionActivated"] = true
        } catch { context["audioSessionErrors"] = chain(error); stage = "播放会话启用失败"; save(); return }
        defer { PlaybackAudioSession.release(owner: audioOwner) }
        context["jellyfinSourceCount"] = library.servers.filter { $0.kind == .jellyfin }.count
        context["allowsCellularInProbe"] = PlaybackPreferences.cellularPlayback
        save()
        let candidates = library.personalVideos.values.sorted { latestDate($0) > latestDate($1) }
        context["recentCandidateCount"] = candidates.count
        var candidateFormats: [[String: Any]] = []
        for saved in candidates.prefix(12) {
            guard let server = library.servers.first(where: { $0.id == saved.video.sourceID && $0.kind == .jellyfin }),
                  let id = saved.video.remoteID else { continue }
            do {
                let detail = try await MediaClient.shared.catalogDetail(server: server, id: id, refresh: true)
                if let series = UserDefaults.standard.string(forKey: "glideInvestigationSeries") {
                    guard detail.SeriesName?.contains(series) == true,
                          detail.ParentIndexNumber == UserDefaults.standard.integer(forKey: "glideInvestigationSeason"),
                          detail.IndexNumber == UserDefaults.standard.integer(forKey: "glideInvestigationEpisode") else { continue }
                    context["explicitEpisodeMatched"] = true
                }
                let sources: [CatalogItem.Source] = detail.MediaSources ?? []
                let streams: [CatalogItem.Stream] = sources.flatMap { $0.MediaStreams ?? [] }
                for value in streams where value.Type == "Video" {
                    candidateFormats.append(["codec": value.Codec ?? "unknown", "width": value.Width ?? 0, "height": value.Height ?? 0,
                        "dvProfile": value.DvProfile ?? 0, "range": value.VideoRangeType ?? "unknown"])
                }
                context["recentFormats"] = candidateFormats; save()
                guard let stream = streams.first(where: matchesDiagnostic) else { continue }
                context["matchedDiagnosticFormat"] = true
                context["sourceCodec"] = stream.Codec; context["sourceRange"] = stream.VideoRangeType
                context["sourceTransfer"] = stream.ColorTransfer; context["sourceBitrate"] = stream.BitRate
                context["sourceDvProfile"] = stream.DvProfile
                context["sourceSubtitleFormats"] = streams.filter { $0.Type == "Subtitle" }.map { ["codec": $0.Codec ?? "unknown", "language": $0.Language ?? "unknown", "default": $0.IsDefault ?? false, "forced": $0.IsForced ?? false] as [String: Any] }
                if let data = try? await MediaClient.shared.request(ServerURL.endpoint(server.address, "System/Info/Public")),
                   let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { context["serverVersion"] = PlaybackDiagnostic.token(info["Version"] as? String) }
                let video = detail.video(server: server)
                let noSubtitles = UserDefaults.standard.bool(forKey: "glideInvestigationNoSubtitles")
                let useText = UserDefaults.standard.bool(forKey: "glideInvestigationTextSubtitle")
                context["serverSubtitlesDisabled"] = noSubtitles
                context["textSubtitleRequested"] = useText
                let text = streams.first { $0.Type == "Subtitle" && ["srt", "subrip", "vtt", "webvtt"].contains($0.Codec?.lowercased() ?? "") && LanguagePreference.normalized($0.Language) == "zh" }
                if UserDefaults.standard.bool(forKey: "glideInvestigationProduction") {
                    let selection = noSubtitles ? TrackSelection(subtitleIndex: -1) : useText ? TrackSelection(subtitleIndex: text?.Index) : TrackSelection()
                    await productionTrial(video, selection: selection); return
                }
                let qualities: [PlaybackQuality] = UserDefaults.standard.bool(forKey: "glideInvestigationOnlyCompatible") ? [.compatible] : noSubtitles || useText ? [.automatic, .compatible] : [.automatic, .compatible, .hd1080]
                for quality in qualities {
                    MediaClient.qaNegotiationReport = [:]
                    do {
                        let selection = noSubtitles ? TrackSelection(subtitleIndex: -1) : useText ? TrackSelection(subtitleIndex: text?.Index) : TrackSelection()
                        var resource = try await MediaClient.shared.playback(video: video, server: server, quality: quality, tracks: selection)
                        context["negotiation_" + quality.rawValue] = MediaClient.qaNegotiationReport; save()
                        if UserDefaults.standard.bool(forKey: "glideInvestigationNetwork") {
                            context["network_" + quality.rawValue] = await inspectNetwork(resource, server: server); save()
                        }
                        if UserDefaults.standard.bool(forKey: "glideInvestigationMediaOnly"), let variant = firstVariantURL {
                            resource.url = variant; resource.prefersFirstHDRVariant = false
                            context["diagnosticMediaPlaylistOnly"] = true
                        }
                        if UserDefaults.standard.bool(forKey: "glideInvestigationDisableFirstHDR") { resource.prefersFirstHDRVariant = false }
                        await trial(resource, name: quality.rawValue)
                        try? await MediaClient.shared.stopTranscoding(server: server, resource: resource)
                    } catch { context["negotiation_" + quality.rawValue] = MediaClient.qaNegotiationReport; results.append(["route": quality.rawValue, "negotiationErrors": chain(error)]); save() }
                }
                stage = "Jellyfin 原片诊断完成"; save(); return
            } catch { context["metadataErrors"] = chain(error); save() }
        }
        stage = "未找到与诊断匹配的最近视频"; save()
    }
    private func matchesDiagnostic(_ stream: CatalogItem.Stream) -> Bool {
        if (UserDefaults.standard.bool(forKey: "glideInvestigationSubtitleDiagnosis") || ProcessInfo.processInfo.arguments.contains("--glide-ass-investigation")), UserDefaults.standard.string(forKey: "glideInvestigationSeries") != nil { return stream.Type == "Video" }
        guard stream.Type == "Video", stream.Codec?.lowercased() == "hevc" else { return false }
        return stream.Width == 3840 && stream.Height == 2160 && stream.DvProfile == 8
    }
    private func choiceKind(_ choice: SubtitleChoice?) -> String {
        switch choice {
        case nil: "automatic"
        case .off: "off"
        case .embedded: "embedded"
        case .server: "server"
        case .sidecar: "sidecar"
        case .imported: "imported"
        }
    }
}
#endif
