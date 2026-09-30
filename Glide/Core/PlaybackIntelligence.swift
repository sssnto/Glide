import Foundation

struct BufferedRange: Equatable {
    var start: Double
    var end: Double
}

enum BufferedTimeline {
    static func normalized(_ ranges: [BufferedRange], duration: Double) -> [BufferedRange] {
        guard duration.isFinite, duration > 0 else { return [] }
        let bounded = ranges.compactMap { range -> BufferedRange? in
            guard range.start.isFinite, range.end.isFinite, range.end > range.start else { return nil }
            let start = max(0, min(duration, range.start))
            let end = max(0, min(duration, range.end))
            return end > start ? BufferedRange(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var merged: [BufferedRange] = []
        for range in bounded {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1].end = max(last.end, range.end)
            } else { merged.append(range) }
        }
        return merged
    }
    static func contains(_ time: Double, in ranges: [BufferedRange]) -> Bool {
        time.isFinite && ranges.contains { time >= $0.start && time <= $0.end - 0.25 }
    }
}

enum NativePlaybackPolicy {
    /// Keep startup light, then buffer enough media for about 15 seconds at the current speed.
    static func forwardBufferDuration(local: Bool, firstFrame: Bool, rate: Float) -> TimeInterval {
        guard !local else { return 0 }
        guard firstFrame else { return 2 }
        let speed = rate.isFinite && rate > 0 ? Double(rate) : 1
        return min(45, 15 * max(1, speed))
    }
    static func seekTolerance(local: Bool, buffered: Bool) -> TimeInterval {
        local ? 0.15 : buffered ? 0.25 : 0.5
    }
}

/// A Jellyfin master can describe SDR/baseline while its encoded segment is
/// HDR/high. AVPlayer may reject that master with CoreMedia -12927, even though
/// the media playlist decodes. Only unwrap one self-contained AVC rendition;
/// HDR/HEVC, adaptive masters and external tracks/session keys stay intact.
enum NativeHLSPlaylist {
    static func mediaURL(master: URL, data: Data) -> URL? {
        guard data.count <= 262_144, let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first == "#EXTM3U" else { return nil }
        let protectedTags = ["#EXT-X-MEDIA:", "#EXT-X-SESSION-KEY:", "#EXT-X-DEFINE:", "#EXT-X-CONTENT-STEERING:", "#EXT-X-START:"]
        guard !lines.contains(where: { line in protectedTags.contains(where: { line.hasPrefix($0) }) }) else { return nil }
        var variants: [String] = []
        var needsURI = false
        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                guard !needsURI else { return nil }
                guard line.contains("CODECS="), line.contains("avc1."),
                      !["VIDEO-RANGE=PQ", "VIDEO-RANGE=HLG", "SUPPLEMENTAL-CODECS="].contains(where: { line.contains($0) }) else { return nil }
                // Referenced rendition groups cannot be discarded, even if
                // the server omitted their EXT-X-MEDIA declarations.
                guard !["AUDIO=", "SUBTITLES=", "VIDEO="].contains(where: { line.contains($0) }) else { return nil }
                needsURI = true
            } else if !line.isEmpty && !line.hasPrefix("#") {
                guard needsURI else { return nil }
                variants.append(line); needsURI = false
            }
        }
        guard !needsURI, variants.count == 1,
              let url = URL(string: variants[0], relativeTo: master)?.absoluteURL,
              ServerURL.sameOrigin(master, url), url.pathExtension.lowercased() == "m3u8", url != master,
              url.user == nil, url.password == nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Relative URIs do not inherit their parent's query. Preserve only
        // Jellyfin authentication, never encoder parameters or session data.
        let tokenKeys = Set(["apikey", "api_key"])
        if !(parts.queryItems ?? []).contains(where: { tokenKeys.contains($0.name.lowercased()) }),
           let token = URLComponents(url: master, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { tokenKeys.contains($0.name.lowercased()) }) {
            parts.queryItems = (parts.queryItems ?? []) + [token]
        }
        return parts.url
    }
}

