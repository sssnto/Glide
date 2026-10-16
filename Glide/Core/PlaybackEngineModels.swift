import Foundation

enum PlaybackEngineID: String, Codable, Sendable { case avPlayer, vlc }

/// A saved local preference must never send a remote or authenticated resource
/// to an adapter that only implements local file access.
enum PlaybackEngineSelection {
    static func resolve(preferred: PlaybackEngineID, localFile: Bool, hasHeaders: Bool) -> PlaybackEngineID {
        localFile && !hasHeaders ? preferred : .avPlayer
    }
}

enum PlaybackEngineCapability: String, Hashable, Sendable {
    case pictureInPicture, externalPlayback, timelinePreview, tracks, preloading, aspectFill
}

struct PlaybackEngineDescriptor: Equatable, Sendable {
    var id: PlaybackEngineID
    var title: String
    var capabilities: Set<PlaybackEngineCapability>
    static let native = Self(id: .avPlayer, title: "AVPlayer · 系统播放器",
        capabilities: [.pictureInPicture, .externalPlayback, .timelinePreview, .tracks, .preloading, .aspectFill])
}

struct PlaybackTrack: Identifiable, Equatable, Hashable, Sendable {
    enum Kind: String, Sendable { case audio, subtitle }
    var id: String
    var kind: Kind
    var displayName: String
    var language: String?
    var forced: Bool
}

enum EnginePlaybackPhase: Sendable { case idle, preparing, playing, paused, waiting, failed }

struct PlaybackEngineSnapshot {
    var hasItem = false
    var ready = false
    var phase: EnginePlaybackPhase = .idle
    var time: Double = 0
    var duration: Double = 0
    var buffered: [BufferedRange] = []
    var frameReady = false
    var externalPlayback = false
    var width: Int?
    var height: Int?
    var bitrate: Int?
    var indicatedBitrate: Int?
    var droppedVideoFrames: Int?
    var nativeStalls: Int?
    var waitingReason: String?
    var bufferEmpty: Bool?
    var rebufferCount: Int?
    var lastResumeBufferedAhead: Double?
    var rebufferElapsedSeconds: Double?
    var lastRebufferSeconds: Double?
    var bufferFull: Bool?
    var likelyToKeepUp: Bool?
    var nativeTimeControlStatus: String?
    var accessLogBytesTransferred: Int64?
    var accessLogTransferSeconds: Double?
}

/// An old async load, seek, or thumbnail must never publish into a newer item.
struct PlaybackEngineLifetime {
    struct Seek: Equatable { let load: UUID; let request: UUID }
    private(set) var load = UUID()
    private var seek: Seek?
    mutating func begin() -> UUID { load = UUID(); seek = nil; return load }
    func accepts(_ token: UUID) -> Bool { token == load }
    mutating func beginSeek() -> Seek {
        let token = Seek(load: load, request: UUID()); seek = token; return token
    }
    mutating func finishSeek(_ token: Seek) -> Bool {
        guard token == seek, token.load == load else { return false }
        seek = nil; return true
    }
    mutating func cancelSeek() { seek = nil }
}

enum MediaContainer: String, Codable, Sendable {
    case mp4, quickTime, matroska, avi, transportStream, unknown
    var title: String {
        switch self {
        case .mp4: "MP4 / ISO Base Media"
        case .quickTime: "QuickTime / MOV"
        case .matroska: "Matroska / WebM"
        case .avi: "AVI"
        case .transportStream: "MPEG-TS"
        case .unknown: "未识别"
        }
    }
    /// A bounded signature hint, independent of the extension; never a decode guarantee.
    static func identify(_ data: Data) -> Self {
        let b = Array(data.prefix(4096))
        if b.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return .matroska }
        if b.count >= 12, String(bytes: b[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: b[8..<12], encoding: .ascii) == "AVI " { return .avi }
        if b.count >= 12, String(bytes: b[4..<8], encoding: .ascii) == "ftyp" {
            return String(bytes: b[8..<12], encoding: .ascii) == "qt  " ? .quickTime : .mp4
        }
        if b.count >= 8, ["moov", "mdat", "wide"].contains(String(bytes: b[4..<8], encoding: .ascii) ?? "") { return .quickTime }
        if b.count > 376, b[0] == 0x47, b[188] == 0x47, b[376] == 0x47 { return .transportStream }
        return .unknown
    }
}

struct LocalMediaInspection: Codable, Equatable, Sendable {
    var container: MediaContainer = .unknown
    var playable: Bool?
    var videoTracks: Int?
    var audioTracks: Int?
    var subtitleTracks: Int?
    var videoCodec: String?
    var audioCodecs: [String] = []
    var hasNoVideo: Bool { playable == true && videoTracks == 0 }
    var summary: String { playable.map { $0 ? "系统允许尝试播放" : "系统判定不可播放" } ?? "未能完成系统检查" }
    var failureMessage: String? {
        if hasNoVideo { return "此文件没有视频轨道。当前版本用于视频观看，请选择含画面的视频文件。" }
        if playable == false { return "当前播放器无法播放此文件。文件可能损坏，或封装、编码不受系统支持。可尝试兼容的 MP4／MOV 文件，或通过 Jellyfin 转码观看。" }
        return nil
    }
}
