import AVFoundation
import Observation
import UIKit

@MainActor @Observable
final class PlaybackController {
    @ObservationIgnored private let warmup = PlaybackWarmup()
    func prepareNext(_ video: Video, library: LibraryStore) async {
        await warmup.prepare(video, server: library.servers.first { $0.id == video.sourceID })
    }
    func cancelWarmup() { warmup.cancel() }
    let player = AVPlayer()
    @ObservationIgnored weak var videoLayer: AVPlayerLayer?
    var tracks = TrackSelection()
    var pictureInPicture = PictureInPicture()
    var diagnostic = PlaybackDiagnostic()
    var currentState = "准备中"
    private var recoveryStep = 0
    private var stallTracker = PlaybackStallTracker()
    private var bufferingStartedAfterFrame = false
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
    func attachLayer(_ layer: AVPlayerLayer) {
        guard videoLayer !== layer else { return }
        videoLayer = layer
        pictureInPicture.attach(layer)
        layerObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.markFirstFrameIfReady() }
        }
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
    private var watchdog: Task<Void, Never>?
    var time: Double = 0
    var duration: Double = 0
    var bufferedRanges: [BufferedRange] = []
    var rate: Float = 1
    var resource: PlaybackResource?
    var supportsTranscoding: Bool {
        guard let current, current.remoteID != nil else { return false }
        return library?.servers.first(where: { $0.id == current.sourceID })?.kind == .jellyfin
    }
    var subtitleOptions: [AVMediaSelectionOption] = []
    var audioOptions: [AVMediaSelectionOption] = []
    var selectedSubtitle: AVMediaSelectionOption?
    var selectedAudio: AVMediaSelectionOption?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var audioGroup: AVMediaSelectionGroup?
    private var library: LibraryStore?
    private var authenticated: AuthenticatedAsset?
    private var loadTask: Task<Void, Never>?
    private var formatTask: Task<Void, Never>?
    private var colorProbe: AVPlayerItemVideoOutput?
    private let audioSessionOwner = UUID()
    @ObservationIgnored nonisolated(unsafe) private var observer: Any?
    private var itemObservation: NSKeyValueObservation?
    private var loadedRangesObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var layerObservation: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    private var generation = UUID()
    @ObservationIgnored private var reportTail: Task<Void, Never>?
    private var lastReport: Double = 0
    private var wantsPlayback = false
    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.player.currentItem != nil else { return }
                let elapsed = self.player.currentTime().seconds
                if self.pendingSeekTarget == nil && self.pendingStartPosition == nil && elapsed.isFinite {
                    self.time = max(0, elapsed)
                }
                let duration = self.player.currentItem?.duration.seconds ?? 0
                if duration.isFinite { self.duration = max(0, duration) }
                if let item = self.player.currentItem {
                    self.refreshBufferedRanges(for: item)
                    let size = item.presentationSize
                    if size.width > 0 && size.height > 0 { self.diagnostic.outputWidth = Int(size.width); self.diagnostic.outputHeight = Int(size.height) }
                    if let bitrate = item.accessLog()?.events.last?.observedBitrate, bitrate.isFinite && bitrate > 0 { self.diagnostic.observedBitrate = Int(bitrate) }
                }
                self.markFirstFrameIfReady()
                if abs(self.time - self.lastReport) >= 10 {
                    self.lastReport = self.time; self.save(); self.report("Progress")
                }
            }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updatePlaybackState() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                self.pause(); self.completedCount += 1
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
    }
    private func updateBufferTarget() {
        guard let item = player.currentItem else { return }
        item.preferredForwardBufferDuration = NativePlaybackPolicy.forwardBufferDuration(
            local: resource?.url.isFileURL == true, firstFrame: receivedFrame, rate: rate)
    }
    private func markFirstFrameIfReady() {
        guard !receivedFrame, pendingStartPosition == nil, pendingSeekTarget == nil,
              player.currentItem?.status == .readyToPlay,
              videoLayer?.player === player, videoLayer?.isReadyForDisplay == true else { return }
        receivedFrame = true
        loading = false
        updateBufferTarget()
        let now = Date(), elapsed = now.timeIntervalSince(attemptStarted)
        diagnostic.firstFrameSeconds = elapsed
        diagnostic.playerReadySeconds = diagnostic.playerReadySeconds ?? elapsed
        diagnostic.totalFirstFrameSeconds = now.timeIntervalSince(sessionStarted)
        diagnostic.attemptSeconds.append(elapsed)
        diagnostic.errorCode = nil; diagnostic.errorDomain = nil; diagnostic.errorChain = nil
        diagnostic.event("first_frame")
        inspectOutputFormat()
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
    private func inspectOutputFormat() {
        guard let item = player.currentItem else { return }
        let token = generation
        formatTask?.cancel()
        formatTask = Task { [weak self] in
            // HLS tracks may only become available after the first decoded frame.
            for _ in 0..<4 {
                guard !Task.isCancelled else { return }
                guard let self, token == generation, item === player.currentItem else { return }
                if let probe = colorProbe,
                   let frame = probe.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) {
                    // Preserve wide color in this diagnostic output. These are
                    // decoded-frame attachments, not compressed codec evidence.
                    diagnostic.outputColorTransfer = PlaybackDiagnostic.token(CVBufferCopyAttachment(frame, kCVImageBufferTransferFunctionKey, nil) as? String)
                    diagnostic.outputColorPrimaries = PlaybackDiagnostic.token(CVBufferCopyAttachment(frame, kCVImageBufferColorPrimariesKey, nil) as? String)
                    diagnostic.outputColorMatrix = PlaybackDiagnostic.token(CVBufferCopyAttachment(frame, kCVImageBufferYCbCrMatrixKey, nil) as? String)
                    diagnostic.outputColorEvidence = "decodedFrame"
                    item.remove(probe); colorProbe = nil
                    if NativeColorPolicy.unexpectedHDRTransfer(requestedRange: diagnostic.requestedOutputRange, actualTransfer: diagnostic.outputColorTransfer) {
                        diagnostic.event("unexpected_hdr_output")
                        recoverOrFail("服务器未返回请求的 SDR 视频。请检查 Jellyfin HDR 色调映射设置。", videoFailed: true)
                        return
                    }
                }
                if let format = await Self.videoFormat(for: item) {
                    guard !Task.isCancelled, token == generation, item === player.currentItem else { return }
                    let subtype = CMFormatDescriptionGetMediaSubType(format)
                    let bytes = [UInt8((subtype >> 24) & 255), UInt8((subtype >> 16) & 255), UInt8((subtype >> 8) & 255), UInt8(subtype & 255)]
                    diagnostic.outputVideoCodec = PlaybackDiagnostic.token(String(bytes: bytes, encoding: .ascii))
                    // HLS track descriptions can expose only codec/matrix. Do
                    // not discard a pending frame probe or overwrite its color
                    // attachments with missing track metadata.
                    if diagnostic.outputColorEvidence != "decodedFrame" {
                        diagnostic.outputColorTransfer = PlaybackDiagnostic.token(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String)
                        diagnostic.outputColorPrimaries = PlaybackDiagnostic.token(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String)
                        diagnostic.outputColorMatrix = PlaybackDiagnostic.token(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String)
                        if diagnostic.outputColorTransfer != nil { diagnostic.outputColorEvidence = "compressedTrack" }
                    }
                    if NativeColorPolicy.unsupportedAVCOutput(codec: diagnostic.outputVideoCodec, transfer: diagnostic.outputColorTransfer) {
                        diagnostic.event("unsupported_avc_hdr_output")
                        recoverOrFail("服务器返回的视频色彩格式不兼容。请检查 Jellyfin HDR 色调映射设置。", videoFailed: true)
                        return
                    }
                    if diagnostic.outputColorTransfer != nil {
                        if let probe = colorProbe { item.remove(probe); colorProbe = nil }
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled, let self, token == generation else { return }
            if let probe = colorProbe { item.remove(probe); colorProbe = nil }
            if diagnostic.outputColorTransfer == nil { diagnostic.event("output_color_unavailable") }
            if diagnostic.outputVideoCodec == nil { diagnostic.event("output_codec_unavailable") }
        }
    }
    private static func videoFormat(for item: AVPlayerItem) async -> CMFormatDescription? {
        // AVURLAsset inspection can return no tracks for HLS. Inspect the
        // tracks actually presented by the player item before file metadata.
        for track in item.tracks.compactMap(\.assetTrack) {
            guard !Task.isCancelled else { return nil }
            if track.mediaType == .video,
               let formats = try? await track.load(.formatDescriptions), let format = formats.first {
                return format
            }
        }
        guard !Task.isCancelled,
              let track = try? await item.asset.loadTracks(withMediaType: .video).first else { return nil }
        return try? await track.load(.formatDescriptions).first
    }
    private func updatePlaybackState() {
        guard current != nil, player.currentItem != nil, error == nil else { return }
        isPlaying = player.timeControlStatus == .playing
        bufferingTask?.cancel(); bufferingTask = nil
        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
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
                      self.pendingSeekTarget == nil, self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
                self.loading = true
                self.state(self.receivedFrame ? "缓冲中" : "准备画面")
                if self.bufferingStarted == nil {
                    self.bufferingStarted = Date()
                    self.bufferingStartedAfterFrame = self.receivedFrame
                    self.diagnostic.bufferingCount += 1
                }
            }
        case .playing:
            markFirstFrameIfReady()
            loading = !receivedFrame; state("播放中")
            finishBuffering(evaluateStall: pendingSeekTarget == nil)
        case .paused:
            loading = wantsPlayback && !receivedFrame
            if !wantsPlayback { state("已暂停"); finishBuffering(evaluateStall: false) }
        @unknown default: break
        }
    }
    private func finishBuffering(evaluateStall: Bool) {
        guard let start = bufferingStarted else { return }
        let now = Date(), elapsed = now.timeIntervalSince(start)
        diagnostic.bufferingSeconds += elapsed
        bufferingStarted = nil
        let afterFrame = bufferingStartedAfterFrame
        bufferingStartedAfterFrame = false
        if evaluateStall, afterFrame, wantsPlayback, stallTracker.record(at: now, duration: elapsed) {
            recoverOrFail("当前网络无法稳定播放这部视频。", stalled: true)
        }
    }
    private func startReadyItem() {
        guard player.currentItem?.status == .readyToPlay else { return }
        if let position = pendingStartPosition {
            pendingStartPosition = nil
            performSeek(position, exact: true)
        } else if pendingSeekTarget == nil && wantsPlayback {
            player.defaultRate = rate; player.play()
        }
    }
    func open(_ video: Video, library: LibraryStore, resumeAt: Double? = nil, autoplay: Bool = true, recovering: Bool = false, recordsProgress: Bool = true) {
        let sameVideo = recovering && current?.id == video.id
        let server = library.servers.first { $0.id == video.sourceID }
        let prepared = !recovering && !tracks.requiresServerSelection ? warmup.take(video, server: server) : nil
        stop()
        self.recordsProgress = recordsProgress
        if !sameVideo {
            bypassLocalFile = false
            let learnedRoute = server?.kind == .jellyfin && video.remoteID != nil && DownloadStore.shared.localURL(videoID: video.id) == nil
                && PlaybackRouteMemory().prefersVideoConversion(for: video.id)
            recoveryStep = learnedRoute ? 2 : 0; playbackNotice = nil; learnConversionRoute = false
            diagnostic = PlaybackDiagnostic(version: PlaybackPreferences.appVersion, system: UIDevice.current.systemVersion, device: Self.hardwareModel)
            diagnostic.event("engine_avplayer")
            sessionStarted = Date()
            if learnedRoute { diagnostic.event("route_learned_hd1080") }
        }
        let requestedQuality = AutomaticPlaybackPolicy.quality(at: recoveryStep)
        diagnostic.requestedQuality = requestedQuality.rawValue
        diagnostic.event("attempt_" + requestedQuality.rawValue)
        diagnostic.firstFrameSeconds = nil; diagnostic.resourceReadySeconds = nil; diagnostic.playerReadySeconds = nil
        diagnostic.outputWidth = nil; diagnostic.outputHeight = nil; diagnostic.observedBitrate = nil; diagnostic.delivery = ""
        diagnostic.outputVideoCodec = nil; diagnostic.outputColorTransfer = nil; diagnostic.playlistMode = nil
        diagnostic.outputColorPrimaries = nil; diagnostic.outputColorMatrix = nil
        diagnostic.outputColorEvidence = nil
        diagnostic.requestedOutputCodec = nil; diagnostic.requestedOutputRange = nil
        attemptStarted = Date(); resourceReadyAt = nil; receivedFrame = false; bufferingStarted = nil; bufferingStartedAfterFrame = false; stallTracker = PlaybackStallTracker(); state("连接中")
        self.library = library; current = video; loading = true; error = nil; syncError = nil
        // Let AVPlayer wait for playable media before advancing its clock. For
        // remote HLS, forcing immediate playback can leave the item at 00:00
        // and trigger the recovery watchdog before a segment is available.
        player.automaticallyWaitsToMinimizeStalling = true
        let requestedResume = recordsProgress ? (resumeAt ?? library.resumePosition(video)) : (recovering ? (resumeAt ?? 0) : 0)
        let resume = requestedResume.isFinite ? max(0, requestedResume) : 0
        if resumeAt != nil ? resume > 0 : WatchProgress.canResume(position: resume, duration: video.duration) {
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
                // A running audio clock does not prove that video has decoded.
                // Inspect the actual displayed layer, not AVPlayerItem.readyToPlay.
                if self.wantsPlayback, self.player.timeControlStatus == .playing,
                   let layer = self.videoLayer, layer.player === self.player,
                   !self.player.isExternalPlaybackActive, !layer.isReadyForDisplay {
                    if missingFrameSince == nil { missingFrameSince = Date() }
                    if Date().timeIntervalSince(missingFrameSince!) > 6 {
                        self.diagnostic.event("video_frame_timeout")
                        if self.recoveryStep == 0 && self.resource?.delivery == .direct { self.learnConversionRoute = true }
                        self.recoverOrFail("这部视频的画面无法正常解码。", videoFailed: true)
                        return
                    }
                } else { missingFrameSince = nil }
                if self.wantsPlayback, !self.receivedFrame, self.recoveryStep == 0, self.supportsTranscoding,
                   self.resource?.delivery == .direct, self.player.currentItem != nil,
                   self.player.timeControlStatus != .playing, let readyAt = self.resourceReadyAt,
                   Date().timeIntervalSince(readyAt) >= AutomaticPlaybackPolicy.directStartupTimeout {
                    self.diagnostic.event("direct_startup_timeout")
                    self.learnConversionRoute = true
                    self.recoverOrFail("原画起播超时，正在切换兼容播放。", stalled: true)
                    return
                }
                if !self.wantsPlayback || abs(self.time - lastTime) > 0.1 { unchangedSince = Date(); lastTime = self.time }
                if self.wantsPlayback && Date().timeIntervalSince(unchangedSince) > 25 {
                    let directStartup = !self.receivedFrame && self.recoveryStep == 0 && self.resource?.delivery == .direct
                    if directStartup { self.learnConversionRoute = true; self.diagnostic.event("direct_startup_timeout") }
                    self.recoverOrFail("视频加载超时，请检查网络或 Jellyfin 服务器。", stalled: self.receivedFrame || directStartup)
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
                if tracks.audioIndex == nil && tracks.subtitleIndex == nil, let server, server.kind == .jellyfin,
                   (!PlaybackPreferences.audioLanguage.isEmpty || !PlaybackPreferences.subtitleLanguage.isEmpty || PlaybackPreferences.subtitlesOff) {
                    if PlaybackPreferences.subtitlesOff { tracks.subtitleIndex = -1 }
                    if let detail = try? await MediaClient.shared.catalogDetail(server: server, id: video.remoteID ?? "") {
                        guard !Task.isCancelled, token == generation else { return }
                        let streams = detail.MediaSources?.first(where: { self.tracks.mediaSourceID == nil || $0.Id == self.tracks.mediaSourceID })?.MediaStreams ?? []
                        // Raw direct playback selects supported tracks locally after loading.
                        if requestedQuality != .original {
                            tracks.audioIndex = LanguagePreference.stream(streams.filter { $0.Type == "Audio" }, language: PlaybackPreferences.audioLanguage)
                            tracks.subtitleIndex = PlaybackPreferences.subtitlesOff ? -1 : LanguagePreference.stream(streams.filter { $0.Type == "Subtitle" }, language: PlaybackPreferences.subtitleLanguage, forcedOnly: PlaybackPreferences.forcedOnly)
                        }
                    }
                }
                guard !Task.isCancelled, token == generation else { return }
                self.time = resolvedResume; self.lastReport = resolvedResume
                self.state("准备画面")
                let resource: PlaybackResource
                if !bypassLocalFile, let local = DownloadStore.shared.localURL(videoID: video.id) { resource = PlaybackResource(url: local, delivery: .local) }
                else if let prepared, requestedQuality == .automatic { resource = prepared.resource; diagnostic.event("warmup_hit") }
                else { resource = try await MediaClient.shared.playback(video: video, server: server, quality: requestedQuality, tracks: tracks) }
                guard !Task.isCancelled, token == generation else {
                    if let server {
                        if recordsProgress { try? await MediaClient.shared.report("Stopped", video: video, server: server, resource: resource, position: 0, paused: true) }
                        else { try? await MediaClient.shared.stopTranscoding(server: server, resource: resource) }
                    }
                    return
                }
                self.resource = resource
                self.resourceReadyAt = Date()
                diagnostic.delivery = resource.url.isFileURL ? PlaybackDelivery.local.title : resource.delivery.title
                diagnostic.videoCodec = PlaybackDiagnostic.token(resource.videoStream?.Codec)
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
                let asset: AVURLAsset
                if let prepared, requestedQuality == .automatic, resource.url == prepared.resource.url { asset = prepared.asset; self.authenticated = prepared.loader }
                else if resource.headers.isEmpty { asset = AVURLAsset(url: resource.url, options: [AVURLAssetAllowsCellularAccessKey: PlaybackPreferences.cellularPlayback]) }
                else { let loader = AuthenticatedAsset(url: resource.url, headers: resource.headers, allowsCellular: PlaybackPreferences.cellularPlayback); self.authenticated = loader; asset = loader.asset }
                let item = AVPlayerItem(asset: asset)
                if resource.prefersFirstHDRVariant {
                    item.startsOnFirstEligibleVariant = true
                    diagnostic.event("hls_hdr_initial_variant")
                }
                if resource.isTranscoding, NativeColorPolicy.isHDR(range: resource.videoStream?.VideoRangeType, transfer: resource.videoStream?.ColorTransfer) {
                    let probe = AVPlayerItemVideoOutput(outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, AVVideoAllowWideColorKey: true])
                    colorProbe = probe; item.add(probe)
                }
                if let rule = AVTextStyleRule(textMarkupAttributes: [kCMTextMarkupAttribute_RelativeFontSize as String: PlaybackPreferences.subtitleScale]) { item.textStyleRules = [rule] }
                item.preferredForwardBufferDuration = NativePlaybackPolicy.forwardBufferDuration(local: resource.url.isFileURL, firstFrame: false, rate: rate)
                if requestedQuality == .hd1080 { item.preferredPeakBitRate = 8_000_000 }
                if requestedQuality == .hd720 { item.preferredPeakBitRate = 3_000_000 }
                self.itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
                    Task { @MainActor in
                        guard let self, token == self.generation, observed === self.player.currentItem else { return }
                        if observed.status == .failed {
                            self.diagnostic.event("item_failed")
                            if let error = observed.error { self.diagnosticError(error) }
                            self.recoverOrFail("当前文件无法播放，请检查网络、媒体格式或服务器转码状态。")
                        } else if observed.status == .readyToPlay {
                            self.diagnostic.playerReadySeconds = self.diagnostic.playerReadySeconds ?? Date().timeIntervalSince(self.attemptStarted)
                            self.loading = self.wantsPlayback && !self.receivedFrame
                            self.startReadyItem()
                            self.markFirstFrameIfReady()
                        }
                    }
                }
                player.replaceCurrentItem(with: item)
                self.loadedRangesObservation = item.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self] observed, _ in
                    Task { @MainActor in
                        guard let self, token == self.generation else { return }
                        self.refreshBufferedRanges(for: observed)
                    }
                }
                startReadyItem()
                report("")
                let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
                let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
                guard !Task.isCancelled, token == generation, item === player.currentItem else { return }
                subtitleGroup = subtitles; audioGroup = audio
                subtitleOptions = subtitles?.options ?? []; audioOptions = audio?.options ?? []
                if let subtitles { selectedSubtitle = item.currentMediaSelection.selectedMediaOption(in: subtitles) }
                if let audio { selectedAudio = item.currentMediaSelection.selectedMediaOption(in: audio) }
                if requestedQuality == .original || server?.kind != .jellyfin {
                    if let option = audioOptions.first(where: { !PlaybackPreferences.audioLanguage.isEmpty && LanguagePreference.normalized($0.extendedLanguageTag) == LanguagePreference.normalized(PlaybackPreferences.audioLanguage) }) { selectAudio(option) }
                    if PlaybackPreferences.subtitlesOff || tracks.subtitleIndex == -1 { selectSubtitle(nil) }
                    else if let option = subtitleOptions.first(where: { !PlaybackPreferences.subtitleLanguage.isEmpty && LanguagePreference.normalized($0.extendedLanguageTag) == LanguagePreference.normalized(PlaybackPreferences.subtitleLanguage) && (!PlaybackPreferences.forcedOnly || $0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)) }) { selectSubtitle(option) }
                } else if tracks.subtitleIndex == -1 {
                    selectSubtitle(nil)
                }
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                self.diagnostic.event("load_failed_" + requestedQuality.rawValue)
                self.diagnosticError(error)
                self.recoverOrFail(error is URLError ? "连接失败，请检查网络与来源地址。可在播放诊断中查看错误代码。" : error.localizedDescription, retryable: !(error is URLError))
            }
        }
    }
    private func recoverOrFail(_ message: String, stalled: Bool = false, videoFailed: Bool = false, retryable: Bool = true) {
        guard error == nil, let video = current, let library else { return }
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
                                                           videoFailed: videoFailed, canDirectStream: resource?.supportsDirectStream != false) {
            diagnostic.attemptSeconds.append(Date().timeIntervalSince(attemptStarted))
            recoveryStep = nextStep
            diagnostic.recoveryCount += 1; diagnostic.event("recovery_" + String(recoveryStep))
            playbackNotice = "正在优化播放…"
            let actualTime = player.currentTime().seconds
            let position = pendingSeekTarget ?? pendingStartPosition ?? (actualTime.isFinite && actualTime > 0 ? actualTime : time)
            let shouldPlay = wantsPlayback
            open(video, library: library, resumeAt: position, autoplay: shouldPlay, recovering: true, recordsProgress: recordsProgress)
        } else {
            diagnostic.attemptSeconds.append(Date().timeIntervalSince(attemptStarted))
            watchdog?.cancel(); loadTask?.cancel(); bufferingTask?.cancel()
            loading = false; wantsPlayback = false; player.pause(); isPlaying = false
            error = bypassLocalFile ? "此离线文件无法由系统直接播放。请连接 Jellyfin 服务器后重试兼容播放。" : message
            state("播放失败"); diagnostic.event("failed"); Self.lastDiagnostic = diagnostic
        }
    }
    func play() {
        guard error == nil else { return }
        wantsPlayback = true
        if duration > 0, time >= duration - 0.3 { seek(0) }
        startReadyItem(); report("Progress")
    }
    func pause() {
        state("已暂停"); wantsPlayback = false; loading = false
        bufferingTask?.cancel(); finishBuffering(evaluateStall: false)
        player.pause(); isPlaying = false; save(); report("Progress")
    }
    func toggle() { wantsPlayback ? pause() : play() }
    func seek(_ seconds: Double) {
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        guard target.isFinite, player.currentItem != nil else { return }
        if player.currentItem?.status != .readyToPlay {
            pendingStartPosition = target; time = target
            return
        }
        pendingStartPosition = nil
        performSeek(target, exact: false)
    }
    private func performSeek(_ target: Double, exact: Bool) {
        guard let item = player.currentItem else { return }
        let tolerance = CMTime(seconds: exact ? 0 : NativePlaybackPolicy.seekTolerance(
            local: resource?.url.isFileURL == true, buffered: BufferedTimeline.contains(target, in: bufferedRanges)), preferredTimescale: 600)
        let token = generation, requestID = UUID()
        seekID = requestID
        pendingSeekTarget = target
        time = target
        bufferingTask?.cancel(); finishBuffering(evaluateStall: false)
        item.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor in
                guard let self, token == self.generation, requestID == self.seekID else { return }
                self.pendingSeekTarget = nil
                let actual = self.player.currentTime().seconds
                if finished && actual.isFinite { self.time = max(0, actual) }
                if self.wantsPlayback { self.player.defaultRate = self.rate; self.player.play() }
                self.markFirstFrameIfReady()
                self.updatePlaybackState()
            }
        }
    }
    private func refreshBufferedRanges(for item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        let length = duration > 0 ? duration : item.duration.seconds
        let ranges: [BufferedRange]
        if resource?.url.isFileURL == true {
            ranges = [BufferedRange(start: 0, end: length)]
        } else {
            ranges = item.loadedTimeRanges.map { value in
                let range = value.timeRangeValue
                return BufferedRange(start: range.start.seconds, end: range.start.seconds + range.duration.seconds)
            }
        }
        let normalized = BufferedTimeline.normalized(ranges, duration: length)
        if bufferedRanges != normalized { bufferedRanges = normalized }
    }
    func setRate(_ value: Float) {
        guard value.isFinite, value > 0 else { return }
        rate = value
        updateBufferTarget()
        player.defaultRate = value
        if wantsPlayback { player.rate = value }
    }
    func selectSubtitle(_ option: AVMediaSelectionOption?) {
        guard let group = subtitleGroup else { return }; player.currentItem?.select(option, in: group); selectedSubtitle = option
    }
    func selectAudio(_ option: AVMediaSelectionOption) {
        guard let group = audioGroup else { return }; player.currentItem?.select(option, in: group); selectedAudio = option
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
        guard let video = current, let server = library?.servers.first(where: { $0.id == video.sourceID }), let resource, !resource.url.isFileURL else { return }
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
        warmup.cancel()
        Self.lastDiagnostic = diagnostic
        watchdog?.cancel(); watchdog = nil
        formatTask?.cancel(); formatTask = nil
        if let colorProbe { player.currentItem?.remove(colorProbe) }; colorProbe = nil
        bufferingTask?.cancel(); bufferingTask = nil
        pendingSeekTarget = nil; pendingStartPosition = nil; seekID = UUID()
        save()
        if recordsProgress { report("Stopped") }
        else if let video = current, let server = library?.servers.first(where: { $0.id == video.sourceID }), let resource {
            Task { try? await MediaClient.shared.stopTranscoding(server: server, resource: resource) }
        }
        generation = UUID(); loadTask?.cancel(); loadTask = nil
        wantsPlayback = false
        player.currentItem?.cancelPendingSeeks()
        player.pause(); player.replaceCurrentItem(with: nil)
        itemObservation = nil; loadedRangesObservation = nil; authenticated?.cancel(); authenticated = nil
        resource = nil; current = nil; isPlaying = false; loading = false; bufferedRanges = []
        subtitleOptions = []; audioOptions = []; subtitleGroup = nil; audioGroup = nil; selectedSubtitle = nil; selectedAudio = nil
    }
    func close() {
        stop()
        PlaybackAudioSession.release(owner: audioSessionOwner)
    }
    deinit {
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        let owner = audioSessionOwner
        Task { @MainActor in PlaybackAudioSession.release(owner: owner) }
    }
}
