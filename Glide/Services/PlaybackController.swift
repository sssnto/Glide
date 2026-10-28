import AVFoundation
import Observation
import UIKit

@MainActor @Observable
final class PlaybackController {
    @ObservationIgnored private let warmup = PlaybackWarmup()
    func prepareNext(_ video: Video, library: LibraryStore) async {
        guard video.offlineOnly != true, current?.offlineOnly != true else { warmup.cancel(); return }
        guard engine.descriptor.capabilities.contains(.preloading) else { return }
        await warmup.prepare(video, server: library.servers.first { $0.id == video.sourceID })
    }
    func cancelWarmup() { warmup.cancel() }
    @ObservationIgnored private var engine: any PlaybackEngine
    private var engineRevision = 0
    var presentation: PlaybackPresentation { _ = engineRevision; return engine.presentation }
    var engineDescriptor: PlaybackEngineDescriptor { _ = engineRevision; return engine.descriptor }
    var canSwitchEngine: Bool { resource?.url.isFileURL == true && resource?.headers.isEmpty == true && !pictureInPicture.active }
    var externalPlaybackActive: Bool { engine.snapshot.externalPlayback }
    var canPreview: Bool { resource?.url.isFileURL == true && engine.descriptor.capabilities.contains(.timelinePreview) }
    var localInspection: LocalMediaInspection?
    func previewFrame(at time: Double) async -> UIImage? { await engine.preview(at: time) }
    var pendingMomentReference: MomentReference?
    var clip: MediaClip?
    private(set) var clipCompletedCount = 0
    private var clipEnded = false
    private func handleClipBoundary(ended: Bool = false) -> Bool {
        guard let clip else { return false }
        guard !isSeeking, wantsPlayback else { return ended }
        guard ended || engine.snapshot.time >= clip.end else { return false }
        if ended, engine.snapshot.time < clip.end - 0.6 {
            pause(); error = "视频提前结束，未能读到片段终点。请确认文件完整后重试。"; return true
        }
        guard !clipEnded else { return true }
        clipEnded = true; pause(); time = clip.end
        clipCompletedCount += 1
        return true
    }
    /// Only expose a displayed media position after any outstanding seek finishes.
    var navigationPosition: Double? {
        let position = engine.snapshot.time
        guard frameReady, error == nil, pendingSeekTarget == nil, pendingStartPosition == nil,
              position.isFinite, duration.isFinite, duration > 0 else { return nil }
        return max(0, min(position, duration - 0.01))
    }
    /// Read the decoder clock for every display refresh; ASS animations must not use the 4 Hz UI clock.
    var subtitleRenderTime: Double? {
        guard frameReady, error == nil, !isSeeking else { return nil }
        return engine.subtitleClock
    }
    var subtitleVideoMatrix: String {
        guard let stream = resource?.videoStream else { return "" }
        return NativeColorPolicy.isHDR(range: stream.VideoRangeType, transfer: stream.ColorTransfer) ? "hdr" : stream.ColorSpace?.lowercased() ?? ""
    }
    var subtitleVideoSize: CGSize {
        let stream = resource?.videoStream
        if let w = stream?.Width, let h = stream?.Height, w > 0, h > 0 { return CGSize(width: w, height: h) }
        switch engine.presentation {
        case .native(let player):
            if let size = player.currentItem?.presentationSize, size.width > 0, size.height > 0 { return size }
        case .custom:
            let snapshot = engine.snapshot
            if let w = snapshot.width, let h = snapshot.height, w > 0, h > 0 { return CGSize(width: w, height: h) }
        }
        return CGSize(width: 1920, height: 1080)
    }
    var tracks = TrackSelection()
    private var catalogSeekRecovery = CatalogSeekRecovery()
    private var forceOriginalForSeek = false
    private var originalReadyForSeekRecovery = false
    var pictureInPicture = PictureInPicture()
    var diagnostic = PlaybackDiagnostic()
    var currentState = "准备中"
    private var recoveryStep = 0
    private var stallTracker = PlaybackStallTracker()
    private var bufferingStartedAfterFrame = false
    private var hasRebuffered = false
    private var transportRecovery = OriginalTransportRecovery()
    private var attemptStarted = Date()
    private var sessionStarted = Date()
    private var resourceReadyAt: Date?
    private var learnConversionRoute = false
    private var receivedFrame = false
    private var bypassLocalFile = false
    private var pendingStartPosition: Double?
    private var pendingSeekTarget: Double?
    private var seekID = UUID()
    private var bufferingTask: Task<Void, Never>?
    var frameReady: Bool { receivedFrame }
    private var bufferingStarted: Date?
    private var reportCaptured = Date()
    static var lastDiagnostic = PlaybackDiagnostic()
    func attachLayer(_ layer: AVPlayerLayer?) {
        (engine as? NativePlaybackEngine)?.attachLayer(layer)
        if let layer, engine.descriptor.capabilities.contains(.pictureInPicture) { pictureInPicture.attach(layer) }
        else { pictureInPicture.detach() }
    }
    private static var hardwareModel: String {
        var system = utsname(); uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }
    private func state(_ value: String) { currentState = value; diagnostic.state = value }
    private func diagnosticError(_ error: Error) {
        let ns = error as NSError
        diagnostic.errorCode = ns.code
        diagnostic.errorChain = PlaybackFailure.chain(error)
        diagnostic.errorDomain = diagnostic.errorChain?.first?.domain
        let category = ns.domain == NSURLErrorDomain ? "network" : ns.domain == AVFoundationErrorDomain ? "avfoundation" : ns.domain == NSOSStatusErrorDomain ? "osstatus" : ns.domain == "CoreMediaErrorDomain" ? "coremedia" : "application"
        diagnostic.event("error_\(category)_\(ns.code)")
    }

