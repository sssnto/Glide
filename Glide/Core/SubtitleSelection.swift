import Foundation

struct SubtitleIdentity: Codable, Equatable, Sendable {
    var components: [String]
    init(video: Video, server: MediaServer?) throws {
        if let server {
            let path: String
            switch server.kind {
            case .local:
                path = try video.localRelativePath ?? video.url.map { try LocalMediaIdentity.relativePath(root: server.address, file: $0) } ?? video.id
            case .smb:
                guard let url = video.url else { throw MediaError.message("找不到视频位置。") }
                path = try SMBLocation(server.address).relativePath(url)
            case .jellyfin, .emby: path = video.remoteID ?? video.id
            case .webDAV:
                guard let url = video.url, DirectoryScope.contains(root: server.address, child: url) else { throw MediaError.message("视频超出了来源目录。") }
                path = url.path
            }
            // Bookmarks survive sandbox relocation; reauthorizing a different root
            // gets a different identity without persisting its authorization bytes.
            let root = server.kind == .local ? (server.localBookmark?.base64EncodedString() ?? "managed") : MediaFilePath.display(server.address.absoluteString) ?? ""
            components = [server.id.uuidString, server.kind.rawValue, root, server.username,
                          server.smb?.domain ?? "", String(server.smb?.guest ?? false), path]
        } else { components = ["standalone", video.id] }
    }
}

struct SubtitleRevision: Codable, Equatable, Sendable {
    var size: UInt64
    var modified: Date?
}

struct SidecarSubtitle: Identifiable, Equatable, Sendable {
    var url: URL
    var name: String
    var language: String?
    var forced: Bool
    var id: String { name }
}

/// Only a video's exact stem and recognized language/accessibility suffixes match.
enum SidecarSubtitleMatch {
    static func candidate(videoName: String, url: URL) -> SidecarSubtitle? {
        guard ["srt", "vtt", "ass", "ssa"].contains(url.pathExtension.lowercased()) else { return nil }
        let stem = (videoName as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping
        let subtitle = url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
        guard subtitle.lowercased().hasPrefix(stem.lowercased()) else { return nil }
        let suffix = String(subtitle.dropFirst(stem.count))
        var language: String?
        var forced = false
        if !suffix.isEmpty {
            guard let first = suffix.first, ". _-".contains(first) else { return nil }
            // Keep script/region tags intact before separating other suffixes.
            var normalized = suffix.lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: "zh-hans", with: "chs")
                .replacingOccurrences(of: "zh-cn", with: "chs").replacingOccurrences(of: "zh-sg", with: "chs")
                .replacingOccurrences(of: "zh-hant", with: "cht").replacingOccurrences(of: "zh-tw", with: "cht")
                .replacingOccurrences(of: "zh-hk", with: "cht")
            for tag in ["en-us", "en-gb", "ja-jp", "ko-kr", "fr-fr", "de-de", "es-es", "pt-br", "pt-pt", "ru-ru"] {
                normalized = normalized.replacingOccurrences(of: tag, with: String(tag.prefix(2)))
            }
            let parts = normalized.split(whereSeparator: { ". _-".contains($0) }).map(String.init)
            guard !parts.isEmpty else { return nil }
            for part in parts {
                if let code = languageCode(part) {
                    guard language == nil || language == code else { return nil }
                    language = code
                } else if part == "forced" || part == "强制" { forced = true }
                else if !["sdh", "cc", "default", "utf8", "字幕"].contains(part) { return nil }
            }
        }
        return SidecarSubtitle(url: url, name: url.lastPathComponent, language: language, forced: forced)
    }

