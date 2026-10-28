import AVFoundation
import CoreText
import MobileVLCKit
import Network
import UIKit

@MainActor private final class CompatibilityNetworkPath {
    static let shared = CompatibilityNetworkPath()
    private let monitor = NWPathMonitor()
    private(set) var cellular = false
    private(set) var wifiAvailable = false
    private var resolved = false
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular)
            let wifi = path.availableInterfaces.contains { $0.type == .wifi }
            Task { @MainActor in self?.cellular = cellular; self?.wifiAvailable = wifi; self?.resolved = true }
        }
        monitor.start(queue: DispatchQueue(label: "Glide.compatibility.network"))
    }
    func check(url: URL, allowsCellular: Bool) async throws {
        guard !allowsCellular else { return }
        for _ in 0..<20 where !resolved { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        // Check this NAS endpoint, not the default internet route: a Wi-Fi LAN
        // may have no internet while the system's default path uses cellular.
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        guard let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 445)) else { throw MediaError.message("SMB 服务器位置无效。") }
        let probe = CompatibilityRouteProbe(connection: NWConnection(host: NWEndpoint.Host(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))), port: port, using: parameters))
        try await probe.run()
    }
}

@MainActor private final class CompatibilityRouteProbe {
    let connection: NWConnection
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    init(connection: NWConnection) { self.connection = connection }
    func finish(_ error: Error? = nil) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
    func run() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        switch state {
                        case .ready: self?.finish()
                        case .failed, .waiting: self?.finish(MediaError.message("Wi-Fi 暂时无法连接此 NAS。蜂窝播放已关闭，请检查连接或在设置中允许蜂窝网络播放。"))
                        default: break
                        }
                    }
                }
                connection.start(queue: DispatchQueue(label: "Glide.compatibility.route"))
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    self?.finish(MediaError.message("NAS 连接超时，请检查 Wi-Fi 与局域网访问权限后重试。"))
                }
            }
        } onCancel: { Task { @MainActor in self.finish(CancellationError()) } }
    }
}

@MainActor private enum VLCSubtitleFonts {
    static let options: [String] = {
        guard let directory = Bundle.main.url(forResource: "SubtitleFonts", withExtension: nil) else {
            assertionFailure("Missing bundled subtitle fonts")
            return []
        }
        let font = directory.appendingPathComponent("GlideSubtitleFallback.otf")
        // Register once per process, before FreeType/CoreText builds its cache.
        // libass reads the same bundled file directly through ssa-fontsdir.
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(font as CFURL, .process, &error)
        let registrationError = error?.takeRetainedValue()
        assert(registered, "Cannot register subtitle fallback: \(String(describing: registrationError))")
        return ["--ssa-fontsdir=\(directory.path)", "--freetype-font=Glide Subtitle Fallback"]
    }()
}

