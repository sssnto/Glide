import Foundation

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