struct PlaybackFailure: Codable, Equatable {
    var domain: String
    var code: Int
    init(domain: String, code: Int) {
        self.domain = [NSURLErrorDomain, NSOSStatusErrorDomain, "AVFoundationErrorDomain", "CoreMediaErrorDomain", "VideoToolboxErrorDomain"].contains(domain) ? domain : "ApplicationError"
        self.code = code
    }
    static func chain(_ error: Error) -> [Self] {
        var result: [Self] = [], seen = Set<ObjectIdentifier>()
        var next: NSError? = error as NSError
        while let error = next, result.count < 4, seen.insert(ObjectIdentifier(error)).inserted {
            result.append(Self(domain: error.domain, code: error.code))
            next = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }
}

enum PlaybackDelivery: String, Codable {
    case direct, remux, audioConversion, videoConversion, serverStream, local
    var title: String {
        switch self {
        case .direct: return "原画直放"
        case .remux: return "原画重封装"
        case .audioConversion: return "原画 · 音频转换"
        case .videoConversion: return "视频转码"
        case .serverStream: return "服务器流（方式待确认）"
        case .local: return "本地播放"
        }
    }
    static func suspectHEVCMP4(_ codec: String?, tag: String?, container: String?) -> Bool {
        codec?.lowercased() == "hevc" && tag?.lowercased() == "hev1" && ["mp4", "m4v", "mov"].contains(container?.lowercased() ?? "")
    }
    static func negotiated(url: URL, quality: PlaybackQuality) -> Self {
        if quality == .hd1080 || quality == .hd720 { return .videoConversion }
        let pairs = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(pairs.map { ($0.name.lowercased(), ($0.value ?? "").lowercased()) }, uniquingKeysWith: { _, new in new })
        if query["videocodec"] == "copy" {
            return query["audiocodec"] == "copy" ? .remux : .audioConversion
        }
        return .serverStream // AllowVideoStreamCopy alone is not evidence of actual stream copying.
    }
}

/// Match semantic language preferences, never carry a file's stream index into another file.
enum LanguagePreference {
    static func normalized(_ value: String?) -> String {
        let code = (value ?? "").lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
        switch code { case "chi", "zho", "zh": return "zh"; case "eng", "en": return "en"; case "jpn", "ja": return "ja"; case "kor", "ko": return "ko"; default: return code }
    }
    static func stream(_ streams: [CatalogItem.Stream], language: String, forcedOnly: Bool = false) -> Int? {
        guard !language.isEmpty else { return nil }
        return streams.first { normalized($0.Language) == normalized(language) && (!forcedOnly || $0.IsForced == true) }?.Index
    }
}

struct ProgressSnapshot: Codable, Equatable {
    var position: Double
    var updatedAt: Date
    var pending: Bool
    /// Pending local viewing takes precedence until successfully reported; otherwise a fresh server read wins.
    func resolved(serverPosition: Double, serverLastPlayed: Date?) -> Double {
        guard serverPosition.isFinite, serverPosition >= 0 else { return position }
        if pending && (serverLastPlayed == nil || serverLastPlayed! <= updatedAt) { return position }
        return serverPosition
    }
}

/// Export only structured technical fields. Never serialize Error.localizedDescription, URL, title or stream DisplayTitle.
struct PlaybackDiagnostic: Codable {
    var schema = 3
    var version = ""
    var system = ""
    var device = ""
    var session = UUID().uuidString
    var requestedQuality = ""
    var delivery = ""
    var state = "准备中"
    var videoCodec: String?
    var codecTag: String?
    var profile: String?
    var bitDepth: Int?
    var width: Int?
    var height: Int?
    var level: Double?
    var videoRangeType: String?
    var dolbyVisionProfile: Int?
    var outputVideoCodec: String?
    var outputColorTransfer: String?
    var playlistMode: String?
    var firstFrameSeconds: Double?
    var totalFirstFrameSeconds: Double?
    var attemptSeconds: [Double] = []
    var resourceReadySeconds: Double?
    var playerReadySeconds: Double?
    var outputWidth: Int?
    var outputHeight: Int?
    var observedBitrate: Int?
    var bufferingSeconds: Double = 0
    var bufferingCount = 0
    var recoveryCount = 0
    var errorCode: Int?
    var errorDomain: String?
    var errorChain: [PlaybackFailure]?
    var events: [String] = []
    mutating func event(_ code: String) { events.append(code); if events.count > 30 { events.removeFirst(events.count - 30) } }
    static func token(_ value: String?) -> String? {
        guard let value, value.count <= 48,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " ._-".unicodeScalars.contains($0) }) else { return nil }
        return value
    }
    var export: String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}" }
}
