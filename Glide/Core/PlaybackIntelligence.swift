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
    static func ahead(of time: Double, in ranges: [BufferedRange]) -> TimeInterval {
        guard time.isFinite, let range = ranges.first(where: { $0.start <= time && $0.end > time }) else { return 0 }
        return max(0, range.end - time)
    }
}

enum NativePlaybackPolicy {
    /// Keep startup light, then cover 30 seconds of viewing at the current speed.
    /// After a significant rebuffer, prefer 45 seconds, with a bounded media target.
    static func forwardBufferDuration(local: Bool, firstFrame: Bool, rate: Float, rebuffered: Bool = false) -> TimeInterval {
        guard !local else { return 0 }
        guard firstFrame else { return 2 }
        let speed = rate.isFinite && rate > 0 ? Double(rate) : 1
        return min(90, (rebuffered ? 45 : 30) * max(1, speed))
    }
    static func seekTolerance(local: Bool, buffered: Bool) -> TimeInterval {
        local ? 0.15 : buffered ? 0.25 : 0.5
    }
}

/// Hysteresis for original 4K / high-bitrate network video: avoid resuming on
/// each tiny packet while the same native item is starving. Goals use media
/// time, not observed download throughput (which is not the media bitrate).
enum NativeRebufferPolicy {
    static let maximumHold: TimeInterval = 15
    static let cooldown: TimeInterval = 5
    static func eligible(local: Bool, preservesVideo: Bool, width: Int?, height: Int?, bitrate: Int?) -> Bool {
        !local && preservesVideo && (max(width ?? 0, height ?? 0) >= 3840 || (bitrate ?? 0) >= 20_000_000)
    }
    static func resumeGoal(rate: Float, remaining: Double) -> Double? {
        guard remaining.isFinite, remaining > 0.5 else { return nil }
        let speed = rate.isFinite && rate > 0 ? Double(rate) : 1
        return min(12, 6 * max(1, speed), remaining - 0.15)
    }
    static func canResume(ahead: Double, rate: Float, remaining: Double, bufferFull: Bool) -> Bool {
        guard ahead.isFinite, ahead >= 0 else { return false }
        guard let goal = resumeGoal(rate: rate, remaining: remaining) else { return true }
        let speed = rate.isFinite && rate > 0 ? Double(rate) : 1
        return ahead >= goal || (bufferFull && ahead >= min(goal, 2 * max(1, speed)))
    }
}

/// A Jellyfin master can describe SDR/baseline while its encoded segment is
/// HDR/high. AVPlayer may reject that master with CoreMedia -12927, even though
/// the media playlist decodes. Only unwrap one self-contained AVC rendition;
/// HDR/HEVC, adaptive masters and external tracks/session keys stay intact.
enum NativeHLSPlaylist {
    /// Prefer the first native HDR rendition only when the server actually
    /// declares one first. Keep the entire master and native eligibility checks.
    static func prefersFirstHDRVariant(master: URL, data: Data, sourceCodec: String?, sourceIsHDR: Bool) -> Bool {
        guard sourceIsHDR, sourceCodec?.lowercased() == "hevc",
              data.count <= 262_144, let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first == "#EXTM3U",
              !lines.contains(where: { $0.hasPrefix("#EXT-X-DEFINE:") || $0.hasPrefix("#EXT-X-CONTENT-STEERING:") }) else { return false }
        var attributes: [String: String]?
        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                guard attributes == nil, let parsed = streamAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count))) else { return false }
                attributes = parsed
            } else if !line.isEmpty && !line.hasPrefix("#") {
                guard let attributes,
                      let bandwidth = attributes["BANDWIDTH"].flatMap(Int.init), bandwidth > 0,
                      ["PQ", "HLG"].contains(attributes["VIDEO-RANGE"] ?? ""),
                      let codecs = attributes["CODECS"]?.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }),
                      codecs.contains(where: { $0.hasPrefix("hvc1.") || $0.hasPrefix("hev1.") }),
                      !codecs.contains(where: { $0.hasPrefix("avc1.") || $0.hasPrefix("avc3.") || $0.hasPrefix("av01.") || $0.hasPrefix("dvh1.") || $0.hasPrefix("dvhe.") }),
                      let url = URL(string: line, relativeTo: master)?.absoluteURL,
                      ServerURL.sameOrigin(master, url), url.pathExtension.lowercased() == "m3u8",
                      url != master, url.user == nil, url.password == nil else { return false }
                return true
            }
        }
        return false
    }
    private static func streamAttributes(_ text: String) -> [String: String]? {
        var fields: [String] = [], field = "", quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if character == ",", !quoted { fields.append(field); field = "" }
            else { field.append(character) }
        }
        guard !quoted else { return nil }
        fields.append(field)
        var result: [String: String] = [:]
        for field in fields {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let key = pair[0].trimmingCharacters(in: .whitespaces)
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty, result[key] == nil else { return nil }
            if value.first == "\"", value.last == "\"" { value.removeFirst(); value.removeLast() }
            guard !value.contains("\"") else { return nil }
            result[key] = value
        }
        return result
    }
    static func mediaURL(master: URL, data: Data, sourceIsHDR: Bool = false) -> URL? {
        // An SDR declaration cannot prove that an HDR source was tone-mapped.
        // Keep the master, so native validation cannot be bypassed by this repair.
        guard !sourceIsHDR else { return nil }
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

enum NativeColorPolicy {
    static func isHDR(range: String?, transfer: String? = nil) -> Bool {
        // Explicit PQ/HLG transfer metadata takes precedence over an SDR label.
        if hdrTransfer(transfer) { return true }
        let range = (range ?? "").uppercased()
        if range == "SDR" || range == "DOVIWITHSDR" { return false }
        return range.contains("HDR") || range.contains("HLG") || range.contains("DOVI")
    }
    private static func hdrTransfer(_ transfer: String?) -> Bool {
        let value = (transfer ?? "").uppercased()
        return value.contains("2084") || value.contains("HLG") || value.contains("B67") || value == "PQ"
    }
    static func unsupportedAVCOutput(codec: String?, transfer: String?) -> Bool {
        ["avc1", "avc3", "h264"].contains((codec ?? "").lowercased()) && hdrTransfer(transfer)
    }
    static func unexpectedHDRTransfer(requestedRange: String?, actualTransfer: String?) -> Bool {
        requestedRange?.uppercased() == "SDR" && hdrTransfer(actualTransfer)
    }
    static func outputOptions(_ url: URL) -> (codec: String?, range: String?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let codec = items.last { $0.name.lowercased() == "videocodec" }?.value
        // A codec-qualified option says nothing about other HLS candidates.
        let rangeKey = ["h264", "hevc"].contains(codec?.lowercased() ?? "") ? codec!.lowercased() + "-rangetype" : nil
        let range = rangeKey.flatMap { key in items.last { $0.name.lowercased() == key }?.value }
        return (codec.flatMap(PlaybackDiagnostic.token), range.flatMap(PlaybackDiagnostic.token))
    }
    static func preferHEVCForHDR(_ url: URL, sourceCodec: String?, sourceIsHDR: Bool) -> URL {
        guard sourceIsHDR, sourceCodec?.lowercased() == "hevc",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = parts.queryItems?.last(where: { $0.name.lowercased() == "videocodec" })?.value else { return url }
        let candidates = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        // The negotiated candidate list already reflects device capabilities.
        // Request HEVC for HDR. A server may still add an AVC fallback to its
        // master; inspect the actual master before influencing initial selection.
        guard candidates.count > 1, candidates.contains("hevc") else { return url }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name.lowercased() != "videocodec" } + [URLQueryItem(name: "VideoCodec", value: "hevc")]
        return parts.url ?? url
    }
    static func constrainAVC(_ url: URL, sourceIsHDR: Bool) -> URL {
        guard sourceIsHDR, outputOptions(url).codec?.lowercased() == "h264",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let overrides = ["h264-rangetype": "SDR", "AllowVideoStreamCopy": "false"]
        let keys = Set(overrides.keys.map { $0.lowercased() })
        parts.queryItems = (parts.queryItems ?? []).filter { !keys.contains($0.name.lowercased()) }
            + overrides.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url ?? url
    }
}

