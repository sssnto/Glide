import AVFoundation
import UIKit

/// Only this rendering boundary knows how a particular engine supplies a view.
enum PlaybackPresentation {
    case native(AVPlayer)
    case custom(UIView)
}

@MainActor protocol PlaybackPreload { var engineID: PlaybackEngineID { get } }

struct PlaybackEngineOptions {
    var allowsCellular: Bool
    var subtitleScale: Double
    var forwardBuffer: Double
    var peakBitrate: Double = 0
    var inspectWideColor = false
}

struct PlaybackOutputEvidence {
    var codec: String?
    var transfer: String?
    var primaries: String?
    var matrix: String?
    var source: String?
}

enum PlaybackEngineEvent {
    case installed, clock, stateChanged, ready, frameReady, ended
    case failed(Error)
    case inspection(LocalMediaInspection)
    case output(PlaybackOutputEvidence)
    case diagnostic(String)
}

/// Resource resolution, server recovery and user intent stay in PlaybackController.
/// Implementations own assets, decoder controls, tracks, and async cancellation.
@MainActor protocol PlaybackEngine: AnyObject {
    var descriptor: PlaybackEngineDescriptor { get }
    var presentation: PlaybackPresentation { get }
    var snapshot: PlaybackEngineSnapshot { get }
    var subtitleClock: Double? { get }
    var tracks: [PlaybackTrack] { get }
    var selectedAudioID: String? { get }
    var selectedSubtitleID: String? { get }
    var onEvent: ((PlaybackEngineEvent) -> Void)? { get set }
    func load(_ resource: PlaybackResource, preload: (any PlaybackPreload)?, options: PlaybackEngineOptions) async throws
    func play(rate: Float)
    func pause()
    func setRate(_ rate: Float, playing: Bool)
    func seek(to: Double, tolerance: Double, completion: @escaping (Bool, Double) -> Void)
    func cancelPendingSeeks()
    func setForwardBuffer(_ seconds: Double)
    func selectTrack(_ id: String?, kind: PlaybackTrack.Kind)
    func inspectOutput()
    func preview(at: Double) async -> UIImage?
    func stop()
}

@MainActor extension PlaybackEngine { var subtitleClock: Double? { snapshot.time } }
