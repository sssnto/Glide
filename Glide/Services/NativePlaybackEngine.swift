import AVFoundation
import UIKit

@MainActor final class NativePlaybackEngine: PlaybackEngine {
    let descriptor = PlaybackEngineDescriptor.native
    let player = AVPlayer()
    var presentation: PlaybackPresentation { .native(player) }
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    private(set) var tracks: [PlaybackTrack] = []
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var options: [String: AVMediaSelectionOption] = [:]
    private var resource: PlaybackResource?
    private var asset: AVURLAsset?
    private var loader: AuthenticatedAsset?
    private weak var layer: AVPlayerLayer?
    private var lifetime = PlaybackEngineLifetime()
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var controlObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var rangesObservation: NSKeyValueObservation?
    private var layerObservation: NSKeyValueObservation?
    private var inspectionTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var colorProbe: AVPlayerItemVideoOutput?
    private var stallObserver: NSObjectProtocol?
    private var requestedPlay = false
    private var desiredRate: Float = 1
    private var isSeeking = false
    private var hasPlayedFrame = false
    private var rebuffering = false
    private var rebufferTask: Task<Void, Never>?
    private var rebufferCooldownUntil: TimeInterval = 0
    private var rebufferCount = 0
    private var lastResumeBufferedAhead: Double?
    private var rebufferStarted: TimeInterval?
    private var rebufferID: UUID?
    private var lastRebufferSeconds: Double?
    private var rebufferExhausted = false

