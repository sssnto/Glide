import Foundation

/// In-memory only. Never Codable, URL userinfo, or diagnostics.
struct SMBPlaybackAccess {
    let username: String
    let password: String
    let options: SMBOptions
}

struct PlaybackResource {
    var url: URL
    var headers: [String: String] = [:]
    var sessionID: String?
    var mediaSourceID: String?
    var isTranscoding = false
    var delivery: PlaybackDelivery = .direct
    var videoStream: CatalogItem.Stream?
    var sourceBitrate: Int?
    var supportsDirectStream: Bool?
    var usesMediaPlaylist = false
    var prefersFirstHDRVariant = false
    var sourcePath: String?
    var localAccess: LocalFileAccess?
    var smb: SMBPlaybackAccess?
    var sourceContainer: String?
    var resolvedTracks: TrackSelection?
    var preferredTextSubtitle = false
    var serverSubtitleCues: [SubtitleCue] = []
    var serverSubtitleName: String?
    var serverSubtitleLanguage: String?
    var serverSubtitleTrack: SubtitleServerTrack?
    var serverSubtitleStreams: [CatalogItem.Stream] = []
    var serverAudioStreams: [CatalogItem.Stream] = []
    var serverAudioIndex: Int?
    var serverBitmapSubtitle: PGSSubtitle?
    var serverASSSubtitle: ASSSubtitle?
    var prefersSegmentedTransport: Bool {
        OriginalTransportPolicy.prefersSegments(local: url.isFileURL, delivery: delivery,
            width: videoStream?.Width, height: videoStream?.Height, bitrate: sourceBitrate ?? videoStream?.BitRate)
    }
    var sessionReportMethod: String { delivery == .direct || delivery == .local ? "DirectPlay" : delivery == .remux || delivery == .audioConversion ? "DirectStream" : "Transcode" }
}

/// Retained by the active playback resource, including after its source is deselected.
final class LocalFileAccess: @unchecked Sendable {
    let root: URL
    private let scoped: Bool
    init(root: URL) { self.root = root; scoped = root.startAccessingSecurityScopedResource() }
    deinit { if scoped { root.stopAccessingSecurityScopedResource() } }
}