    var current: Video?
    var isPlaying = false
    var completedCount = 0
    var loading = false
    var error: String?
    var syncError: String?
    var playbackNotice: String?
    var recordsProgress = true
    var inspectionMode = false
    private var watchdog: Task<Void, Never>?
    var time: Double = 0
    var duration: Double = 0
    var bufferedRanges: [BufferedRange] = []
    var rate: Float = 1
    var resource: PlaybackResource?
    var supportsTranscoding: Bool {
        guard let current, current.offlineOnly != true, current.remoteID != nil else { return false }
        return library?.servers.first(where: { $0.id == current.sourceID })?.kind.isCatalogSource == true
    }
    var showsOriginalTransport: Bool {
        supportsTranscoding && engine.descriptor.id == .avPlayer && resource?.url.isFileURL == false
            && (resource?.delivery == .direct || resource?.delivery == .videoConversion || resource?.delivery == .serverStream || error != nil)
    }
    var canTryOriginalTransport: Bool {
        showsOriginalTransport && !pictureInPicture.active && !transportRecovery.pending
    }
    var originalTransportTitle: String { transportRecovery.attempted ? "重试原画兼容" : "尝试原画兼容" }
    var originalTransportActive: Bool {
        guard supportsTranscoding, let resource, !resource.url.isFileURL else { return false }
        return [.remux, .audioConversion].contains(resource.delivery)
    }
    var originalTransportDetail: String {
        if pictureInPicture.active { return "请先关闭画中画，再切换传输方式。" }
        if transportRecovery.pending { return "正在准备原画兼容…" }
        if diagnostic.originalTransportOutcome == "returned_to_direct" { return "原画兼容未能启用，可手动重试。" }
        return "保留视频画质，尝试另一种传输方式。"
    }
    var canPlayOnline: Bool { supportsTranscoding && resource?.url.isFileURL == true && !pictureInPicture.active }
    var subtitleOptions: [PlaybackTrack] = []
    var audioOptions: [PlaybackTrack] = []
    var supportsClientPGS: Bool { current?.offlineOnly != true && library?.servers.first(where: { $0.id == current?.sourceID })?.kind == .jellyfin }
    var serverAudioOptions: [CatalogItem.Stream] { resource?.url.isFileURL == false ? resource?.serverAudioStreams ?? [] : [] }
    var selectedServerAudioIndex: Int? {
        resource?.serverAudioIndex ?? serverAudioOptions.first(where: { $0.IsDefault == true })?.Index ?? serverAudioOptions.first?.Index
    }
    var selectedServerAudio: CatalogItem.Stream? { serverAudioOptions.first { $0.Index == selectedServerAudioIndex } }
    var hasAudioOptions: Bool { !serverAudioOptions.isEmpty || !audioOptions.isEmpty }
    var audioMenuValue: String {
        if !serverAudioOptions.isEmpty { return "\(serverAudioOptions.count) 条 · " + (selectedServerAudio?.label ?? "服务器默认") }
        return selectedAudio?.displayName ?? "无可切换音轨"
    }
    func chooseServerAudio(_ stream: CatalogItem.Stream) {
        guard serverAudioOptions.contains(stream), stream.Index != selectedServerAudioIndex,
              let sourceID = resource?.mediaSourceID, !pictureInPicture.active else { return }
        cancelServerSubtitleSelection()
        tracks.mediaSourceID = sourceID; tracks.audioIndex = stream.Index
        restartForServerTracks()
    }
    var selectedSubtitle: PlaybackTrack?
    var selectedAudio: PlaybackTrack?
    var serverSubtitleOptions: [CatalogItem.Stream] { resource?.url.isFileURL == false ? resource?.serverSubtitleStreams ?? [] : [] }
    var selectedServerSubtitleIndex: Int? {
        guard !serverSubtitleOptions.isEmpty, let resource else { return nil }
        if let track = subtitles.serverTrack, track.mediaSourceID == resource.mediaSourceID { return track.index }
        guard subtitles.choice == nil, subtitles.cues.isEmpty, secondarySubtitles.cues.isEmpty, serverBurnsSubtitle else { return nil }
        return URLComponents(url: resource.url, resolvingAgainstBaseURL: false)?.queryItems?
            .last(where: { $0.name.lowercased() == "subtitlestreamindex" })?.value.flatMap(Int.init)
    }
    var selectedServerSubtitle: CatalogItem.Stream? { serverSubtitleOptions.first { $0.Index == selectedServerSubtitleIndex } }
    var serverSubtitlePendingIndex: Int?
    @ObservationIgnored private var serverSubtitleTask: Task<Void, Never>?
    private var serverSubtitleRequest = UUID()
    private var serverBurnsSubtitle: Bool {
        guard let resource else { return false }
        return URLComponents(url: resource.url, resolvingAgainstBaseURL: false)?.queryItems?
            .last(where: { $0.name.lowercased() == "subtitlemethod" })?.value?.lowercased() == "encode"
    }
    @ObservationIgnored private var subtitleCatalogTask: Task<SubtitleCatalog, Error>?
    let subtitles = SubtitleSession()
    let secondarySubtitles = SubtitleSession(lane: .secondary)
    func closeExternalSubtitles() {
        cancelServerSubtitleSelection()
        let restart = serverBurnsSubtitle
        if !serverSubtitleOptions.isEmpty { tracks.subtitleIndex = -1 }
        secondarySubtitles.selectEmbedded(nil, engine: engine.descriptor.id)
        subtitles.selectEmbedded(nil, engine: engine.descriptor.id)
        resource?.serverSubtitleCues = []; resource?.serverBitmapSubtitle = nil; resource?.serverASSSubtitle = nil; resource?.serverSubtitleTrack = nil
        resource?.serverSubtitleName = nil; resource?.serverSubtitleLanguage = nil
        resource?.resolvedTracks = tracks
        if restart { restartForServerTracks() }
    }
    func chooseEmbeddedSubtitle(_ option: PlaybackTrack?) {
        cancelServerSubtitleSelection()
        secondarySubtitles.selectEmbedded(nil, engine: engine.descriptor.id)
        subtitles.selectEmbedded(option, engine: engine.descriptor.id)
    }
    private func cancelServerSubtitleSelection() {
        serverSubtitleRequest = UUID(); serverSubtitleTask?.cancel(); serverSubtitleTask = nil; serverSubtitlePendingIndex = nil
    }
    func chooseServerSubtitle(_ stream: CatalogItem.Stream) {
        guard let video = current, let server = library?.servers.first(where: { $0.id == video.sourceID }),
              let sourceID = resource?.mediaSourceID, serverSubtitleOptions.contains(stream), !pictureInPicture.active else { return }
        cancelServerSubtitleSelection()
        let track = SubtitleServerTrack(mediaSourceID: sourceID, stream: stream)
        if server.kind == .jellyfin, (CatalogSubtitlePolicy.textCodecs.contains(stream.Codec?.lowercased() ?? "") || CatalogSubtitlePolicy.pgsCodecs.contains(stream.Codec?.lowercased() ?? "")),
           !serverBurnsSubtitle, frameReady, error == nil {
            let request = serverSubtitleRequest, load = generation, token = subtitles.beginServerSelection()
            serverSubtitlePendingIndex = stream.Index
            serverSubtitleTask = Task { [weak self] in
                guard let self else { return }
                defer { if request == serverSubtitleRequest { serverSubtitlePendingIndex = nil; serverSubtitleTask = nil } }
                do {
                    let bitmap = CatalogSubtitlePolicy.pgsCodecs.contains(stream.Codec?.lowercased() ?? "")
                        ? try await MediaClient.shared.serverBitmapSubtitle(video: video, server: server, sourceID: sourceID, stream: stream) : nil
                    let ass = ["ass", "ssa"].contains(stream.Codec?.lowercased() ?? "")
                        ? try await MediaClient.shared.serverASSSubtitle(video: video, server: server, sourceID: sourceID, stream: stream) : nil
                    let values: [SubtitleCue]
                    if let ass { values = ass.cues }
                    else if bitmap == nil { values = try await MediaClient.shared.serverSubtitle(video: video, server: server, sourceID: sourceID, stream: stream) }
                    else { values = [] }
                    guard !Task.isCancelled, load == generation, request == serverSubtitleRequest else { return }
                    if let ass {
                        guard subtitles.finishServerASS(ass, track: track, token: token) else { return }
                    } else if let bitmap {
                        guard subtitles.finishServerBitmap(bitmap, track: track, token: token) else { return }
                        subtitles.updateBitmap(at: time)
                    } else { guard subtitles.finishServerSelection(values, track: track, token: token) else { return } }
                    secondarySubtitles.selectEmbedded(nil, engine: engine.descriptor.id)
                    tracks.mediaSourceID = sourceID; tracks.subtitleIndex = stream.Index
                    resource?.resolvedTracks = tracks; resource?.serverSubtitleTrack = track
                    resource?.serverSubtitleCues = values; resource?.serverBitmapSubtitle = bitmap; resource?.serverASSSubtitle = ass; resource?.serverSubtitleName = track.name; resource?.serverSubtitleLanguage = track.language
                    diagnostic.clientSubtitleCueCount = values.count; diagnostic.clientSubtitleLanguage = PlaybackDiagnostic.token(track.language)
                    diagnostic.event("subtitle_server_switched")
                } catch {
                    guard !Task.isCancelled, load == generation, request == serverSubtitleRequest else { return }
                    subtitles.failServerSelection("切换字幕失败：" + error.localizedDescription, token: token)
                }
            }
        } else {
            tracks.mediaSourceID = sourceID; tracks.subtitleIndex = stream.Index
            secondarySubtitles.selectEmbedded(nil, engine: engine.descriptor.id)
            subtitles.selectServer(track)
            restartForServerTracks()
        }
    }
    private func restartForServerTracks() {
        guard let video = current, let library else { return }
        let intent = retryIntent ?? (pendingSeekTarget ?? pendingStartPosition ?? time, wantsPlayback)
        switch subtitles.choice {
        case .off, .sidecar, .imported: tracks.subtitleIndex = -1
        default: break
        }
        recoveryStep = 0; transportRecovery = OriginalTransportRecovery()
        open(video, library: library, resumeAt: intent.position, autoplay: intent.autoplay, recovering: true, recordsProgress: recordsProgress)
    }
    func forgetSubtitles() { subtitles.forget(); secondarySubtitles.forget() }
    let skips = PlaybackSkipSession()
    private(set) var loop: PlaybackLoop?
    private(set) var loopStart: Double?
    private(set) var loopCount = 0
    var loopMessage: String?
    var activeSkip: SkipSegment? { loop == nil && clip == nil ? skips.active(time: time, duration: duration) : nil }
    var isSeeking: Bool { pendingSeekTarget != nil || pendingStartPosition != nil }
    func markLoopStart() {
        guard clip == nil, frameReady, !isSeeking, time.isFinite else { return }
        loop = nil; loopStart = time; loopCount = 0; loopMessage = "已设置起点 A，再播放到终点设置 B。"
    }
    @discardableResult func setLoop(start: Double, end: Double, mode: PlaybackLoop.Mode = .repeating) -> Bool {
        guard clip == nil, frameReady, !isSeeking, let selection = PlaybackLoop(start: start, end: end, duration: duration, mode: mode) else {
            loopMessage = "请选择至少 0.5 秒、位于视频内的区间。"; return false
        }
        loop = selection; loopStart = start; loopCount = 0; loopMessage = nil
        engine.pause(); isPlaying = false
        wantsPlayback = true
        performSeek(start, exact: true, looping: true)
        return true
    }
    func markLoopEnd() { if let start = loopStart { _ = setLoop(start: start, end: time) } }
    func clearLoop() { loop = nil; loopStart = nil; loopCount = 0; loopMessage = nil }
    func seekToSubtitle(_ cue: SubtitleCue) {
        guard subtitles.cues.contains(cue), frameReady, duration > 0 else { return }
        let target = cue.start + subtitles.delay
        guard target.isFinite, cue.end + subtitles.delay > 0, target < duration else { return }
        seek(max(0, target))
    }
    @discardableResult func replaySubtitle(_ cue: SubtitleCue? = nil) -> Bool {
        let selected = cue ?? SubtitleTranscript(cues: subtitles.cues).active(at: time, delay: subtitles.delay)?.cue
        guard let selected, subtitles.cues.contains(selected),
              let range = SubtitleTranscript.Entry(cue: selected).range(delay: subtitles.delay, duration: duration) else {
            loopMessage = "当前没有可重播的主字幕句，或该句不足 0.5 秒。"; return false
        }
        return setLoop(start: range.start, end: range.end, mode: .once)
    }
    private func handleLoopBoundary(ended: Bool = false) -> Bool {
        guard let loop else { return false }
        guard wantsPlayback, !isSeeking, ended || loop.reachedEnd(time, playing: isPlaying, seeking: isSeeking) else { return ended }
        if loop.mode == .once {
            pause(); clearLoop(); loopMessage = "本句重播完成。"
        } else {
            loopCount += 1
            if ended, engine.descriptor.id == .vlc, let video = current, let library {
                // A VLC input that has reached EOF may no longer accept seeks.
                // Reopen the same video at A, retaining this session's loop.
                open(video, library: library, resumeAt: loop.start, autoplay: true, recovering: true, recordsProgress: recordsProgress)
                return true
            }
            engine.pause(); isPlaying = false
            performSeek(loop.start, exact: true, looping: true)
        }
        return true
    }
    func skip(_ segment: SkipSegment) {
        guard loop == nil, frameReady, pendingSeekTarget == nil, segment.valid(duration: duration) else { return }
        skips.consume(segment); seek(segment.target(duration: duration))
    }
    private var library: LibraryStore?
    private var loadTask: Task<Void, Never>?
    private let audioSessionOwner = UUID()
    @ObservationIgnored nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    private var generation = UUID()
    @ObservationIgnored private var reportTail: Task<Void, Never>?
    private var lastReport: Double = 0
    private var wantsPlayback = false
    private var retryIntent: (position: Double, autoplay: Bool)?
    func retry() {
        guard let video = current, let library else { return }
        let intent = retryIntent ?? (pendingSeekTarget ?? pendingStartPosition ?? time, wantsPlayback)
        open(video, library: library, resumeAt: intent.position, autoplay: intent.autoplay, recovering: true, recordsProgress: recordsProgress)
    }
    var isPlaybackRequested: Bool { wantsPlayback }
#if DEBUG
    var qaLoopClock: [String: Any] {
        var value: [String: Any] = ["phase": String(describing: engine.snapshot.phase), "actual": engine.snapshot.time, "duration": engine.snapshot.duration, "requested": wantsPlayback, "seeking": isSeeking, "controllerTime": time]
        if let vlc = engine as? VLCPlaybackEngine { value["sdkTime"] = vlc.cachedSDKTime; value["nativePlaying"] = vlc.isPlaying; value["nativeState"] = vlc.nativeState; value["sdkState"] = vlc.cachedSDKState; value["rate"] = vlc.playbackRate; value["frames"] = vlc.displayedPictures; value["seekTrace"] = vlc.qaSeekSamples }
        return value
    }
#endif
    private var trackPreferencesApplied = false
    private var useLocalTrackPreferences = true
    private var localEngineOverride: PlaybackEngineID?
    init(engine: (any PlaybackEngine)? = nil) {
        self.engine = engine ?? NativePlaybackEngine()
        self.engine.onEvent = { [weak self] event in self?.handle(event) }
        subtitles.onSelection = { [weak self] in
            guard let self else { return }
            if subtitles.choice == nil { trackPreferencesApplied = false }
            refreshTrackOptions()
        }
        secondarySubtitles.onSelection = { [weak self] in self?.refreshTrackOptions() }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
    }
    private func handle(_ event: PlaybackEngineEvent) {
        guard current != nil else { return }
        switch event {
        case .clock:
            refreshTrackOptions()
            let snapshot = engine.snapshot
            guard snapshot.hasItem else { return }
            if pendingSeekTarget == nil && pendingStartPosition == nil { time = snapshot.time }
            if snapshot.duration > 0 || snapshot.ready { duration = snapshot.duration }
            subtitles.updateBitmap(at: time)
            refreshBufferedRanges()
            refreshPlaybackDiagnostic(snapshot)
            markFirstFrameIfReady()
            if handleClipBoundary() || handleLoopBoundary() { return }
            if skips.rule.automatic, wantsPlayback, snapshot.phase == .playing, frameReady, !loading,
               pendingSeekTarget == nil, pendingStartPosition == nil, let segment = activeSkip { skip(segment) }
            if abs(time - lastReport) >= 10 { lastReport = time; save(); report("Progress") }
        case .installed: startReadyItem(); report("")
        case .stateChanged:
            refreshPlaybackDiagnostic(engine.snapshot)
            updatePlaybackState()
        case .ready:
            refreshTrackOptions()
            diagnostic.playerReadySeconds = diagnostic.playerReadySeconds ?? Date().timeIntervalSince(attemptStarted)
            loading = wantsPlayback && !receivedFrame
            startReadyItem(); markFirstFrameIfReady()
        case .frameReady: markFirstFrameIfReady()
        case .ended:
            if !handleClipBoundary(ended: true) && !handleLoopBoundary(ended: true) { pause(); completedCount += 1 }
        case .failed(let failure):
            diagnostic.event("item_failed"); diagnosticError(failure)
            recoverOrFail(engine.descriptor.id == .vlc ? failure.localizedDescription : "当前文件无法播放，请检查网络、媒体格式或服务器转码状态。")
        case .inspection(let report):
            localInspection = report; diagnostic.localMedia = report
            if let message = report.failureMessage, !supportsTranscoding {
                if error != nil { error = message }
                else if !receivedFrame && (report.hasNoVideo || report.playable == false) { recoverOrFail(message, retryable: false) }
            }
        case .diagnostic(let event):
            if event == "network_rebuffer_hold" { warmup.cancel() }
            if event == "network_rebuffer_unproductive" { transportRecovery.unproductiveRefill = true }
            diagnostic.event(event)
        case .output(let output):
            diagnostic.outputVideoCodec = output.codec
            diagnostic.outputColorTransfer = output.transfer; diagnostic.outputColorPrimaries = output.primaries
            diagnostic.outputColorMatrix = output.matrix; diagnostic.outputColorEvidence = output.source
            if output.source == "decodedFrame", NativeColorPolicy.unexpectedHDRTransfer(requestedRange: diagnostic.requestedOutputRange, actualTransfer: output.transfer) {
                diagnostic.event("unexpected_hdr_output")
                recoverOrFail("服务器未返回请求的 SDR 视频。请检查 媒体服务器 HDR 色调映射设置。", videoFailed: true)
            } else if NativeColorPolicy.unsupportedAVCOutput(codec: output.codec, transfer: output.transfer) {
                diagnostic.event("unsupported_avc_hdr_output")
                recoverOrFail("服务器返回的视频色彩格式不兼容。请检查 媒体服务器 HDR 色调映射设置。", videoFailed: true)
            }
        }
    }
    private func refreshPlaybackDiagnostic(_ snapshot: PlaybackEngineSnapshot) {
        guard snapshot.hasItem else { return }
        if let width = snapshot.width, let height = snapshot.height { diagnostic.outputWidth = width; diagnostic.outputHeight = height }
        if let bitrate = snapshot.bitrate { diagnostic.observedBitrate = bitrate }
        diagnostic.indicatedBitrate = snapshot.indicatedBitrate
        diagnostic.droppedVideoFrames = snapshot.droppedVideoFrames
        diagnostic.nativeStalls = snapshot.nativeStalls
        diagnostic.waitingReason = snapshot.waitingReason
        diagnostic.bufferEmpty = snapshot.bufferEmpty
        diagnostic.rebufferCount = snapshot.rebufferCount
        diagnostic.lastResumeBufferedAheadSeconds = snapshot.lastResumeBufferedAhead
        diagnostic.rebufferElapsedSeconds = snapshot.rebufferElapsedSeconds
        diagnostic.lastRebufferSeconds = snapshot.lastRebufferSeconds
        diagnostic.bufferFull = snapshot.bufferFull
        diagnostic.likelyToKeepUp = snapshot.likelyToKeepUp
        diagnostic.nativeTimeControlStatus = snapshot.nativeTimeControlStatus
        diagnostic.accessLogBytesTransferred = snapshot.accessLogBytesTransferred
        diagnostic.accessLogTransferSeconds = snapshot.accessLogTransferSeconds
        diagnostic.activeBufferingSeconds = bufferingStarted.map { max(0, Date().timeIntervalSince($0)) }
    }
    private func updateBufferTarget() {
        guard engine.snapshot.hasItem else { return }
        guard engine.descriptor.id == .avPlayer else { diagnostic.forwardBufferTargetSeconds = nil; return }
        let target = NativePlaybackPolicy.forwardBufferDuration(
            local: resource?.url.isFileURL == true, firstFrame: receivedFrame, rate: rate, rebuffered: hasRebuffered)
        engine.setForwardBuffer(target)
        diagnostic.forwardBufferTargetSeconds = target
    }
    private func markFirstFrameIfReady() {
        guard !receivedFrame, pendingStartPosition == nil, pendingSeekTarget == nil,
              engine.snapshot.ready, engine.snapshot.frameReady else { return }
        receivedFrame = true
        if resource?.delivery == .direct { originalReadyForSeekRecovery = true }
        loading = false
        updateBufferTarget()
        let now = Date(), elapsed = now.timeIntervalSince(attemptStarted)
        diagnostic.firstFrameSeconds = elapsed
        diagnostic.playerReadySeconds = diagnostic.playerReadySeconds ?? elapsed
        diagnostic.totalFirstFrameSeconds = now.timeIntervalSince(sessionStarted)
        diagnostic.attemptSeconds.append(elapsed)
        diagnostic.errorCode = nil; diagnostic.errorDomain = nil; diagnostic.errorChain = nil
        diagnostic.event("first_frame")
        if resource?.delivery == .remux || resource?.delivery == .audioConversion {
            transportRecovery.displayedFrame()
            diagnostic.originalTransportOutcome = "active"
        }
        engine.inspectOutput()
        if learnConversionRoute, resource?.delivery == .videoConversion, supportsTranscoding, let video = current {
            PlaybackRouteMemory().rememberVideoConversion(for: video.id)
            diagnostic.event("route_learned_video_conversion")
            learnConversionRoute = false
        }
        if playbackNotice != nil {
            let token = generation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self, token == self.generation else { return }
                self.playbackNotice = nil
            }
        }
    }
    private func updatePlaybackState() {
        guard current != nil, engine.snapshot.hasItem, error == nil else { return }
        isPlaying = engine.snapshot.phase == .playing
        bufferingTask?.cancel(); bufferingTask = nil
        switch engine.snapshot.phase {
        case .waiting:
            guard wantsPlayback else { loading = false; return }
            if pendingSeekTarget != nil {
                loading = !receivedFrame; state("定位中")
                return
            }
            let token = generation
            // Ignore short transitions caused by a seek or rate change.
            bufferingTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, token == self.generation, self.wantsPlayback,
                      self.pendingSeekTarget == nil, self.engine.snapshot.phase == .waiting else { return }
                self.loading = true
                self.state(self.receivedFrame ? "缓冲中" : "准备画面")
                if self.bufferingStarted == nil {
                    self.bufferingStarted = Date()
                    self.bufferingStartedAfterFrame = self.receivedFrame
                    self.diagnostic.bufferingCount += 1
                }
            }
        case .playing:
            stallTracker = PlaybackStallTracker()
            markFirstFrameIfReady()
            loading = !receivedFrame; state("播放中")
            finishBuffering(evaluateStall: pendingSeekTarget == nil)
        case .paused:
            loading = wantsPlayback && !receivedFrame
            if !wantsPlayback { state("已暂停"); finishBuffering(evaluateStall: false) }
        default: break
        }
    }
    private func finishBuffering(evaluateStall: Bool) {
        guard let start = bufferingStarted else { return }
        let now = Date(), elapsed = now.timeIntervalSince(start)
        diagnostic.bufferingSeconds += elapsed
        diagnostic.activeBufferingSeconds = nil
        bufferingStarted = nil
        let afterFrame = bufferingStartedAfterFrame
        bufferingStartedAfterFrame = false
        if evaluateStall, afterFrame, wantsPlayback, elapsed >= 1.5,
           resource?.url.isFileURL == false, !hasRebuffered {
            hasRebuffered = true
            updateBufferTarget()
            diagnostic.event("buffer_target_increased")
        }
        // This callback runs when playback has already resumed. Keep the
        // working stream; only the watchdog can recover an ongoing stall.
        if evaluateStall, afterFrame, wantsPlayback, elapsed >= 2.5 { diagnostic.event("buffering_recovered") }
    }
    private func startReadyItem() {
        guard engine.snapshot.ready else { return }
        if let clip {
            let actualDuration = engine.snapshot.duration
            guard actualDuration <= 0 || clip.end <= actualDuration + 0.1 else {
                pause(); error = "视频时长已变化，无法播放原片段。请重新选择区间。"; return
            }
            engine.setPlaybackEnd(clip.end)
        }
        if let position = pendingStartPosition {
            pendingStartPosition = nil
            performSeek(position, exact: true)
        } else if pendingSeekTarget == nil && wantsPlayback {
            engine.play(rate: rate)
        }
    }
    private func installEngine(_ id: PlaybackEngineID) {
        guard engine.descriptor.id != id else { return }
        pictureInPicture.detach()
        engine.onEvent = nil
        engine.stop()
        engine = id == .vlc ? VLCPlaybackEngine() : NativePlaybackEngine()
        engine.onEvent = { [weak self] event in self?.handle(event) }
        engineRevision += 1
    }
    func switchEngine(to id: PlaybackEngineID) {
        guard canSwitchEngine, id != engine.descriptor.id, let video = current, let library else { return }
        let position = pendingSeekTarget ?? pendingStartPosition ?? engine.snapshot.time
        let autoplay = error != nil || wantsPlayback
        localEngineOverride = id
        PlaybackPreferences.localEngine = id
        open(video, library: library, resumeAt: position, autoplay: autoplay, recovering: true, recordsProgress: recordsProgress)
    }
    func tryOriginalTransport(automatic: Bool = false) {
        guard canTryOriginalTransport, let video = current, let library, transportRecovery.begin(manual: !automatic) else { return }
        if !automatic { catalogSeekRecovery = CatalogSeekRecovery() }
        let position = pendingSeekTarget ?? pendingStartPosition ?? (error != nil ? retryIntent?.position : nil) ?? engine.snapshot.time
        let autoplay = error != nil ? (retryIntent?.autoplay ?? true) : wantsPlayback
        tracks.mediaSourceID = resource?.mediaSourceID ?? tracks.mediaSourceID
        bypassLocalFile = true; recoveryStep = 1
        diagnostic.recoveryCount += 1; diagnostic.event("transport_retry_original")
        diagnostic.originalTransportAttempts += 1; diagnostic.originalTransportOutcome = "requesting"
        playbackNotice = "正在切换原画传输…"
        open(video, library: library, resumeAt: position, autoplay: autoplay, recovering: true, recordsProgress: recordsProgress)
    }
    func playOnline() {
        guard canPlayOnline, let video = current, let library else { return }
        let position = pendingSeekTarget ?? pendingStartPosition ?? engine.snapshot.time
        bypassLocalFile = true; recoveryStep = 0
        transportRecovery = OriginalTransportRecovery()
        diagnostic.event("online_requested")
        open(video, library: library, resumeAt: position, autoplay: wantsPlayback, recovering: true, recordsProgress: recordsProgress)
    }
    private func refreshTrackOptions() {
        let available = engine.tracks
        subtitleOptions = available.filter { $0.kind == .subtitle }
        audioOptions = available.filter { $0.kind == .audio }
        selectedSubtitle = subtitleOptions.first { $0.id == engine.selectedSubtitleID }
        selectedAudio = audioOptions.first { $0.id == engine.selectedAudioID }
        if !trackPreferencesApplied, engine.snapshot.ready, !available.isEmpty {
          trackPreferencesApplied = true
          if useLocalTrackPreferences {
            if let option = audioOptions.first(where: { !PlaybackPreferences.audioLanguage.isEmpty && LanguagePreference.normalized($0.language) == LanguagePreference.normalized(PlaybackPreferences.audioLanguage) }) { selectAudio(option) }
            if PlaybackPreferences.subtitlesOff || tracks.subtitleIndex == -1 { selectSubtitle(nil) }
            else if let option = subtitleOptions.first(where: { !PlaybackPreferences.subtitleLanguage.isEmpty && LanguagePreference.normalized($0.language) == LanguagePreference.normalized(PlaybackPreferences.subtitleLanguage) && (!PlaybackPreferences.forcedOnly || $0.forced) }) { selectSubtitle(option) }
          } else if tracks.subtitleIndex == -1 { selectSubtitle(nil) }
        }
        if secondarySubtitles.hasBitmap || subtitles.hasBitmap || secondarySubtitles.hasASS || subtitles.hasASS || !secondarySubtitles.cues.isEmpty || !subtitles.cues.isEmpty, engine.snapshot.hasItem {
            if engine.selectedSubtitleID != nil { engine.selectTrack(nil, kind: .subtitle) }
            selectedSubtitle = nil
            return
        }
        if let choice = subtitles.choice, engine.snapshot.hasItem {
            if choice.suppressesEmbedded {
                if engine.selectedSubtitleID != nil { engine.selectTrack(nil, kind: .subtitle) }
                selectedSubtitle = nil
            } else if case .embedded(let saved) = choice,
                      let option = saved.match(in: subtitleOptions, engine: engine.descriptor.id) {
                if engine.selectedSubtitleID != option.id { engine.selectTrack(option.id, kind: .subtitle) }
                selectedSubtitle = option
            }
        }
    }
    func open(_ video: Video, library: LibraryStore, resumeAt: Double? = nil, autoplay: Bool = true, recovering: Bool = false, recordsProgress: Bool = true) {
        let sameVideo = recovering && current?.id == video.id
        let retainedLoop = sameVideo ? loop : nil, retainedStart = sameVideo ? loopStart : nil
        let retainedLoopCount = sameVideo ? loopCount : 0
        let server = video.offlineOnly == true ? nil : library.servers.first { $0.id == video.sourceID }
        let prepared = !recovering && engine.descriptor.capabilities.contains(.preloading) && !tracks.requiresServerSelection ? warmup.take(video, server: server) : nil
        stop()
        loop = retainedLoop; loopStart = retainedStart; loopCount = retainedLoopCount
        let recordsProgress = clip == nil && recordsProgress
        self.recordsProgress = recordsProgress
        if !sameVideo {
            catalogSeekRecovery = CatalogSeekRecovery(); forceOriginalForSeek = false; originalReadyForSeekRecovery = false
            bypassLocalFile = false
            transportRecovery = OriginalTransportRecovery()
            let learnedRoute = server?.kind.isCatalogSource == true && video.remoteID != nil && DownloadStore.shared.localURL(videoID: video.id) == nil
                && PlaybackRouteMemory().prefersVideoConversion(for: video.id)
            recoveryStep = learnedRoute ? 2 : 0; playbackNotice = nil; learnConversionRoute = false
            diagnostic = PlaybackDiagnostic(version: PlaybackPreferences.appVersion, system: UIDevice.current.systemVersion, device: Self.hardwareModel)
            sessionStarted = Date()
            if learnedRoute { diagnostic.event("route_learned_hd1080") }
        }
        if clip?.moment.reference.kind == .catalog { bypassLocalFile = true }
        let requestedQuality = forceOriginalForSeek ? PlaybackQuality.original : AutomaticPlaybackPolicy.quality(at: recoveryStep)
        forceOriginalForSeek = false
        trackPreferencesApplied = false
        useLocalTrackPreferences = requestedQuality == .original || server?.kind.isCatalogSource != true
        diagnostic.requestedQuality = requestedQuality.rawValue
        diagnostic.event("attempt_" + requestedQuality.rawValue)
        diagnostic.localMedia = nil
        diagnostic.firstFrameSeconds = nil; diagnostic.resourceReadySeconds = nil; diagnostic.playerReadySeconds = nil
        diagnostic.outputWidth = nil; diagnostic.outputHeight = nil; diagnostic.observedBitrate = nil; diagnostic.delivery = ""
        diagnostic.sourceBitrate = nil; diagnostic.sourceFrameRate = nil; diagnostic.indicatedBitrate = nil
        diagnostic.droppedVideoFrames = nil; diagnostic.nativeStalls = nil; diagnostic.waitingReason = nil
        diagnostic.bufferEmpty = nil; diagnostic.rebufferCount = nil; diagnostic.lastResumeBufferedAheadSeconds = nil
        diagnostic.rebufferElapsedSeconds = nil; diagnostic.lastRebufferSeconds = nil
        diagnostic.bufferFull = nil; diagnostic.likelyToKeepUp = nil; diagnostic.nativeTimeControlStatus = nil
        diagnostic.accessLogBytesTransferred = nil; diagnostic.accessLogTransferSeconds = nil; diagnostic.activeBufferingSeconds = nil
        diagnostic.outputVideoCodec = nil; diagnostic.outputColorTransfer = nil; diagnostic.playlistMode = nil
        diagnostic.outputColorPrimaries = nil; diagnostic.outputColorMatrix = nil
        diagnostic.outputColorEvidence = nil
        diagnostic.requestedOutputCodec = nil; diagnostic.requestedOutputRange = nil
        diagnostic.forwardBufferTargetSeconds = nil; diagnostic.bufferedAheadSeconds = nil
        diagnostic.sourceKind = nil; diagnostic.subtitleMethod = nil; diagnostic.serverSubtitleIndex = nil
        diagnostic.preferredTextSubtitle = nil; diagnostic.clientSubtitleCueCount = nil; diagnostic.clientSubtitleLanguage = nil
        if !sameVideo { hasRebuffered = false }
        attemptStarted = Date(); resourceReadyAt = nil; receivedFrame = false; bufferingStarted = nil; bufferingStartedAfterFrame = false; stallTracker = PlaybackStallTracker(); state("连接中")
        self.library = library; current = video; loading = true; error = nil; syncError = nil
        let subtitleCatalog = Task { try await SubtitleSource.catalog(video: video, server: server) }
        subtitleCatalogTask = subtitleCatalog
        subtitles.prepare(video: video, server: server, sharedCatalog: subtitleCatalog)
        secondarySubtitles.prepare(video: video, server: server, sharedCatalog: subtitleCatalog)
        if clip == nil { skips.prepare(video: video, server: server, preservingSession: sameVideo) }
        let requestedResume = resumeAt ?? (recordsProgress ? library.resumePosition(video) : 0)
        let resume = clip?.resume(requestedResume) ?? (requestedResume.isFinite ? max(0, requestedResume) : 0)
        clipEnded = false
        if clip != nil || (resumeAt != nil ? resume > 0 : WatchProgress.canResume(position: resume, duration: video.duration)) {
            pendingStartPosition = resume
        }
        time = resume; duration = video.duration; lastReport = resume; wantsPlayback = autoplay
        let token = UUID(); generation = token
        watchdog = Task { [weak self] in
            var lastTime = resume; var unchangedSince = Date()
            var missingFrameSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, token == self.generation else { return }
                self.refreshPlaybackDiagnostic(self.engine.snapshot)
                if self.transportRecovery.unproductiveRefill, !self.transportRecovery.attempted, self.canTryOriginalTransport,
                   self.wantsPlayback,
                   self.pendingSeekTarget == nil, self.pendingStartPosition == nil,
                   self.engine.snapshot.phase == .waiting,
                   BufferedTimeline.ahead(of: self.engine.snapshot.time, in: self.engine.snapshot.buffered) < 2 {
                    self.tryOriginalTransport(automatic: true)
                    return
                }
                // A running audio clock does not prove that video has decoded.
                // Inspect the actual displayed layer, not AVPlayerItem.readyToPlay.
                if self.wantsPlayback, self.engine.snapshot.phase == .playing,
                   !self.engine.snapshot.externalPlayback, !self.engine.snapshot.frameReady {
                    if missingFrameSince == nil { missingFrameSince = Date() }
                    if Date().timeIntervalSince(missingFrameSince!) > 6 {
                        self.diagnostic.event("video_frame_timeout")
                        if self.recoveryStep == 0 && self.resource?.delivery == .direct { self.learnConversionRoute = true }
                        self.recoverOrFail("这部视频的画面无法正常解码。", videoFailed: true)
                        return
                    }
                } else { missingFrameSince = nil }
                if self.wantsPlayback, !self.receivedFrame, self.recoveryStep == 0, self.supportsTranscoding,
                   self.resource?.delivery == .direct, self.engine.snapshot.hasItem,
                   self.engine.snapshot.phase != .playing, let readyAt = self.resourceReadyAt,
                   Date().timeIntervalSince(readyAt) >= AutomaticPlaybackPolicy.directStartupTimeout {
                    self.diagnostic.event("direct_startup_timeout")
                    self.learnConversionRoute = true
                    self.recoverOrFail("原画起播超时，正在切换兼容播放。", stalled: true)
                    return
                }
                let now = Date(), actualTime = self.engine.snapshot.time
                let clock = actualTime.isFinite ? actualTime : self.time
                let progressing = abs(clock - lastTime) > 0.1
                if !self.wantsPlayback || progressing { unchangedSince = now; lastTime = clock }
                if self.receivedFrame {
                    let intentionalWait = !self.wantsPlayback || self.pendingSeekTarget != nil || self.pendingStartPosition != nil
                    let stalled = !intentionalWait && !progressing &&
                        (self.engine.snapshot.phase != .playing || now.timeIntervalSince(unchangedSince) >= 2)
                    let bufferedEnd = clock + BufferedTimeline.ahead(of: clock, in: self.bufferedRanges)
                    if self.stallTracker.shouldRecover(at: now, stalled: stalled, bufferedEnd: bufferedEnd) {
                        self.diagnostic.event("buffer_wait_timeout")
                        self.recoverOrFail("视频持续缓冲，正在恢复播放。", stalled: true)
                        return
                    }
                } else if self.wantsPlayback && now.timeIntervalSince(unchangedSince) > 25 {
                    let directStartup = self.recoveryStep == 0 && self.resource?.delivery == .direct
                    if directStartup { self.learnConversionRoute = true; self.diagnostic.event("direct_startup_timeout") }
                    let message = self.resource?.url.isFileURL == true
                        ? "无法及时读取此文件的视频画面。请检查文件是否完整，或尝试其他兼容视频。"
                        : "视频加载超时，请检查网络或 媒体服务器 服务器。"
                    self.recoverOrFail(message, stalled: directStartup)
                    return
                }
            }
        }
        loadTask = Task { [weak self] in
            guard let self, !Task.isCancelled, token == self.generation else { return }
            do {
                try await PlaybackAudioSession.activate(owner: audioSessionOwner)
                guard !Task.isCancelled, token == generation else { return }
                let resolvedResume = resume
                if let server, server.kind.isCatalogSource {
                    await subtitles.waitUntilPrepared()
                    guard !Task.isCancelled, token == generation else { return }
                    if !bypassLocalFile, DownloadStore.shared.localURL(videoID: video.id) != nil {
                        subtitles.ignoreServerSelectionForLocalPlayback()
                    } else if tracks.subtitleIndex == nil {
                        if case .server(let saved) = subtitles.choice {
                            let detail = try await MediaClient.shared.catalogDetail(server: server, id: video.remoteID ?? "")
                            guard !Task.isCancelled, token == generation else { return }
                            if tracks.mediaSourceID == nil || tracks.mediaSourceID == saved.mediaSourceID,
                               let source = detail.MediaSources?.first(where: { $0.Id == saved.mediaSourceID }),
                               saved.match(in: source.MediaStreams ?? [], mediaSourceID: source.Id) != nil {
                                tracks.mediaSourceID = saved.mediaSourceID; tracks.subtitleIndex = saved.index
                            } else {
                                subtitles.selectEmbedded(nil, engine: engine.descriptor.id)
                                subtitles.message = "已保存的服务器字幕轨道已变化，请重新选择。"; tracks.subtitleIndex = -1
                            }
                        } else if subtitles.choice?.suppressesEmbedded == true || !secondarySubtitles.cues.isEmpty { tracks.subtitleIndex = -1 }
                    }
                }
                if tracks.audioIndex == nil && tracks.subtitleIndex == nil, let server, server.kind.isCatalogSource,
                   (!PlaybackPreferences.audioLanguage.isEmpty || !PlaybackPreferences.subtitleLanguage.isEmpty || PlaybackPreferences.subtitlesOff) {
                    if PlaybackPreferences.subtitlesOff { tracks.subtitleIndex = -1 }
                    if let detail = try? await MediaClient.shared.catalogDetail(server: server, id: video.remoteID ?? "") {
                        guard !Task.isCancelled, token == generation else { return }
                        let streams = detail.MediaSources?.first(where: { self.tracks.mediaSourceID == nil || $0.Id == self.tracks.mediaSourceID })?.MediaStreams ?? []
                        // Raw direct playback selects supported tracks locally after loading.
                        if requestedQuality != .original {
                            tracks.audioIndex = LanguagePreference.stream(streams.filter { $0.Type == "Audio" }, language: PlaybackPreferences.audioLanguage)
                            let subtitles = streams.filter { $0.Type == "Subtitle" }
                            tracks.subtitleIndex = PlaybackPreferences.subtitlesOff ? -1 : server.kind == .jellyfin
                                ? CatalogSubtitlePolicy.preferred(subtitles, language: PlaybackPreferences.subtitleLanguage, forcedOnly: PlaybackPreferences.forcedOnly)
                                : LanguagePreference.stream(subtitles, language: PlaybackPreferences.subtitleLanguage, forcedOnly: PlaybackPreferences.forcedOnly)
                        }
                    }
                }
                guard !Task.isCancelled, token == generation else { return }
                self.time = resolvedResume; self.lastReport = resolvedResume
                self.state("准备画面")
                var selectedQuality = requestedQuality
                var resource: PlaybackResource
                if video.offlineOnly == true {
                    resource = try DownloadStore.shared.offlineResource(video)
                    try await DownloadStore.shared.installOfflineSubtitles(video: video, primary: subtitles, secondary: secondarySubtitles)
                    diagnostic.event("offline_only")
                }
                else if !bypassLocalFile, DownloadStore.shared.canReuse(videoID: video.id, sourceID: tracks.mediaSourceID), let local = DownloadStore.shared.localURL(videoID: video.id) { resource = PlaybackResource(url: local, delivery: .local) }
                else if let prepared, requestedQuality == .automatic { resource = prepared.resource; diagnostic.event("warmup_hit") }
                else { resource = try await MediaClient.shared.playback(video: video, server: server, quality: requestedQuality, tracks: tracks) }
                if !Task.isCancelled, token == generation, server?.kind.isCatalogSource == true, requestedQuality == .automatic,
                   resource.prefersSegmentedTransport, transportRecovery.begin() {
                    // Negotiate the same source before installing any direct item.
                    // Compatible explicitly forbids video encoding and validates copy.
                    let direct = resource
                    tracks.mediaSourceID = direct.mediaSourceID ?? tracks.mediaSourceID
                    recoveryStep = 1; selectedQuality = .compatible
                    diagnostic.originalTransportAttempts += 1; diagnostic.originalTransportOutcome = "requesting"
                    diagnostic.requestedQuality = selectedQuality.rawValue
                    diagnostic.event("transport_preferred_original"); diagnostic.event("attempt_compatible")
                    do {
                        resource = try await MediaClient.shared.playback(video: video, server: server, quality: .compatible, tracks: tracks)
                    } catch {
                        guard !Task.isCancelled, token == generation else { return }
                        diagnosticError(error)
                        diagnostic.originalTransportFailure = PlaybackFailure.chain(error)
                        diagnostic.originalTransportOutcome = "returned_to_direct"
                        _ = transportRecovery.returnToDirectIfPending()
                        recoveryStep = 0; selectedQuality = .automatic
                        diagnostic.requestedQuality = selectedQuality.rawValue
                        diagnostic.event("transport_return_to_direct")
                        resource = direct
                    }
                }
                guard !Task.isCancelled, token == generation else {
                    if let server {
                        if recordsProgress { try? await MediaClient.shared.report("Stopped", video: video, server: server, resource: resource, position: 0, paused: true) }
                        else { try? await MediaClient.shared.stopTranscoding(server: server, resource: resource) }
                    }
                    return
                }
                if let expected = clip?.moment.reference ?? pendingMomentReference {
                    guard expected.videoID == video.id else { throw MediaError.message("时刻对应的视频已变化。") }
                    do { try await MomentResolver.verify(expected, video: video, library: library, resource: resource) }
                    catch {
                        if let server, resource.isTranscoding { try? await MediaClient.shared.stopTranscoding(server: server, resource: resource) }
                        throw error
                    }
                    guard !Task.isCancelled, token == generation else { return }
                    pendingMomentReference = nil
                }
                self.resource = resource
                if let resolved = resource.resolvedTracks { self.tracks = resolved }
                if let name = resource.serverSubtitleName, let track = resource.serverSubtitleTrack {
                    if let ass = resource.serverASSSubtitle { _ = await subtitles.installServerASS(ass, track: track, videoID: video.id) }
                    else if let bitmap = resource.serverBitmapSubtitle { _ = await subtitles.installServerBitmap(bitmap, track: track, videoID: video.id) }
                    else { _ = await subtitles.installServerText(resource.serverSubtitleCues, name: name, track: track, videoID: video.id) }
                    guard !Task.isCancelled, token == generation else { return }
                    diagnostic.clientSubtitleCueCount = subtitles.cues.count
                    diagnostic.clientSubtitleLanguage = resource.serverSubtitleLanguage
                    diagnostic.event("subtitle_client_text")
                }
                if resource.preferredTextSubtitle { playbackNotice = "已使用同语言文字字幕播放。"; diagnostic.event("subtitle_text_preferred") }
                diagnostic.sourceKind = server?.kind.rawValue
                let subtitleQuery = URLComponents(url: resource.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                diagnostic.subtitleMethod = PlaybackDiagnostic.token(subtitleQuery.last { $0.name.lowercased() == "subtitlemethod" }?.value)
                diagnostic.serverSubtitleIndex = subtitleQuery.last { $0.name.lowercased() == "subtitlestreamindex" }?.value.flatMap(Int.init)
                diagnostic.preferredTextSubtitle = resource.preferredTextSubtitle
                diagnostic.directStreamFlag = resource.supportsDirectStream
                let offlineEngine: PlaybackEngineID? = video.offlineOnly == true && resource.url.pathExtension.lowercased() == "mkv" ? .vlc : nil
                let selectedEngine = PlaybackEngineSelection.resolve(preferred: localEngineOverride ?? offlineEngine ?? PlaybackPreferences.localEngine,
                    localFile: resource.url.isFileURL, hasHeaders: !resource.headers.isEmpty, smb: resource.smb != nil)
                installEngine(selectedEngine)
                diagnostic.event("engine_" + engine.descriptor.id.rawValue.lowercased())
                self.resourceReadyAt = Date()
                diagnostic.delivery = resource.url.isFileURL ? PlaybackDelivery.local.title : resource.delivery.title
                diagnostic.videoCodec = PlaybackDiagnostic.token(resource.videoStream?.Codec)
                diagnostic.sourceBitrate = resource.sourceBitrate ?? resource.videoStream?.BitRate
                let frameRate = resource.videoStream?.AverageFrameRate ?? resource.videoStream?.RealFrameRate
                diagnostic.sourceFrameRate = frameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                diagnostic.codecTag = PlaybackDiagnostic.token(resource.videoStream?.CodecTag)
                diagnostic.profile = PlaybackDiagnostic.token(resource.videoStream?.Profile)
                diagnostic.bitDepth = resource.videoStream?.BitDepth
                diagnostic.width = resource.videoStream?.Width; diagnostic.height = resource.videoStream?.Height; diagnostic.level = resource.videoStream?.Level
                diagnostic.videoRangeType = PlaybackDiagnostic.token(resource.videoStream?.VideoRangeType)
                diagnostic.dolbyVisionProfile = resource.videoStream?.DvProfile
                diagnostic.sourceColorTransfer = PlaybackDiagnostic.token(resource.videoStream?.ColorTransfer)
                diagnostic.sourceColorPrimaries = PlaybackDiagnostic.token(resource.videoStream?.ColorPrimaries)
                diagnostic.sourceColorSpace = PlaybackDiagnostic.token(resource.videoStream?.ColorSpace)
                let requestedOutput = NativeColorPolicy.outputOptions(resource.url)
                diagnostic.requestedOutputCodec = requestedOutput.codec; diagnostic.requestedOutputRange = requestedOutput.range
                if requestedOutput.range == "SDR", NativeColorPolicy.isHDR(range: resource.videoStream?.VideoRangeType, transfer: resource.videoStream?.ColorTransfer) {
                    diagnostic.event("hdr_sdr_output_requested")
                }
                if resource.isTranscoding {
                    diagnostic.playlistMode = resource.usesMediaPlaylist ? "media" : "master"
                    if resource.usesMediaPlaylist { diagnostic.event("hls_single_variant") }
                }
                diagnostic.event("resource_ready_" + resource.delivery.rawValue)
                diagnostic.resourceReadySeconds = Date().timeIntervalSince(attemptStarted)
                let buffer = NativePlaybackPolicy.forwardBufferDuration(local: resource.url.isFileURL, firstFrame: false, rate: rate)
                diagnostic.forwardBufferTargetSeconds = engine.descriptor.id == .avPlayer ? buffer : nil
                if resource.prefersFirstHDRVariant { diagnostic.event("hls_hdr_initial_variant") }
                let options = PlaybackEngineOptions(allowsCellular: PlaybackPreferences.cellularPlayback,
                    subtitleScale: PlaybackPreferences.subtitleScale, forwardBuffer: buffer,
                    peakBitrate: selectedQuality == .hd1080 ? 8_000_000 : selectedQuality == .hd720 ? 3_000_000 : 0,
                    inspectWideColor: resource.isTranscoding && NativeColorPolicy.isHDR(range: resource.videoStream?.VideoRangeType, transfer: resource.videoStream?.ColorTransfer))
                var loadOptions = options; loadOptions.muted = inspectionMode; loadOptions.endTime = clip?.end
                try await engine.load(resource, preload: selectedQuality == .automatic && engine.descriptor.capabilities.contains(.preloading) ? prepared : nil, options: loadOptions)
                guard !Task.isCancelled, token == generation else { return }
                refreshTrackOptions()
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                self.diagnostic.event("load_failed_" + self.diagnostic.requestedQuality)
                self.diagnosticError(error)
                self.recoverOrFail(error is URLError ? "连接失败，请检查网络与来源地址。可在播放诊断中查看错误代码。" : error.localizedDescription, retryable: !(error is URLError))
            }
        }
    }
    private func recoverOrFail(_ message: String, stalled: Bool = false, videoFailed: Bool = false, retryable: Bool = true) {
        guard error == nil, let video = current, let library else { return }
        if transportRecovery.returnToDirectIfPending() {
            diagnostic.originalTransportFailure = diagnostic.errorChain
            diagnostic.originalTransportOutcome = "returned_to_direct"
            let position = pendingSeekTarget ?? pendingStartPosition ?? max(time, engine.snapshot.time)
            recoveryStep = 0
            diagnostic.recoveryCount += 1; diagnostic.event("transport_return_to_direct")
            playbackNotice = "原画兼容暂不可用，已返回原画直放。"
            open(video, library: library, resumeAt: position, autoplay: wantsPlayback, recovering: true, recordsProgress: recordsProgress)
            return
        }
        if retryable, resource?.url.isFileURL == true, !bypassLocalFile, supportsTranscoding {
            bypassLocalFile = true
            diagnostic.attemptSeconds.append(Date().timeIntervalSince(attemptStarted))
            diagnostic.recoveryCount += 1; diagnostic.event("local_requires_server")
            recoveryStep = 0
            playbackNotice = "离线文件需要兼容处理，正在连接服务器…"
            open(video, library: library, resumeAt: time, autoplay: wantsPlayback, recovering: true, recordsProgress: recordsProgress)
            return
        }
        let preservingVideo = resource?.delivery == .direct || resource?.delivery == .remux || resource?.delivery == .audioConversion
        if retryable, supportsTranscoding,
           let nextStep = AutomaticPlaybackPolicy.nextStep(after: recoveryStep, stalled: stalled, preservingVideo: preservingVideo,
                                                           videoFailed: videoFailed, canDirectStream: resource?.supportsDirectStream != false && !transportRecovery.attempted) {
            diagnostic.attemptSeconds.append(Date().timeIntervalSince(attemptStarted))
            recoveryStep = nextStep
            diagnostic.recoveryCount += 1; diagnostic.event("recovery_" + String(recoveryStep))
            playbackNotice = "正在优化播放…"
            let actualTime = engine.snapshot.time
            let position = pendingSeekTarget ?? pendingStartPosition ?? (actualTime.isFinite && actualTime > 0 ? actualTime : time)
            let shouldPlay = wantsPlayback
            open(video, library: library, resumeAt: position, autoplay: shouldPlay, recovering: true, recordsProgress: recordsProgress)
        } else {
            diagnostic.attemptSeconds.append(Date().timeIntervalSince(attemptStarted))
            retryIntent = (pendingSeekTarget ?? pendingStartPosition ?? time, wantsPlayback)
            watchdog?.cancel(); loadTask?.cancel(); bufferingTask?.cancel()
            loading = false; wantsPlayback = false; engine.pause(); isPlaying = false
            error = bypassLocalFile ? "此离线文件无法由系统直接播放。请连接 媒体服务器 服务器后重试兼容播放。" : (localInspection?.failureMessage ?? message)
            state("播放失败"); diagnostic.event("failed"); Self.lastDiagnostic = diagnostic
        }
    }
    func play() {
        guard error == nil else { return }
        wantsPlayback = true
        if let clip, clipEnded || time >= clip.end - 0.05 { seek(clip.moment.position) }
        else if duration > 0, time >= duration - 0.3 { seek(0) }
        startReadyItem(); report("Progress")
    }
    func pause() {
        state("已暂停"); wantsPlayback = false; loading = false
        bufferingTask?.cancel(); finishBuffering(evaluateStall: false)
        engine.pause(); isPlaying = false; save(); report("Progress")
    }
    func toggle() { wantsPlayback ? pause() : play() }
    func seek(_ seconds: Double) {
        let bounded = clip.map { max($0.moment.position, min(seconds, $0.end - 0.05)) } ?? seconds
        let target = max(0, min(bounded, duration > 0 ? duration : bounded))
        guard target.isFinite, engine.snapshot.hasItem else { return }
        if let loop, !loop.contains(target) { clearLoop(); loopMessage = "已移出区间，循环已退出。" }
        if !engine.snapshot.ready {
            pendingStartPosition = target; time = target
            return
        }
        pendingStartPosition = nil; clipEnded = false
        performSeek(target, exact: clip != nil)
    }
    private func performSeek(_ target: Double, exact: Bool, looping: Bool = false) {
        guard engine.snapshot.hasItem else { return }
        let tolerance = exact ? 0 : NativePlaybackPolicy.seekTolerance(
            local: resource?.url.isFileURL == true, buffered: BufferedTimeline.contains(target, in: bufferedRanges))
        let token = generation, requestID = UUID()
        seekID = requestID
        pendingSeekTarget = target
        time = target
        bufferingTask?.cancel(); finishBuffering(evaluateStall: false)
        engine.cancelPendingSeeks()
        engine.seek(to: target, tolerance: tolerance) { [weak self] finished, actual in
            Task { @MainActor in
                guard let self, token == self.generation, requestID == self.seekID else { return }
                self.pendingSeekTarget = nil
                if looping, !finished {
                    self.clearLoop(); self.pause(); self.loopMessage = "循环定位未完成，已暂停。请重新定位后再试。"
                    return
                }
                if !finished, self.resource?.smb != nil {
                    self.pendingStartPosition = target
                    self.diagnostic.event("smb_seek_failed")
                    self.recoverOrFail("未能定位到指定位置。请检查 NAS 连接后重试，将保留本次定位位置。", retryable: false)
                    return
                }
                if finished && actual.isFinite { self.time = max(0, actual) }
                if finished, let video = self.current, let library = self.library, let resource = self.resource,
                   let server = library.servers.first(where: { $0.id == video.sourceID }),
                   self.catalogSeekRecovery.returnToOriginal(kind: server.kind, container: resource.sourceContainer,
                       delivery: resource.delivery, originalWasPlayable: self.originalReadyForSeekRecovery, hasServerTracks: self.tracks.requiresServerSelection,
                       target: target, actual: actual, tolerance: tolerance) {
                    let autoplay = self.wantsPlayback
                    self.time = target // Persist the requested position before closing the bad stream.
                    self.forceOriginalForSeek = true; self.recoveryStep = 0; self.bypassLocalFile = true
                    self.diagnostic.recoveryCount += 1; self.diagnostic.event("emby_seek_return_to_original")
                    self.diagnostic.originalTransportOutcome = "returned_to_direct"
                    self.playbackNotice = "原画兼容流定位有偏差，正在用原文件恢复该位置。"
                    self.open(video, library: library, resumeAt: target, autoplay: autoplay, recovering: true, recordsProgress: self.recordsProgress)
                    return
                }
                if let clip = self.clip, !finished || !actual.isFinite || actual < clip.moment.position - 0.25 || actual >= clip.end {
                    self.pause(); self.error = "未能准确定位到片段区间，已暂停。请重试或观看完整视频。"; return
                }
                if self.wantsPlayback { self.engine.play(rate: self.rate) }
                self.markFirstFrameIfReady()
                self.updatePlaybackState()
            }
        }
    }
    private func refreshBufferedRanges() {
        let snapshot = engine.snapshot
        if bufferedRanges != snapshot.buffered { bufferedRanges = snapshot.buffered }
        diagnostic.bufferedAheadSeconds = BufferedTimeline.ahead(of: snapshot.time, in: snapshot.buffered)
    }
    func setRate(_ value: Float) {
        guard value.isFinite, value > 0 else { return }
        rate = value
        updateBufferTarget()
        engine.setRate(value, playing: wantsPlayback)
    }
    func selectSubtitle(_ option: PlaybackTrack?) {
        engine.selectTrack(option?.id, kind: .subtitle); selectedSubtitle = subtitleOptions.first { $0.id == self.engine.selectedSubtitleID }
    }
    func selectAudio(_ option: PlaybackTrack) {
        engine.selectTrack(option.id, kind: .audio); selectedAudio = audioOptions.first { $0.id == self.engine.selectedAudioID }
    }
    func save() {
        guard recordsProgress else { return }
        if var current {
            if duration.isFinite && duration > 0 { current.duration = duration }
            library?.savePosition(current, time: time)
        }
    }
    func report(_ event: String) {
        guard recordsProgress else { return }
        guard let video = current, let server = library?.servers.first(where: { $0.id == video.sourceID }), server.kind.isCatalogSource, let resource, !resource.url.isFileURL else { return }
        let position = time, paused = !wantsPlayback, token = generation, capturedAt = Date()
        let previous = reportTail
        reportTail = Task { [weak self] in
            await previous?.value
            do {
                try await MediaClient.shared.report(event, video: video, server: server, resource: resource, position: position, paused: paused)
                if let self { self.library?.acknowledgeProgress(video.id, position: position, capturedAt: capturedAt); if self.generation == token { self.syncError = nil } }
            }
            catch { if let self, self.generation == token { self.syncError = "观看进度暂未同步到服务器，已保存在本机。" } }
        }
    }
    func stop() {
        cancelServerSubtitleSelection()
        clearLoop()
        skips.cancel()
        subtitleCatalogTask?.cancel(); subtitleCatalogTask = nil
        subtitles.cancel(); secondarySubtitles.cancel()
        retryIntent = nil
        warmup.cancel()
        Self.lastDiagnostic = diagnostic
        watchdog?.cancel(); watchdog = nil
        bufferingTask?.cancel(); bufferingTask = nil
        pendingSeekTarget = nil; pendingStartPosition = nil; seekID = UUID()
        save()
        if recordsProgress { report("Stopped") }
        else if let video = current, let server = library?.servers.first(where: { $0.id == video.sourceID }), let resource {
            Task { try? await MediaClient.shared.stopTranscoding(server: server, resource: resource) }
        }
        generation = UUID(); loadTask?.cancel(); loadTask = nil
        wantsPlayback = false
        engine.stop(); localInspection = nil
        resource = nil; current = nil; isPlaying = false; loading = false; bufferedRanges = []
        subtitleOptions = []; audioOptions = []; selectedSubtitle = nil; selectedAudio = nil
    }
    func close() {
        stop(); clip = nil
        PlaybackAudioSession.release(owner: audioSessionOwner)
    }
    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        let owner = audioSessionOwner
        Task { @MainActor in PlaybackAudioSession.release(owner: owner) }
    }
}