    var selectedAudioID: String? { selectedID(in: audioGroup, kind: .audio) }
    var selectedSubtitleID: String? { selectedID(in: subtitleGroup, kind: .subtitle) }
    private func selectedID(in group: AVMediaSelectionGroup?, kind: PlaybackTrack.Kind) -> String? {
        guard let group, let option = player.currentItem?.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return tracks.first { $0.kind == kind && options[$0.id] == option }?.id
    }
    var subtitleClock: Double? {
        guard !player.isExternalPlaybackActive, player.currentItem != nil else { return nil }
        let time = player.currentTime().seconds
        return time.isFinite ? time : nil
    }
    var snapshot: PlaybackEngineSnapshot {
        guard let item = player.currentItem else { return PlaybackEngineSnapshot() }
        let rawTime = player.currentTime().seconds, rawDuration = item.duration.seconds
        let duration = rawDuration.isFinite ? max(0, rawDuration) : 0
        let time = rawTime.isFinite ? max(0, rawTime) : 0
        let ranges = resource?.url.isFileURL == true ? [BufferedRange(start: 0, end: duration)] : item.loadedTimeRanges.map {
            BufferedRange(start: $0.timeRangeValue.start.seconds, end: $0.timeRangeValue.start.seconds + $0.timeRangeValue.duration.seconds)
        }
        let phase: EnginePlaybackPhase
        if item.status == .failed { phase = .failed }
        else if item.status != .readyToPlay { phase = .preparing }
        else if rebuffering { phase = .waiting }
        else {
            switch player.timeControlStatus {
            case .playing: phase = .playing
            case .waitingToPlayAtSpecifiedRate: phase = .waiting
            default: phase = .paused
            }
        }
        let size = item.presentationSize, log = item.accessLog()?.events.last
        func bitrate(_ value: Double?) -> Int? {
            guard let value, value.isFinite, value > 0, value < Double(Int.max) else { return nil }
            return Int(value)
        }
        return PlaybackEngineSnapshot(hasItem: true, ready: item.status == .readyToPlay, phase: phase,
            time: time, duration: duration, buffered: BufferedTimeline.normalized(ranges, duration: duration),
            frameReady: item.status == .readyToPlay && layer?.player === player && layer?.isReadyForDisplay == true,
            externalPlayback: player.isExternalPlaybackActive,
            width: size.width > 0 ? Int(size.width) : nil, height: size.height > 0 ? Int(size.height) : nil,
            bitrate: bitrate(log?.observedBitrate), indicatedBitrate: bitrate(log?.indicatedBitrate),
            droppedVideoFrames: log.flatMap { $0.numberOfDroppedVideoFrames >= 0 ? $0.numberOfDroppedVideoFrames : nil },
            nativeStalls: log.flatMap { $0.numberOfStalls >= 0 ? $0.numberOfStalls : nil },
            waitingReason: rebuffering ? "refillingBuffer" : player.reasonForWaitingToPlay.flatMap { PlaybackDiagnostic.token($0.rawValue) },
            bufferEmpty: item.isPlaybackBufferEmpty, rebufferCount: rebufferCount, lastResumeBufferedAhead: lastResumeBufferedAhead,
            rebufferElapsedSeconds: rebufferStarted.map { max(0, ProcessInfo.processInfo.systemUptime - $0) },
            lastRebufferSeconds: lastRebufferSeconds, bufferFull: item.isPlaybackBufferFull,
            likelyToKeepUp: item.isPlaybackLikelyToKeepUp,
            nativeTimeControlStatus: player.timeControlStatus == .playing ? "playing" : player.timeControlStatus == .paused ? "paused" : "waiting",
            accessLogBytesTransferred: log.flatMap { $0.numberOfBytesTransferred >= 0 ? $0.numberOfBytesTransferred : nil },
            accessLogTransferSeconds: log.flatMap { $0.transferDuration.isFinite && $0.transferDuration >= 0 ? $0.transferDuration : nil })
    }
    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.resource != nil else { return }
                if self.player.timeControlStatus == .playing, self.layer?.isReadyForDisplay == true { self.hasPlayedFrame = true }
                self.onEvent?(.clock)
            }
        }
        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.resource != nil else { return }
                self.beginRebufferIfNeeded()
                self.onEvent?(.stateChanged)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                self.onEvent?(.ended)
            }
        }
        stallObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                self.onEvent?(.diagnostic("native_stall_notification"))
                self.beginRebufferIfNeeded(stallNotification: true)
                self.onEvent?(.stateChanged)
            }
        }
    }
    func attachLayer(_ layer: AVPlayerLayer?) {
        guard self.layer !== layer else { return }
        self.layer = layer
        layerObservation = layer?.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.onEvent?(.frameReady) }
        }
    }
    func load(_ resource: PlaybackResource, preload: (any PlaybackPreload)?, options configuration: PlaybackEngineOptions) async throws {
        stop()
        defer { withExtendedLifetime(resource) {} }
        let token = lifetime.load
        self.resource = resource
        if let prepared = preload as? PlaybackWarmup.Prepared, prepared.resource.url == resource.url {
            asset = prepared.asset; loader = prepared.loader
        } else if resource.headers.isEmpty {
            asset = AVURLAsset(url: resource.url, options: [AVURLAssetAllowsCellularAccessKey: configuration.allowsCellular])
        } else {
            let authenticated = AuthenticatedAsset(url: resource.url, headers: resource.headers, allowsCellular: configuration.allowsCellular)
            loader = authenticated; asset = authenticated.asset
        }
        guard let asset else { throw MediaError.message("无法创建播放资源。") }
        let item = AVPlayerItem(asset: asset)
        item.startsOnFirstEligibleVariant = resource.prefersFirstHDRVariant
        if configuration.inspectWideColor {
            let probe = AVPlayerItemVideoOutput(outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, AVVideoAllowWideColorKey: true])
            colorProbe = probe; item.add(probe)
        }
        if let rule = AVTextStyleRule(textMarkupAttributes: [kCMTextMarkupAttribute_RelativeFontSize as String: configuration.subtitleScale]) { item.textStyleRules = [rule] }
        item.preferredForwardBufferDuration = configuration.forwardBuffer
        item.preferredPeakBitRate = configuration.peakBitrate
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.lifetime.accepts(token), observed === self.player.currentItem else { return }
                if observed.status == .failed { self.onEvent?(.failed(observed.error ?? MediaError.message("系统无法读取此媒体文件。"))) }
                else if observed.status == .readyToPlay { self.onEvent?(.ready) }
            }
        }
        player.replaceCurrentItem(with: item)
        rangesObservation = item.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.lifetime.accepts(token), observed === self.player.currentItem else { return }
                self.onEvent?(.clock)
            }
        }
        onEvent?(.installed)
        if resource.url.isFileURL {
            inspectionTask = Task { [weak self] in
                let report = await LocalMediaInspector.inspect(asset: asset, resource: resource) { [weak self] container in
                    guard !Task.isCancelled, let self, self.lifetime.accepts(token) else { return }
                    self.onEvent?(.inspection(LocalMediaInspection(container: container)))
                }
                guard !Task.isCancelled, let self, self.lifetime.accepts(token) else { return }
                self.onEvent?(.inspection(report))
            }
        }
        let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
        let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
        try Task.checkCancellation()
        guard lifetime.accepts(token), item === player.currentItem else { throw CancellationError() }
        subtitleGroup = subtitles; audioGroup = audio
        appendTracks(audio, kind: .audio); appendTracks(subtitles, kind: .subtitle)
    }
    private func appendTracks(_ group: AVMediaSelectionGroup?, kind: PlaybackTrack.Kind) {
        for (index, option) in (group?.options ?? []).enumerated() {
            let id = kind.rawValue + "-" + String(index)
            options[id] = option
            tracks.append(PlaybackTrack(id: id, kind: kind, displayName: option.displayName,
                language: option.extendedLanguageTag ?? option.locale?.language.languageCode?.identifier, forced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles)))
        }
    }
    func selectTrack(_ id: String?, kind: PlaybackTrack.Kind) {
        let group = kind == .audio ? audioGroup : subtitleGroup
        guard let group else { return }
        if let id, tracks.contains(where: { $0.id == id && $0.kind == kind }), let option = options[id] { player.currentItem?.select(option, in: group) }
        else if id == nil, kind == .subtitle { player.currentItem?.select(nil, in: group) }
    }
    func play(rate: Float) {
        requestedPlay = true; desiredRate = rate; player.defaultRate = rate
        if !rebuffering { player.play() }
    }
    func pause() { requestedPlay = false; cancelRebuffer(); player.pause() }
    func setRate(_ rate: Float, playing: Bool) {
        desiredRate = rate; requestedPlay = playing; player.defaultRate = rate
        if !playing { cancelRebuffer() }
        if playing && !rebuffering { player.rate = rate }
        else if playing { primeRebuffer() }
    }
    func setForwardBuffer(_ seconds: Double) { player.currentItem?.preferredForwardBufferDuration = seconds }
    func cancelPendingSeeks() { cancelRebuffer(); isSeeking = false; lifetime.cancelSeek(); player.currentItem?.cancelPendingSeeks() }
    func seek(to time: Double, tolerance: Double, completion: @escaping (Bool, Double) -> Void) {
        guard player.currentItem != nil else { return }
        // Retire the previous operation before publishing the new seek token.
        // Loop boundaries and a following manual seek can arrive back-to-back.
        cancelPendingSeeks(); isSeeking = true
        let token = lifetime.beginSeek()
        let delta = CMTime(seconds: tolerance, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: delta, toleranceAfter: delta) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.lifetime.finishSeek(token) else { return }
                self.isSeeking = false
                completion(finished, self.snapshot.time)
            }
        }
    }
    private func cancelRebuffer() {
        rebufferTask?.cancel(); rebufferTask = nil; rebuffering = false
        rebufferID = nil; rebufferStarted = nil
        player.cancelPendingPrerolls()
    }
    private func primeRebuffer() {
        // A paused player is not a request to prepare playback. Explicitly prime
        // the pipeline while retaining the user's intent in requestedPlay.
        guard rebuffering, player.status == .readyToPlay, player.rate == 0 else { return }
        player.cancelPendingPrerolls()
        let request = UUID(), load = lifetime.load
        rebufferID = request
        onEvent?(.diagnostic("network_rebuffer_preroll"))
        player.preroll(atRate: desiredRate) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.lifetime.accepts(load), self.rebufferID == request,
                      self.rebuffering, self.requestedPlay else { return }
                self.onEvent?(.diagnostic(finished ? "network_preroll_ready" : "network_preroll_unavailable"))
                self.onEvent?(.clock)
            }
        }
    }
    private func beginRebufferIfNeeded(stallNotification: Bool = false) {
        guard !rebuffering, !rebufferExhausted, requestedPlay, hasPlayedFrame, !isSeeking, let resource, let item = player.currentItem,
              item.status == .readyToPlay, layer?.isReadyForDisplay == true, !player.isExternalPlaybackActive,
              ProcessInfo.processInfo.systemUptime >= rebufferCooldownUntil,
              stallNotification || player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
              NativeRebufferPolicy.eligible(local: resource.url.isFileURL,
                preservesVideo: [.direct, .remux, .audioConversion].contains(resource.delivery),
                width: resource.videoStream?.Width, height: resource.videoStream?.Height,
                bitrate: resource.sourceBitrate ?? resource.videoStream?.BitRate) else { return }
        let state = snapshot
        let ahead = BufferedTimeline.ahead(of: state.time, in: state.buffered)
        guard ahead < 2, NativeRebufferPolicy.resumeGoal(rate: desiredRate, remaining: state.duration - state.time) != nil else { return }
        rebuffering = true; rebufferCount += 1
        rebufferStarted = ProcessInfo.processInfo.systemUptime
        player.pause()
        onEvent?(.diagnostic("network_rebuffer_hold"))
        primeRebuffer()
        let token = lifetime.load, started = ProcessInfo.processInfo.systemUptime
        rebufferTask = Task { [weak self] in
            var publishedAt = started
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.lifetime.accepts(token), self.rebuffering,
                      self.requestedPlay, !self.isSeeking, item === self.player.currentItem else { return }
                let state = self.snapshot
                let ahead = BufferedTimeline.ahead(of: state.time, in: state.buffered)
                let expired = ProcessInfo.processInfo.systemUptime - started >= NativeRebufferPolicy.maximumHold
                if ProcessInfo.processInfo.systemUptime - publishedAt >= 1 {
                    publishedAt = ProcessInfo.processInfo.systemUptime
                    self.onEvent?(.clock)
                }
                let useful = NativeRebufferPolicy.canResume(ahead: ahead, rate: self.desiredRate,
                    remaining: state.duration - state.time, bufferFull: item.isPlaybackBufferFull)
                guard expired || useful else { continue }
                self.lastRebufferSeconds = ProcessInfo.processInfo.systemUptime - started
                self.cancelRebuffer()
                self.lastResumeBufferedAhead = ahead
                self.rebufferCooldownUntil = ProcessInfo.processInfo.systemUptime + NativeRebufferPolicy.cooldown
                let goal = NativeRebufferPolicy.resumeGoal(rate: self.desiredRate, remaining: state.duration - state.time) ?? 0
                self.onEvent?(.diagnostic(expired ? "network_rebuffer_deadline" : ahead >= goal ? "network_rebuffer_ready" : "network_rebuffer_capacity"))
                if expired && !useful {
                    self.rebufferExhausted = true
                    self.onEvent?(.diagnostic("network_rebuffer_unproductive"))
                }
                self.player.defaultRate = self.desiredRate; self.player.play()
                self.onEvent?(.stateChanged)
                return
            }
        }
    }
    func preview(at time: Double) async -> UIImage? {
        guard let asset, let resource, resource.url.isFileURL else { return nil }
        let token = lifetime.load
        defer { withExtendedLifetime(resource) {} }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 336, height: 188)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let result = try await withTaskCancellationHandler {
                try await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600))
            } onCancel: { generator.cancelAllCGImageGeneration() }
            guard !Task.isCancelled, lifetime.accepts(token) else { return nil }
            return UIImage(cgImage: result.image)
        } catch { return nil }
    }
    func inspectOutput() {
        guard let item = player.currentItem else { return }
        let token = lifetime.load
        outputTask?.cancel()
        outputTask = Task { [weak self] in
            var evidence = PlaybackOutputEvidence()
            for _ in 0..<4 {
                guard !Task.isCancelled, let self, lifetime.accepts(token), item === player.currentItem else { return }
                if let probe = colorProbe, let frame = probe.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) {
                    evidence.transfer = PlaybackDiagnostic.token(CVBufferCopyAttachment(frame, kCVImageBufferTransferFunctionKey, nil) as? String)
                    evidence.primaries = PlaybackDiagnostic.token(CVBufferCopyAttachment(frame, kCVImageBufferColorPrimariesKey, nil) as? String)
                    evidence.matrix = PlaybackDiagnostic.token(CVBufferCopyAttachment(frame, kCVImageBufferYCbCrMatrixKey, nil) as? String)
                    evidence.source = "decodedFrame"
                    item.remove(probe); colorProbe = nil
                    onEvent?(.output(evidence))
                }
                guard !Task.isCancelled, lifetime.accepts(token) else { return }
                if let format = await Self.videoFormat(for: item) {
                    guard !Task.isCancelled, lifetime.accepts(token), item === player.currentItem else { return }
                    evidence.codec = LocalMediaInspector.codec(format)
                    if evidence.source != "decodedFrame" {
                        evidence.transfer = PlaybackDiagnostic.token(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String)
                        evidence.primaries = PlaybackDiagnostic.token(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String)
                        evidence.matrix = PlaybackDiagnostic.token(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String)
                        if evidence.transfer != nil { evidence.source = "compressedTrack" }
                    }
                    onEvent?(.output(evidence))
                    guard lifetime.accepts(token) else { return }
                    if evidence.transfer != nil { if let probe = colorProbe { item.remove(probe); colorProbe = nil }; return }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled, let self, lifetime.accepts(token) else { return }
            if let probe = colorProbe { item.remove(probe); colorProbe = nil }
            if evidence.transfer == nil { onEvent?(.diagnostic("output_color_unavailable")) }
            if evidence.codec == nil { onEvent?(.diagnostic("output_codec_unavailable")) }
        }
    }
    private static func videoFormat(for item: AVPlayerItem) async -> CMFormatDescription? {
        for track in item.tracks.compactMap(\.assetTrack) where track.mediaType == .video {
            guard !Task.isCancelled else { return nil }
            if let formats = try? await track.load(.formatDescriptions), let format = formats.first { return format }
        }
        guard !Task.isCancelled, let track = try? await item.asset.loadTracks(withMediaType: .video).first else { return nil }
        return try? await track.load(.formatDescriptions).first
    }
    func stop() {
        requestedPlay = false; cancelRebuffer(); isSeeking = false
        hasPlayedFrame = false
        rebufferCount = 0; lastResumeBufferedAhead = nil; lastRebufferSeconds = nil; rebufferCooldownUntil = 0; rebufferExhausted = false
        _ = lifetime.begin()
        inspectionTask?.cancel(); inspectionTask = nil; outputTask?.cancel(); outputTask = nil
        if let colorProbe { player.currentItem?.remove(colorProbe) }; colorProbe = nil
        itemObservation = nil; rangesObservation = nil
        player.currentItem?.cancelPendingSeeks(); player.pause(); player.replaceCurrentItem(with: nil)
        asset?.cancelLoading(); asset = nil; loader?.cancel(); loader = nil; resource = nil
        tracks = []; options = [:]; audioGroup = nil; subtitleGroup = nil
    }
    deinit {
        inspectionTask?.cancel(); outputTask?.cancel(); rebufferTask?.cancel()
        if let observer { player.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver) }
    }
}

