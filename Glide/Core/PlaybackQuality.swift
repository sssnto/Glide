import Foundation

enum PlaybackQuality: String, CaseIterable, Identifiable {
    case automatic, original, compatible, hd1080, hd720
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "自动"; case .compatible: return "原画兼容"
        case .original: return "原画直放"; case .hd1080: return "1080p"; case .hd720: return "720p" }
    }
    var detail: String {
        switch self {
        case .automatic: return "自动（兼容优先）"
        case .compatible: return "原画兼容（保留视频，允许转换音频）"
        case .original: return "原画直放（不转码）"
        case .hd1080: return "1080p 转码 · 8 Mbps"
        case .hd720: return "720p 转码 · 3 Mbps"
        }
    }
}

enum AutomaticPlaybackPolicy {
    /// A direct file that has already resolved but still has no first frame
    /// should not consume the generic 25-second network timeout.
    static let directStartupTimeout: TimeInterval = 8
    static func quality(at step: Int) -> PlaybackQuality {
        switch step { case 1: return .compatible; case 2: return .hd1080; case 3: return .hd720; default: return .automatic }
    }
    static func nextStep(after step: Int, stalled: Bool, preservingVideo: Bool, videoFailed: Bool = false, canDirectStream: Bool = true) -> Int? {
        guard step < 3 else { return nil }
        // Remuxing preserves video bits, so it cannot repair video decoding or buffering.
        // It also costs another PlaybackInfo request when the server disallows direct stream.
        if stalled || videoFailed || !preservingVideo || !canDirectStream { return step < 2 ? 2 : 3 }
        return step + 1
    }
}

/// Remember only media for which direct startup stalled and video conversion
/// subsequently displayed a frame. Entries expire so a repaired file can use
/// its original stream again without exposing a manual quality setting.
struct PlaybackRouteMemory {
    private let defaults: UserDefaults
    private let storageKey = "glide.learnedVideoConversion.v1"
    static let lifetime: TimeInterval = 24 * 60 * 60
    private static let capacity = 200

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func prefersVideoConversion(for videoID: String, at date: Date = Date()) -> Bool {
        guard let timestamp = entries()[videoID] else { return false }
        let age = date.timeIntervalSince1970 - timestamp
        return age >= 0 && age < Self.lifetime
    }

    func rememberVideoConversion(for videoID: String, at date: Date = Date()) {
        var valid = entries().filter { date.timeIntervalSince1970 - $0.value >= 0 && date.timeIntervalSince1970 - $0.value < Self.lifetime }
        valid[videoID] = date.timeIntervalSince1970
        if valid.count > Self.capacity {
            valid = Dictionary(uniqueKeysWithValues: valid.sorted { $0.value > $1.value }.prefix(Self.capacity).map { ($0.key, $0.value) })
        }
        defaults.set(valid, forKey: storageKey)
    }

    private func entries() -> [String: TimeInterval] {
        defaults.dictionary(forKey: storageKey) as? [String: TimeInterval] ?? [:]
    }
}

struct PlaybackStallTracker {
    private var stalls: [(date: Date, duration: TimeInterval)] = []
    mutating func record(at date: Date, duration: TimeInterval) -> Bool {
        guard duration.isFinite, duration >= 2.5 else { return false }
        stalls.removeAll { date.timeIntervalSince($0.date) > 90 }
        stalls.append((date, duration))
        return duration >= 8 || (stalls.count >= 2 && stalls.reduce(0) { $0 + $1.duration } >= 5)
    }
}

enum JellyfinPlaybackPolicy {
    static func body(userID: String, quality: PlaybackQuality, directVideoCodecs: String = "h264,hevc") -> [String: Any] {
        let bitrate = quality == .hd1080 ? 8_000_000 : quality == .hd720 ? 3_000_000 : 200_000_000
        var profile: [String: Any] = ["Name": "Glide iOS", "MaxStreamingBitrate": bitrate,
            "DirectPlayProfiles": [["Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": directVideoCodecs, "AudioCodec": "aac,mp3,alac"]],
            "TranscodingProfiles": [["Container": quality == .compatible || quality == .automatic ? "mp4" : "ts", "Type": "Video", "Protocol": "hls", "VideoCodec": quality == .compatible || quality == .automatic ? directVideoCodecs : "h264", "AudioCodec": "aac", "Context": "Streaming", "MaxAudioChannels": "2", "MinSegments": 2, "BreakOnNonKeyFrames": false]]]
        // Native HEVC can retain HDR in fMP4. AVC conversion must target SDR,
        // rather than advertising H.264 High 10 / PQ as a usable iOS output.
        var avcConditions: [[String: Any]] = [
            ["Condition": "EqualsAny", "Property": "VideoRangeType", "Value": "SDR", "IsRequired": false],
            ["Condition": "LessThanEqual", "Property": "VideoBitDepth", "Value": "8", "IsRequired": false],
            ["Condition": "EqualsAny", "Property": "VideoProfile", "Value": "baseline|constrained baseline|main|high", "IsRequired": false]]
        if quality == .hd1080 || quality == .hd720 {
            let width = quality == .hd720 ? "1280" : "1920"
            let height = quality == .hd720 ? "720" : "1080"
            avcConditions += [
                ["Condition": "LessThanEqual", "Property": "Width", "Value": width, "IsRequired": true],
                ["Condition": "LessThanEqual", "Property": "Height", "Value": height, "IsRequired": true]]
        }
        profile["CodecProfiles"] = [["Type": "Video", "Codec": "h264", "Conditions": avcConditions]]
        return ["UserId": userID, "DeviceProfile": profile, "MaxStreamingBitrate": bitrate, "StartTimeTicks": 0,
                "EnableDirectPlay": quality == .automatic || quality == .original, "EnableDirectStream": quality == .automatic || quality == .compatible,
                "EnableTranscoding": quality != .original && quality != .compatible, "AllowVideoStreamCopy": quality != .hd1080 && quality != .hd720,
                "AllowAudioStreamCopy": quality != .hd1080 && quality != .hd720]
    }
    static func transcodeURL(_ url: URL, quality: PlaybackQuality) -> URL {
        guard quality == .hd1080 || quality == .hd720 else { return url }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let limits = quality == .hd720
            ? ["MaxWidth": "1280", "MaxHeight": "720", "VideoBitrate": "2808000", "AudioBitrate": "192000", "AllowVideoStreamCopy": "false", "AllowAudioStreamCopy": "false", "VideoCodec": "h264", "h264-rangetype": "SDR"]
            : ["MaxWidth": "1920", "MaxHeight": "1080", "VideoBitrate": "7808000", "AudioBitrate": "192000", "AllowVideoStreamCopy": "false", "AllowAudioStreamCopy": "false", "VideoCodec": "h264", "h264-rangetype": "SDR"]
        let keys = Set(limits.keys.map { $0.lowercased() })
        parts.queryItems = (parts.queryItems ?? []).filter { !keys.contains($0.name.lowercased()) }
            + limits.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }
}