    static func languageCode(_ value: String) -> String? {
        switch value.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "chs", "sc", "简体", "简中", "简体中文", "zh-hans", "zh-cn", "zh-sg": "zh-Hans"
        case "cht", "tc", "繁体", "繁體", "繁中", "繁體中文", "繁体中文", "zh-hant", "zh-tw", "zh-hk": "zh-Hant"
        case "zh", "chi", "zho", "中文": "zh"
        case "en", "eng", "english", "英文": "en"
        case "ja", "jpn", "日文": "ja"
        case "ko", "kor", "韩文": "ko"
        case "fr", "fra", "fre": "fr"
        case "de", "deu", "ger": "de"
        case "es", "spa": "es"
        case "it", "ita": "it"
        case "pt", "por": "pt"
        case "ru", "rus": "ru"
        default: nil
        }
    }

    static func automatic(_ candidates: [SidecarSubtitle], language: String, forcedOnly: Bool) -> SidecarSubtitle? {
        guard language != "off" else { return nil }
        let eligible = candidates.filter { !forcedOnly || $0.forced }
        if eligible.count == 1 { return eligible[0] }
        guard !language.isEmpty else { return nil }
        let preferred = languageCode(language) ?? LanguagePreference.normalized(language)
        var matches = eligible.filter { $0.language == preferred }
        if matches.isEmpty, preferred == "zh" { matches = eligible.filter { $0.language?.hasPrefix("zh") == true } }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct SubtitleEmbeddedTrack: Codable, Equatable, Sendable {
    var engine: PlaybackEngineID
    var id: String
    var name: String
    var language: String?
    var forced: Bool

    func match(in tracks: [PlaybackTrack], engine: PlaybackEngineID) -> PlaybackTrack? {
        if self.engine == engine, let exact = tracks.first(where: { $0.id == id && $0.displayName == name && $0.language == language }) { return exact }
        let matches = tracks.filter { $0.displayName == name && $0.language == language && $0.forced == forced }
        if matches.count == 1 { return matches[0] }
        guard self.engine != engine, let language, !language.isEmpty else { return nil }
        let semantic = tracks.filter { LanguagePreference.normalized($0.language) == LanguagePreference.normalized(language) && $0.forced == forced }
        return semantic.count == 1 ? semantic[0] : nil
    }
}

/// Server indices belong to one media version, never to the reduced HLS track list.
struct SubtitleServerTrack: Codable, Equatable, Sendable {
    var mediaSourceID: String
    var index: Int
    var name: String
    var language: String?
    var codec: String?
    var forced: Bool
    init(mediaSourceID: String, stream: CatalogItem.Stream) {
        self.mediaSourceID = mediaSourceID; index = stream.Index
        name = stream.label + " · #\(stream.Index)"; language = stream.Language
        codec = stream.Codec; forced = stream.IsForced == true
    }
    func match(in streams: [CatalogItem.Stream], mediaSourceID: String) -> CatalogItem.Stream? {
        guard self.mediaSourceID == mediaSourceID else { return nil }
        return streams.first { $0.Type == "Subtitle" && $0.Index == index
            && $0.Codec == codec && $0.Language == language && ($0.IsForced == true) == forced }
    }
}

enum SubtitleChoice: Codable, Equatable, Sendable {
    case off
    case sidecar(name: String, digest: String)
    case imported(file: String, name: String, digest: String)
    case embedded(SubtitleEmbeddedTrack)
    case server(SubtitleServerTrack)

    var suppressesEmbedded: Bool {
        switch self { case .off, .sidecar, .imported, .server: true; case .embedded: false }
    }
    var managedFile: String? { if case .imported(let file, _, _) = self { file } else { nil } }
    var importedCopy: ImportedSubtitleCopy? {
        if case .imported(let file, let name, let digest) = self { ImportedSubtitleCopy(file: file, name: name, digest: digest) } else { nil }
    }
}

struct ImportedSubtitleCopy: Codable, Equatable, Sendable {
    var file: String
    var name: String
    var digest: String
    var choice: SubtitleChoice { .imported(file: file, name: name, digest: digest) }
}

struct SubtitleMemory: Codable, Equatable, Sendable {
    var sourceID: UUID?
    var videoID: String
    var revision: SubtitleRevision?
    var choice: SubtitleChoice
    var delay: Double
    var importedCopy: ImportedSubtitleCopy? = nil

    var safeDelay: Double { delay.isFinite ? min(30, max(-30, delay)) : 0 }
}

enum SubtitleDocument {
    static let maximumBytes = 2_000_000
    static func parse(_ data: Data, assText: Bool = false) throws -> [SubtitleCue] {
        guard data.count <= maximumBytes else { throw MediaError.message("字幕文件超过 2 MB，请使用较小的 SRT/VTT 文件。") }
        guard let text = String(data: data, encoding: .utf8) else { throw MediaError.message("字幕需要使用 UTF-8 编码的 SRT/VTT 文件。") }
        let cues = SubtitleCue.parse(text.replacingOccurrences(of: "\u{feff}", with: ""), assText: assText)
        guard !cues.isEmpty else { throw MediaError.message("没有识别到字幕，请使用 UTF-8 编码的 SRT/VTT 文件。") }
        return cues
    }
}

/// The primary key stays byte-for-byte compatible with 1.5.1–1.7.0 memories.
enum SubtitleLane: String, CaseIterable, Identifiable {
    case primary, secondary
    var id: String { rawValue }
    var title: String { self == .primary ? "主字幕" : "第二字幕" }
    func memoryKey(_ primary: String) -> String { self == .primary ? primary : primary + ":secondary-v1" }
}