@MainActor enum LocalMediaInspector {
    static func codec(_ format: CMFormatDescription) -> String? {
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        let bytes = [UInt8((subtype >> 24) & 255), UInt8((subtype >> 16) & 255), UInt8((subtype >> 8) & 255), UInt8(subtype & 255)]
        return PlaybackDiagnostic.token(String(bytes: bytes, encoding: .ascii))
    }
    static func inspect(asset: AVURLAsset, resource: PlaybackResource, onContainer: (MediaContainer) -> Void) async -> LocalMediaInspection {
        let url = resource.url, access = resource.localAccess
        defer { withExtendedLifetime(access) {} }
        let container = await Task.detached {
            defer { withExtendedLifetime(access) {} }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return MediaContainer.unknown }
            defer { try? handle.close() }
            return MediaContainer.identify((try? handle.read(upToCount: 4096)) ?? Data())
        }.value
        guard !Task.isCancelled else { return LocalMediaInspection(container: container) }
        onContainer(container)
        async let playable = try? asset.load(.isPlayable)
        async let video = try? asset.loadTracks(withMediaType: .video)
        async let audio = try? asset.loadTracks(withMediaType: .audio)
        var report = LocalMediaInspection(container: container)
        report.playable = await playable
        let videoTracks = await video, audioTracks = await audio
        report.videoTracks = videoTracks?.count; report.audioTracks = audioTracks?.count
        if let track = videoTracks?.first, let format = try? await track.load(.formatDescriptions).first { report.videoCodec = codec(format) }
        for track in audioTracks ?? [] {
            guard !Task.isCancelled else { return report }
            if let format = try? await track.load(.formatDescriptions).first, let name = codec(format), !report.audioCodecs.contains(name) { report.audioCodecs.append(name) }
        }
        do { report.subtitleTracks = try await asset.loadMediaSelectionGroup(for: .legible)?.options.count ?? 0 } catch { }
        return report
    }
}
