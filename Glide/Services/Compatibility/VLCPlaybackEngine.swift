import AVFoundation
import CoreText
import MobileVLCKit
import UIKit

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

/// Local-file compatibility adapter shared by Glide and the independent QA app.
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
    private var wasReady = false
    private var wasFrame = false
    private var failed = false
    private var ended = false
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
    func setVolume(_ value: Int32) { player?.audio?.volume = value }
    var playbackRate: Float { player?.rate ?? 0 }
    var isPlaying: Bool { player?.isPlaying ?? false }
    var subtitleSettled: Bool {
        !subtitleNeedsApplication && !subtitleRefreshPending && !isSeeking
            && ProcessInfo.processInfo.systemUptime >= subtitleSettlingUntil
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
            height: size.height > 0 ? Int(size.height) : nil)
    }
    func load(_ resource: PlaybackResource, preload: (any PlaybackPreload)?, options: PlaybackEngineOptions) async throws {
        stop()
        guard resource.url.isFileURL, resource.headers.isEmpty else { throw MediaError.message("兼容播放暂时仅支持本地文件。") }
        guard preload == nil else { throw MediaError.message("兼容播放暂不支持预加载。") }
        self.resource = resource
        let token = lifetime.load
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
        media.addOption(":start-paused")
        player.media = media
        self.player = player
        inspectionTask = Task { [weak self] in
            let hint = await Task.detached(priority: .utility) {
                defer { withExtendedLifetime(resource) {} }
                guard let file = try? FileHandle(forReadingFrom: resource.url) else { return MediaContainer.unknown }
                defer { try? file.close() }
                return MediaContainer.identify((try? file.read(upToCount: 4096)) ?? Data())
            }.value
            guard !Task.isCancelled, let self, self.lifetime.accepts(token) else { return }
            self.containerHint = hint; self.headerRead = true
        }
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
           player.state != .error, player.state != .ended, !player.isPlaying,
           player.state == .paused || !wasFrame,
           ProcessInfo.processInfo.systemUptime - lastPlayRequest >= 0.25 {
            requestPlayback(player)
        }
        let state = snapshot
        if state.phase != previousPhase {
            previousPhase = state.phase
            onEvent?(.stateChanged)
        }
        guard lifetime.accepts(token) else { return }
        if state.frameReady, !wasFrame { wasFrame = true; onEvent?(.frameReady) }
        guard lifetime.accepts(token) else { return }
        if player.state == .error, !failed {
            failed = true; onEvent?(.failed(MediaError.message("兼容播放器无法读取此文件，文件可能损坏或编码暂不支持。")))
        }
        guard lifetime.accepts(token) else { return }
        if player.state == .ended, !ended { ended = true; onEvent?(.ended) }
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
    func cancelPendingSeeks() { seeking?.cancel(); seeking = nil; lifetime.cancelSeek(); isSeeking = false }
    func seek(to time: Double, tolerance: Double, completion: @escaping (Bool, Double) -> Void) {
        guard player != nil, time.isFinite, time >= 0 else { completion(false, snapshot.time); return }
        cancelPendingSeeks()
        isSeeking = true
        let token = lifetime.beginSeek()
        let target = min(time, max(0, snapshot.duration - 0.1))
        seeking = Task { [weak self] in
            var submitted = false, stepped = false, stable = 0
            for _ in 0..<30 {
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
                    if !self.wantsPlayback, self.snapshot.duration > 0 { self.player?.position = Float(target / self.snapshot.duration) }
                    else { self.player?.time = VLCTime(int: Int32(target * 1000)) }
                    submitted = true
                    continue
                }
                // A paused input must decode its target frame to publish time.
                // Step after the queued seek, only for the surviving request.
                if !stepped, !self.wantsPlayback { self.player?.gotoNextFrame(); stepped = true }
                let actual = self.snapshot.time
                stable = abs(actual - target) <= max(0.5, tolerance) ? stable + 1 : 0
                // Paused frame stepping and seek completion are asynchronous.
                // Keep observing the real clock before acknowledging a paused
                // request, then reassert the surviving playback intent.
                if stable >= (self.wantsPlayback ? 2 : 5) {
                    guard self.lifetime.finishSeek(token) else { return }
                    self.isSeeking = false
                    if self.wantsPlayback { self.play(rate: self.desiredRate) }
                    else { self.player?.pause() }
                    completion(true, actual); return
                }
            }
            guard let self, self.lifetime.finishSeek(token) else { return }
            self.isSeeking = false
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