/// Local files and explicitly verified SMB resources; shared by Glide and QA.
@MainActor final class VLCPlaybackEngine: PlaybackEngine {
    let descriptor = PlaybackEngineDescriptor(id: .vlc, title: "兼容播放 · VLC", capabilities: [.tracks])
    let surface = UIView()
    var presentation: PlaybackPresentation { .custom(surface) }
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    private(set) var tracks: [PlaybackTrack] = []
    private let library = VLCLibrary(options: ["--no-video-title-show", "--no-video-on-top", "--no-color", "--quiet"] + VLCSubtitleFonts.options)
    private var player: VLCMediaPlayer?
    private var clockPlayer: VLCClockPlayer?
    private var drawable: UIView?
    private var clipEnd: Double?
    private var resource: PlaybackResource?
    private var lifetime = PlaybackEngineLifetime()
    private var polling: Task<Void, Never>?
    private var seeking: Task<Void, Never>?
    private var inspectionTask: Task<Void, Never>?
    private var containerHint = MediaContainer.unknown
    private var headerRead = false
    private var inspectionSent = false
    private var preparingPausedFrame = false
    private var preparedVolume: Int32?
    private var pausedSeekVolume: Int32?
    private var wasReady = false
    private var wasFrame = false
    private var failed = false
    private var ended = false
    private var lastClock: Double = 0
    private var smbReadStall = SMBReadStall()
    private var allowsCellular = false
    private(set) var libraryVersion = ""
    private var previousPhase: EnginePlaybackPhase = .idle
    private var wantsPlayback = false
    private var desiredRate: Float = 1
    private var lastPlayRequest: TimeInterval = 0
    private var subtitleChoice: Int32?
    private var subtitleRefreshPending = false
    private var subtitleReconciliations = 0
    private var subtitleSettlingUntil: TimeInterval = 0
    private var subtitleNeedsApplication = false
    private var isSeeking = false
#if DEBUG
    private(set) var qaSeekSamples: [[String: Any]] = []
#endif
    private(set) var subtitleRefreshCount = 0
    var selectedAudioID: String? { player.map { "audio-" + String($0.currentAudioTrackIndex) } }
    var selectedSubtitleID: String? {
        guard let player, player.currentVideoSubTitleIndex >= 0 else { return nil }
        return "subtitle-" + String(player.currentVideoSubTitleIndex)
    }
    var displayedPictures: Int { Int(player?.media?.statistics.displayedPictures ?? 0) }
    var decodedVideo: Int { Int(player?.media?.statistics.decodedVideo ?? 0) }
    var retiringSessions: Int { VLCRetiredPlayback.pendingCount }
    var cachedSDKTime: Double { Double(player?.time.intValue ?? 0) / 1000 }
    var nativeState: Int { Int(clockPlayer?.nativeState ?? -1) }
    var cachedSDKState: String { player.map { String(describing: $0.state) } ?? "none" }
    func setVolume(_ value: Int32) { player?.audio?.volume = value }
    var playbackRate: Float { player?.rate ?? 0 }
    var isPlaying: Bool { player?.isPlaying ?? false }
    var subtitleSettled: Bool {
        !subtitleNeedsApplication && !subtitleRefreshPending && !isSeeking
            && ProcessInfo.processInfo.systemUptime >= subtitleSettlingUntil
    }
    var subtitleClock: Double? {
        guard resource != nil, let clockPlayer else { return nil }
        let value = clockPlayer.timeMilliseconds
        return value >= 0 ? Double(value) / 1000 : nil
    }
    var snapshot: PlaybackEngineSnapshot {
        guard let player, resource != nil else { return PlaybackEngineSnapshot() }
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        let time = Double(clockPlayer?.timeMilliseconds ?? -1) / 1000
        let phase: EnginePlaybackPhase
        if player.isPlaying { phase = .playing }
        else { switch player.state {
        case .error: phase = .failed
        case .opening, .esAdded: phase = .preparing
        case .buffering: phase = .waiting
        case .playing: phase = .playing
        case .paused, .ended: phase = .paused
        default: phase = wasReady ? .paused : .preparing
        } }
        let size = player.videoSize
        return PlaybackEngineSnapshot(hasItem: true, ready: wasReady, phase: phase,
            time: max(0, time), duration: max(0, length), buffered: [],
            frameReady: displayedPictures > 0 && size.width > 0 && surface.window != nil,
            externalPlayback: false, width: size.width > 0 ? Int(size.width) : nil,
            height: size.height > 0 ? Int(size.height) : nil,
            accessLogBytesTransferred: player.media.map { Int64(UInt32(bitPattern: $0.statistics.readBytes)) })
    }
    func load(_ resource: PlaybackResource, preload: (any PlaybackPreload)?, options: PlaybackEngineOptions) async throws {
        stop()
        let token = lifetime.load
        guard resource.headers.isEmpty, resource.url.isFileURL || (resource.smb != nil && resource.url.scheme == "smb") else {
            throw MediaError.message("兼容播放仅接受本地文件或已验证的 SMB 资源。")
        }
        guard preload == nil else { throw MediaError.message("兼容播放暂不支持预加载。") }
        if resource.smb != nil { try await CompatibilityNetworkPath.shared.check(url: resource.url, allowsCellular: options.allowsCellular) }
        guard lifetime.accepts(token) else { throw CancellationError() }
        allowsCellular = options.allowsCellular
        self.resource = resource; clipEnd = options.endTime
        guard let clockPlayer = VLCClockPlayer(library: library) else { throw MediaError.message("无法创建兼容播放器。") }
        self.clockPlayer = clockPlayer
        let player = clockPlayer.player
        libraryVersion = player.libraryInstance.version + " (" + player.libraryInstance.changeset + ")"
        // An old asynchronous stop may still use its drawable. Each input owns its view.
        let drawable = UIView(frame: surface.bounds)
        drawable.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.addSubview(drawable)
        self.drawable = drawable
        player.drawable = drawable
        let media = VLCMedia(url: resource.url)
        if let access = resource.smb {
            media.addOption(":smb-user=" + (access.options.guest ? "Guest" : access.username))
            media.addOption(":smb-pwd=" + (access.options.guest ? "" : access.password))
            media.addOption(":smb-domain=" + access.options.domain)
            media.addOption(":network-caching=1500")
        }
        if let end = options.endTime, end.isFinite, end > 0 { media.addOption(":stop-time=\(end)") }
        media.addOption(":start-paused")
        player.media = media
        self.player = player
        if options.muted { player.audio?.volume = 0 }
        if resource.smb != nil { headerRead = true }
        else { inspectionTask = Task { [weak self] in
            let hint = await Task.detached(priority: .utility) {
                defer { withExtendedLifetime(resource) {} }
                guard let file = try? FileHandle(forReadingFrom: resource.url) else { return MediaContainer.unknown }
                defer { try? file.close() }
                return MediaContainer.identify((try? file.read(upToCount: 4096)) ?? Data())
            }.value
            guard !Task.isCancelled, let self, self.lifetime.accepts(token) else { return }
            self.containerHint = hint; self.headerRead = true
        } }
        onEvent?(.installed)
        guard lifetime.accepts(token) else { return }
        // libVLC prepares its input by entering playback; start-paused preserves caller intent.
        player.play()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.lifetime.accepts(token) else { return }
                self.poll()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    private func poll() {
        guard let player, resource != nil else { return }
        let token = lifetime.load
        updateTracks()
        reconcileSubtitle()
        let prepared = (player.media?.length.intValue ?? 0) > 0 && !(player.media?.tracksInformation.isEmpty ?? true)
        if prepared, headerRead, !inspectionSent {
            inspectionSent = true
            let information = player.media?.tracksInformation as? [[String: Any]] ?? []
            let videos = information.filter { $0[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeVideo }
            let audio = information.filter { $0[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeAudio }
            let subtitles = information.filter { $0[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeText }
            func codec(_ info: [String: Any]) -> String? {
                guard let value = info[VLCMediaTracksInformationCodec] as? NSNumber else { return nil }
                let code = value.uint32Value
                let bytes = (0..<4).map { UInt8((code >> ($0 * 8)) & 255) }
                guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
                return PlaybackDiagnostic.token(String(bytes: bytes, encoding: .ascii))
            }
            onEvent?(.inspection(LocalMediaInspection(container: containerHint, playable: nil,
                videoTracks: videos.count, audioTracks: audio.count, subtitleTracks: subtitles.count,
                videoCodec: videos.first.flatMap(codec), audioCodecs: audio.compactMap(codec))))
            guard lifetime.accepts(token) else { return }
            if videos.isEmpty {
                failed = true
                onEvent?(.failed(MediaError.message("此文件没有视频轨道，请选择含画面的视频文件。")))
                return
            }
        }
        if !wasReady, prepared || player.state == .playing || player.state == .paused {
            wasReady = true
            // start-paused preserves the initial intent while metadata becomes available.
            onEvent?(.ready)
        }
        guard lifetime.accepts(token) else { return }
        // Adopt the input's default only while the caller has not chosen a
        // subtitle. This also refreshes a cue selected during start-paused.
        if wasReady, subtitleChoice == nil, player.currentVideoSubTitleIndex >= 0 {
            selectSubtitle(player.currentVideoSubTitleIndex)
        }
        // A cold start-paused input may not have created its video output yet.
        // Decode silently until the attached drawable receives a frame, then
        // pause before submitting the caller's pending seek.
        if wasReady, !wantsPlayback, !wasFrame, surface.window != nil,
           surface.bounds.width > 0, surface.bounds.height > 0 {
            if !preparingPausedFrame {
                preparingPausedFrame = true
                preparedVolume = player.audio?.volume
                player.audio?.volume = 0
            }
            if !snapshot.frameReady, ProcessInfo.processInfo.systemUptime - lastPlayRequest >= 0.25 {
                requestPlayback(player)
            }
        }
        if preparingPausedFrame, snapshot.frameReady {
            player.pause()
            finishPausedPreparation()
        }
        // Metadata can precede start-paused input initialization. A play sent
        // in that interval can be superseded by the input's initial pause.
        if wantsPlayback, wasReady, !isSeeking, !failed, !ended,
           player.state != .error, clockPlayer?.hasEnded != true, !player.isPlaying,
           player.state == .paused || !wasFrame,
           ProcessInfo.processInfo.systemUptime - lastPlayRequest >= 0.25 {
            requestPlayback(player)
        }
        let state = snapshot
        if clockPlayer?.hasEnded != true, state.time > 0 { lastClock = state.time }
        if state.phase != previousPhase {
            previousPhase = state.phase
            onEvent?(.stateChanged)
        }
        guard lifetime.accepts(token) else { return }
        if state.frameReady, !wasFrame { wasFrame = true; onEvent?(.frameReady) }
        guard lifetime.accepts(token) else { return }
        let mediaStats = player.media?.statistics
        if resource?.smb != nil, !failed, !allowsCellular, CompatibilityNetworkPath.shared.cellular, !CompatibilityNetworkPath.shared.wifiAvailable {
            failed = true
            onEvent?(.failed(MediaError.message("已停止蜂窝网络播放。请连接 Wi-Fi 后重试，或在设置中允许蜂窝网络播放。")))
        }
        if resource?.smb != nil, !failed,
           smbReadStall.sample(at: ProcessInfo.processInfo.systemUptime,
                eligible: wantsPlayback && wasFrame && !isSeeking && !preparingPausedFrame && UIApplication.shared.applicationState == .active,
                frames: UInt64(max(0, mediaStats?.displayedPictures ?? 0)),
                bytes: UInt64(UInt32(bitPattern: mediaStats?.readBytes ?? 0))) {
            failed = true
            onEvent?(.diagnostic("smb_input_and_picture_stalled"))
            onEvent?(.failed(MediaError.message("NAS 视频已停止读取并且画面未继续更新。请检查连接后重试，将保留播放位置。")))
        }
        guard lifetime.accepts(token) else { return }
        if player.state == .error, !failed {
            failed = true; onEvent?(.failed(MediaError.message(resource?.smb != nil
                ? "SMB 视频读取中断或格式暂不支持。请检查网络后重试，或尝试其他视频。"
                : "兼容播放器无法读取此文件，文件可能损坏或编码暂不支持。")))
        }
        guard lifetime.accepts(token) else { return }
        // An input can be sought and played again after an end notification.
        // Re-arm only after observing real playback before the tail, so an old
        // cached SDK .ended state cannot repeatedly complete the new seek.
        if ended, player.isPlaying, state.duration > 0, state.time < state.duration - 0.2 { ended = false }
        // VLCKit's cached state can be overwritten by a queued pause after EOF.
        // Observe the same native input as the clock rather than that cache.
        if clockPlayer?.hasEnded == true, !player.isPlaying, !ended {
            ended = true
            if resource?.smb != nil, state.duration > 0, lastClock < (clipEnd ?? state.duration) - 1.5 {
                failed = true
                onEvent?(.failed(MediaError.message("SMB 读取提前中断。请检查网络后重试，将从中断位置继续。")))
            } else { onEvent?(.ended) }
        }
        guard lifetime.accepts(token) else { return }
        onEvent?(.clock)
    }
    private func updateTracks() {
        guard let player else { return }
        let information = player.media?.tracksInformation as? [[String: Any]] ?? []
        func list(_ ids: [Any]?, _ names: [Any]?, kind: PlaybackTrack.Kind) -> [PlaybackTrack] {
            zip(ids ?? [], names ?? []).compactMap { raw, name in
                guard let number = raw as? NSNumber, number.intValue >= 0, let title = name as? String else { return nil }
                let metadata = information.first { ($0[VLCMediaTracksInformationId] as? NSNumber)?.intValue == number.intValue }
                return PlaybackTrack(id: kind.rawValue + "-" + number.stringValue, kind: kind, displayName: title,
                    language: metadata?[VLCMediaTracksInformationLanguage] as? String, forced: false)
            }
        }
        tracks = list(player.audioTrackIndexes, player.audioTrackNames, kind: .audio)
            + list(player.videoSubTitlesIndexes, player.videoSubTitlesNames, kind: .subtitle)
    }
    func play(rate: Float) {
        finishPausedPreparation()
        finishPausedSeekPreparation()
        if !wantsPlayback { refreshActiveSubtitle() }
        refreshSubtitleForRateChange(rate)
        wantsPlayback = true; desiredRate = rate
        if let player { requestPlayback(player) }
    }
    private func requestPlayback(_ player: VLCMediaPlayer) {
        refreshSubtitleForRateChange(desiredRate)
        lastPlayRequest = ProcessInfo.processInfo.systemUptime
        player.play()
        if abs(player.rate - desiredRate) > 0.001 { player.rate = desiredRate }
    }
    private func finishPausedPreparation() {
        if let preparedVolume { player?.audio?.volume = preparedVolume }
        preparedVolume = nil; preparingPausedFrame = false
    }
    private func finishPausedSeekPreparation() {
        guard let volume = pausedSeekVolume else { return }
        player?.audio?.volume = volume
        player?.rate = desiredRate
        pausedSeekVolume = nil
    }
    func pause() {
        if wantsPlayback { refreshActiveSubtitle() }
        wantsPlayback = false; player?.pause()
    }
    func setRate(_ rate: Float, playing: Bool) {
        refreshSubtitleForRateChange(rate)
        desiredRate = rate; wantsPlayback = playing
        if playing, let player, abs(player.rate - rate) > 0.001 { player.rate = rate }
    }
    private func refreshSubtitleForRateChange(_ rate: Float) {
        guard let player, abs(player.rate - rate) > 0.001, let choice = subtitleChoice, choice >= 0 else { return }
        // Changing input rate can discard an already active long cue.
        refreshActiveSubtitle()
    }
    private func refreshActiveSubtitle() {
        guard let choice = subtitleChoice, choice >= 0 else { return }
        subtitleRefreshPending = true
        subtitleSettlingUntil = ProcessInfo.processInfo.systemUptime + 0.25
    }
    func setForwardBuffer(_ seconds: Double) { }
    func selectTrack(_ id: String?, kind: PlaybackTrack.Kind) {
        guard let player else { return }
        if id == nil, kind == .subtitle { selectSubtitle(-1); return }
        guard let id, tracks.contains(where: { $0.id == id && $0.kind == kind }),
              let index = Int32(id.dropFirst(kind.rawValue.count + 1)) else { return }
        if kind == .audio { player.currentAudioTrackIndex = index }
        else { selectSubtitle(index) }
    }
    private func selectSubtitle(_ index: Int32) {
        guard subtitleChoice != index else { return }
        subtitleChoice = index
        subtitleReconciliations = 0
        subtitleRefreshPending = false
        subtitleNeedsApplication = true
        // Coalesce rapid off/on into the latest choice before touching the
        // asynchronous input. An invisible intermediate choice must not flush it.
        subtitleSettlingUntil = ProcessInfo.processInfo.systemUptime + 0.1
    }
    private func reconcileSubtitle() {
        guard let player, let choice = subtitleChoice else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if subtitleNeedsApplication {
            guard now >= subtitleSettlingUntil else { return }
            let changed = player.currentVideoSubTitleIndex != choice
            if changed { player.currentVideoSubTitleIndex = choice }
            subtitleNeedsApplication = false
            // Even a coalesced off/on can accompany a rate change. Re-send the
            // active cue after the final choice settles, without toggling input.
            subtitleRefreshPending = changed || choice >= 0
            subtitleSettlingUntil = now + 0.25
        }
        if now >= subtitleSettlingUntil, player.currentVideoSubTitleIndex != choice, subtitleReconciliations < 3 {
            subtitleReconciliations += 1
            player.currentVideoSubTitleIndex = choice
            subtitleRefreshPending = true
            subtitleSettlingUntil = now + 0.25
        }
        // Selecting a sparse subtitle after demux has passed its first packet
        // does not replay the active cue. Re-read at the current position once
        // video output exists, preserving pause/rate and giving user seeks priority.
        guard subtitleRefreshPending, !isSeeking, player.isSeekable,
              ProcessInfo.processInfo.systemUptime >= subtitleSettlingUntil,
              snapshot.frameReady, player.currentVideoSubTitleIndex == choice else { return }
        subtitleRefreshPending = false
        subtitleRefreshCount += 1
        player.time = VLCTime(int: Int32(snapshot.time * 1000))
        if !wantsPlayback { player.pause() }
    }
    func cancelPendingSeeks() {
        seeking?.cancel(); seeking = nil; lifetime.cancelSeek(); isSeeking = false
        if pausedSeekVolume != nil, !wantsPlayback { player?.pause() }
        finishPausedSeekPreparation()
    }
    func seek(to time: Double, tolerance: Double, completion: @escaping (Bool, Double) -> Void) {
        guard player != nil, time.isFinite, time >= 0 else { completion(false, snapshot.time); return }
        cancelPendingSeeks()
        isSeeking = true
        let token = lifetime.beginSeek()
        let target = snapshot.duration > 0 ? min(time, max(0, snapshot.duration - 0.1)) : time
        let attempts = resource?.smb != nil ? 150 : 30
        seeking = Task { [weak self] in
            var submitted = false, stepped = false, stable = 0, picturesBeforeSeek = 0
            for _ in 0..<attempts {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, self.lifetime.accepts(token.load) else { return }
                if !submitted {
                    // The latest user seek also re-reads subtitles. Submit it
                    // after the selected input is stable, then consume that
                    // refresh so it cannot seek again to an old clock value.
                    guard self.player?.isSeekable == true, self.snapshot.frameReady,
                          !self.preparingPausedFrame, !self.subtitleNeedsApplication,
                          ProcessInfo.processInfo.systemUptime >= self.subtitleSettlingUntil else { continue }
                    self.subtitleRefreshPending = false
                    // Network input clocks may keep advancing while a seek is
                    // queued. Decode one paused target frame before restoring
                    // the requested play state, so recovery acknowledges the
                    // actual position rather than an already advancing clock.
                    if self.resource?.smb != nil, self.wantsPlayback { self.player?.pause() }
                    picturesBeforeSeek = self.displayedPictures
                    if self.resource?.smb == nil, !self.wantsPlayback, let player = self.player {
                        // A frame-step can leave a paused input at an old keyframe.
                        // Decode the local seek silently, then freeze its first
                        // observed target frame before restoring the caller's volume.
                        self.pausedSeekVolume = player.audio?.volume ?? 100
                        player.audio?.volume = 0
                        player.rate = 1
                        player.play()
                    }
                    // Submit a time seek for paused local inputs too. A fractional
                    // position seek can return to the preceding keyframe after a
                    // frame step, leaving consecutive seeks near the old clock.
                    self.player?.time = VLCTime(int: Int32(target * 1000))
                    submitted = true
                    continue
                }
                // A paused input must decode its target frame to publish time.
                // Step after the queued seek, only for the surviving request.
                if self.resource?.smb != nil, !stepped {
                    self.player?.gotoNextFrame(); stepped = true
                }
                let actual = self.snapshot.time
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--glide-subtitle-study-probe"), target >= 9, self.qaSeekSamples.count < 100 {
                    self.qaSeekSamples.append(["target": target, "actual": actual, "sdk": self.cachedSDKTime, "beforeFrames": picturesBeforeSeek, "frames": self.displayedPictures, "playing": self.player?.isPlaying ?? false, "state": self.player.map { String(describing: $0.state) } ?? "none", "wants": self.wantsPlayback, "stable": stable])
                }
#endif
                // libVLC statistics can restart at zero after a seek. Require
                // a positive changed picture count, rather than monotonicity
                // across two different demux positions.
                let targetFrameDecoded = self.pausedSeekVolume == nil || (self.displayedPictures > 0 && self.displayedPictures != picturesBeforeSeek)
                if self.pausedSeekVolume != nil, targetFrameDecoded, abs(actual - target) <= max(0.5, tolerance) {
                    self.player?.pause()
                }
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--glide-smb-seek-probe") {
                    print("SMB_SEEK target=\(target) clock=\(actual) sdk=\(self.cachedSDKTime) playing=\(self.player?.isPlaying ?? false) frames=\(self.displayedPictures)")
                }
#endif
                stable = targetFrameDecoded && abs(actual - target) <= max(0.5, tolerance) ? stable + 1 : 0
                // Paused frame stepping and seek completion are asynchronous.
                // Keep observing the real clock before acknowledging a paused
                // request, then reassert the surviving playback intent.
                if stable >= (self.wantsPlayback ? 2 : 5) {
                    guard self.lifetime.finishSeek(token) else { return }
                    self.isSeeking = false
                    if self.wantsPlayback { self.play(rate: self.desiredRate) }
                    else { self.player?.pause() }
                    self.finishPausedSeekPreparation()
                    completion(true, actual); return
                }
            }
            guard let self, self.lifetime.finishSeek(token) else { return }
            self.isSeeking = false
            if !self.wantsPlayback { self.player?.pause() }
            self.finishPausedSeekPreparation()
            completion(false, self.snapshot.time)
        }
    }
    func inspectOutput() { onEvent?(.diagnostic("vlc_output_color_not_verified")) }
    func preview(at: Double) async -> UIImage? { nil }
    func saveSnapshot(to path: URL) {
        player?.saveVideoSnapshot(at: path.path, withWidth: 320, andHeight: 0)
    }
    func stop() {
        _ = lifetime.begin()
        polling?.cancel(); polling = nil; cancelPendingSeeks()
        inspectionTask?.cancel(); inspectionTask = nil
        containerHint = .unknown; headerRead = false; inspectionSent = false
        lastClock = 0
        smbReadStall = SMBReadStall()
        preparingPausedFrame = false; preparedVolume = nil
        if let player, let drawable, let resource {
            VLCRetiredPlayback.retire(player, drawable: drawable, resource: resource)
        }
        player = nil; clockPlayer = nil; drawable = nil
        resource = nil; tracks = []; wasReady = false; wasFrame = false; failed = false; ended = false
        previousPhase = .idle; wantsPlayback = false
        subtitleChoice = nil; subtitleRefreshPending = false; subtitleReconciliations = 0; subtitleRefreshCount = 0
        subtitleNeedsApplication = false; subtitleSettlingUntil = 0
    }
    deinit { polling?.cancel(); seeking?.cancel(); inspectionTask?.cancel() }
}

/// MobileVLCKit 3.7.3 stop() is asynchronous. Its player, drawable and file lease
/// must survive until the stopped notification, including when opening is interrupted.
@MainActor private final class VLCRetiredPlayback: NSObject, VLCMediaPlayerDelegate {
    private static var pending: [UUID: VLCRetiredPlayback] = [:]
    nonisolated private static let disposalQueue = DispatchQueue(label: "glide.lab.decoder-disposal")
    static var pendingCount: Int { pending.count }
    private let id = UUID()
    private var player: VLCMediaPlayer?
    private let drawable: UIView
    private let resource: PlaybackResource
    private init(_ player: VLCMediaPlayer, drawable: UIView, resource: PlaybackResource) {
        self.player = player; self.drawable = drawable; self.resource = resource
    }
    static func retire(_ player: VLCMediaPlayer, drawable: UIView, resource: PlaybackResource) {
        let session = VLCRetiredPlayback(player, drawable: drawable, resource: resource)
        pending[session.id] = session
        drawable.removeFromSuperview()
        player.delegate = session
        player.stop()
    }
    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        Task { @MainActor [self] in finishIfStopped() }
    }
    private func finishIfStopped() {
        guard let player, player.state == .stopped else { return }
        player.delegate = nil
        player.drawable = nil
        // libVLC's final release joins its worker thread. The worker can still
        // dispatch UIKit teardown to main after the stopped notification.
        let release = VLCBackgroundRelease(player)
        self.player = nil
        // Leave this callback and its strong local reference before transferring
        // final ownership. Keep the UIKit view and file lease on main until done.
        DispatchQueue.main.async { [self] in
            Self.disposalQueue.async {
                release.dispose()
                Task { @MainActor [self] in Self.pending[self.id] = nil }
            }
        }
    }
}

private final class VLCBackgroundRelease: @unchecked Sendable {
    private var player: VLCMediaPlayer?
    init(_ player: VLCMediaPlayer) { self.player = player }
    func dispose() { autoreleasepool { player = nil } }
}
