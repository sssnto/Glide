import Foundation

struct UnifiedRecord: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var binding: String
    var sourceName: String
    var video: Video
    var providers: [String: String] = [:]
    var year: Int?
    var overview: String?
    var mediaSource: CatalogItem.Source?
    var isDefault = true
    var offline = false
    var updatedAt = Date()
    var kind: String { video.mediaType ?? "Video" }
    var fileIdentity: String { binding + ":" + video.id }
    var providerKey: String? { UnifiedLibraryGrouping.providerKey(providers, type: kind) }
    /// Stored metadata never contains a resolved playback URL, server path or auth.
    func sanitized() -> Self {
        var copy = self
        copy.video = PersonalVideo(video: video).video
        copy.video.url = nil; copy.video.artwork = nil
        copy.video.title = String(copy.video.title.prefix(1000)); copy.video.subtitle = String(copy.video.subtitle.prefix(1000))
        copy.sourceName = String(copy.sourceName.prefix(200)); copy.overview = copy.overview.map { String($0.prefix(6000)) }
        copy.mediaSource?.Path = nil
        copy.mediaSource?.MediaAttachments = nil
        if let streams = copy.mediaSource?.MediaStreams { copy.mediaSource?.MediaStreams = Array(streams.prefix(128)) }
        copy.providers = providers.filter { $0.key.count <= 20 && $0.value.count <= 100 }
        return copy
    }
}

struct UnifiedWork: Identifiable, Equatable, Sendable {
    var id: String
    var variants: [UnifiedRecord]
    var title: String { variants.first?.video.title ?? "" }
    var kind: String { variants.first?.kind ?? "Video" }
    var year: Int? { variants.compactMap(\.year).first }
    var hasOffline: Bool { variants.contains(where: \.offline) }
}

enum UnifiedFilter: String, CaseIterable, Identifiable, Sendable {
    case all, movies, series, videos, downloaded
    var id: String { rawValue }
    var title: String { switch self { case .all: "全部"; case .movies: "电影"; case .series: "剧集"; case .videos: "视频"; case .downloaded: "已下载" } }
    func accepts(_ record: UnifiedRecord) -> Bool {
        switch self {
        case .all: true
        case .movies: record.kind == "Movie"
        case .series: ["Series", "Episode"].contains(record.kind)
        case .videos: !["Movie", "Series", "Episode"].contains(record.kind)
        case .downloaded: record.offline
        }
    }
}

enum UnifiedLibraryGrouping {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func providerKey(_ providers: [String: String], type: String) -> String? {
        guard ["Movie", "Series", "Episode"].contains(type) else { return nil }
        let values = Dictionary(providers.map { (normalized($0.key), normalized($0.value)) }, uniquingKeysWith: { a, b in a == b ? a : "" })
        for key in ["tmdb", "tvdb", "imdb"] {
            guard let value = values[key], !value.isEmpty, value.count <= 32 else { continue }
            if key == "imdb" {
                guard value.hasPrefix("tt"), value.dropFirst(2).count >= 5, value.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            } else {
                guard value.allSatisfy({ $0.isASCII && $0.isNumber }), let number = UInt64(value), number > 0 else { continue }
            }
            return "\(type):\(key):\(key == "imdb" ? value : String(UInt64(value)!))"
        }
        return nil
    }
    static func works(_ records: [UnifiedRecord], query: String, filter: UnifiedFilter = .all) -> [UnifiedWork] {
        // Only identical file identity can inherit a provider ID (e.g. its offline copy).
        let identities = Dictionary(records.compactMap { row in row.providerKey.map { (row.fileIdentity, $0) } }, uniquingKeysWith: { min($0, $1) })
        var groups = [String: [UnifiedRecord]](), seen = Set<String>()
        for row in records where seen.insert(row.id).inserted {
            let key = row.providerKey ?? identities[row.fileIdentity] ?? "file:" + row.fileIdentity
            groups[key, default: []].append(row)
        }
        var safeGroups = [String: [UnifiedRecord]]()
        for (key, rows) in groups {
            let conflicting = ["tmdb", "tvdb", "imdb"].contains { provider in
                Set(rows.compactMap { row in
                    let matching = row.providers.filter { normalized($0.key) == provider }
                    return providerKey(matching, type: row.kind)
                }).count > 1
            }
            if conflicting { for row in rows { safeGroups["file:" + row.fileIdentity, default: []].append(row) } }
            else { safeGroups[key] = rows }
        }
        let terms = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        return safeGroups.compactMap { key, rows in
            let variants = rows.filter { filter.accepts($0) }.sorted {
                if $0.offline != $1.offline { return $0.offline }
                if $0.isDefault != $1.isDefault { return $0.isDefault }
                return $0.id < $1.id
            }
            guard !variants.isEmpty else { return nil }
            // Match an alternate title/source too, while keeping all versions visible.
            let text = normalized(rows.map { [$0.video.title, $0.video.seriesTitle ?? "", $0.sourceName, $0.year.map(String.init) ?? ""].joined(separator: " ") }.joined(separator: " "))
            guard terms.allSatisfy({ text.contains($0) }) else { return nil }
            return UnifiedWork(id: key, variants: variants)
        }.sorted {
            let a = normalized($0.title), b = normalized($1.title)
            return a == b ? $0.id < $1.id : a < b
        }
    }
    static func preferred(in work: UnifiedWork, saved: String?) -> UnifiedRecord? {
        guard let saved else { return work.variants.first }
        return work.variants.first { $0.id == saved }
    }
    static func canReuseDownload(savedSourceID: String?, requestedSourceID: String?) -> Bool {
        requestedSourceID == nil || savedSourceID == requestedSourceID
    }
}

struct UnifiedLibrarySnapshot: Codable, Sendable {
    var records: [UnifiedRecord] = []
    var preferred: [String: String] = [:]
}