struct PlaybackFailure: Codable, Equatable {
    var domain: String
    var code: Int
    init(domain: String, code: Int) {
        self.domain = [NSURLErrorDomain, NSOSStatusErrorDomain, "AVFoundationErrorDomain", "CoreMediaErrorDomain", "VideoToolboxErrorDomain", "GlideTransportError"].contains(domain) ? domain : "ApplicationError"
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
        if query["subtitlemethod"] == "encode" { return .videoConversion }
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
    var schema = 10
    var sourceKind: String?
    var subtitleMethod: String?
    var serverSubtitleIndex: Int?
    var preferredTextSubtitle: Bool?
    var clientSubtitleCueCount: Int?
    var clientSubtitleLanguage: String?
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
    var localMedia: LocalMediaInspection?
    var outputVideoCodec: String?
    var outputColorTransfer: String?
    var sourceColorTransfer: String?
    var sourceColorPrimaries: String?
    var sourceColorSpace: String?
    var outputColorPrimaries: String?
    var outputColorMatrix: String?
    var outputColorEvidence: String?
    var requestedOutputCodec: String?
    var requestedOutputRange: String?
    var playlistMode: String?
    var firstFrameSeconds: Double?
    var totalFirstFrameSeconds: Double?
    var attemptSeconds: [Double] = []
    var resourceReadySeconds: Double?
    var playerReadySeconds: Double?
    var outputWidth: Int?
    var outputHeight: Int?
    var observedBitrate: Int?
    var sourceBitrate: Int?
    var sourceFrameRate: Double?
    var indicatedBitrate: Int?
    var droppedVideoFrames: Int?
    var nativeStalls: Int?
    var waitingReason: String?
    var bufferEmpty: Bool?
    var rebufferCount: Int?
    var lastResumeBufferedAheadSeconds: Double?
    var rebufferElapsedSeconds: Double?
    var lastRebufferSeconds: Double?
    var bufferFull: Bool?
    var likelyToKeepUp: Bool?
    var nativeTimeControlStatus: String?
    var accessLogBytesTransferred: Int64?
    var accessLogTransferSeconds: Double?
    var activeBufferingSeconds: Double?
    var bufferingSeconds: Double = 0
    var bufferingCount = 0
    var forwardBufferTargetSeconds: Double?
    var bufferedAheadSeconds: Double?
    var recoveryCount = 0
    var directStreamFlag: Bool?
    var originalTransportAttempts = 0
    var originalTransportOutcome: String?
    var originalTransportFailure: [PlaybackFailure]?
    var errorCode: Int?
    var errorDomain: String?
    var errorChain: [PlaybackFailure]?
    var events: [String] = []
    mutating func event(_ code: String) {
        // Preserve earlier context when native notifications repeat every tick.
        guard events.last != code else { return }
        events.append(code); if events.count > 30 { events.removeFirst(events.count - 30) }
    }
    static func token(_ value: String?) -> String? {
        guard let value, value.count <= 48,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " ._-".unicodeScalars.contains($0) }) else { return nil }
        return value
    }
    var export: String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}" }
}
