import Foundation

/// Stable, account-bound references only. Resolved media URLs never enter channel storage.
struct DiscoveryScope: Codable, Identifiable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case demo, catalog, directory, video }
    var kind: Kind
    var sourceID: UUID?
    var accountID: String?
    var key: String
    var name: String
    var id: String { "\(sourceID?.uuidString ?? "demo"):\(kind.rawValue):\(key)" }
    static let demo = Self(kind: .demo, key: "demo", name: "原创演示视频")
    func matches(_ server: MediaServer) -> Bool { sourceID == server.id && accountID == (server.userID ?? server.username) }
    func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200,
              key.count <= 2048, !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              kind == .demo || sourceID != nil, kind != .video || !key.isEmpty else { throw MediaError.message("内容范围无效，请重新选择。") }
        if kind == .directory {
            guard !key.hasPrefix("/"), !key.contains("\\"), !key.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                throw MediaError.message("目录超出了授权范围。")
            }
        }
        return self
    }
}

struct PrivateChannel: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var scopes: [DiscoveryScope]
    var unwatchedOnly = false
    var avoidRecent = true
    var createdAt = Date()
    var lastStarted: [String: Date] = [:]
    func validated() throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, value.name.count <= 60, !scopes.isEmpty, scopes.count <= 16 else {
            throw MediaError.message("请输入 1–60 字的频道名，并选择 1–16 个内容范围。")
        }
        var seen = Set<String>()
        value.scopes = try scopes.map { try $0.validated() }.filter { seen.insert($0.id).inserted }
        return value
    }
    mutating func recordStart(_ id: String, at date: Date) {
        lastStarted[id] = date
        lastStarted = Dictionary(uniqueKeysWithValues: lastStarted.sorted { $0.value > $1.value }.prefix(500).map { ($0.key, $0.value) })
    }
}

struct DiscoveryBatch: Sendable {
    var scope: DiscoveryScope
    var videos: [Video]
}

enum ChannelPlanner {
    static func seriesKey(_ video: Video) -> String? {
        guard video.mediaType == "Episode", let series = video.seriesID else { return nil }
        return "\(video.sourceID?.uuidString ?? "demo"):series:\(series)"
    }
    /// Round-robin groups; each series retains numeric episode order. No random
    /// file-level shuffle may jump ahead within an ongoing story.
    static func queue(_ batches: [DiscoveryBatch], channel: PrivateChannel, positions: [String: Double], now: Date = Date()) -> [Video] {
        var groups: [String: [Video]] = [:], order: [String] = [], seen = Set<String>()
        for batch in batches {
            for video in batch.videos where seen.insert(video.id).inserted {
                let group = seriesKey(video) ?? batch.scope.id
                if groups[group] == nil { order.append(group) }
                groups[group, default: []].append(video)
            }
        }
        for key in order {
            groups[key] = groups[key]?.filter { video in
                let complete = ContinuousWatching.completed(video, positions: positions)
                if channel.unwatchedOnly && complete { return false }
                // Resume an unfinished episode instead of skipping ahead in its story.
                if channel.avoidRecent, let date = channel.lastStarted[video.id], date > now.addingTimeInterval(-7 * 86400),
                   seriesKey(video) == nil || complete { return false }
                return true
            }
            if groups[key]?.first.flatMap(seriesKey) != nil { groups[key] = ContinuousWatching.ordered(groups[key] ?? []) }
            else {
                groups[key]?.sort {
                    let a = channel.lastStarted[$0.id] ?? .distantPast, b = channel.lastStarted[$1.id] ?? .distantPast
                    return a == b ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : a < b
                }
            }
        }
        var result: [Video] = [], round = 0
        while true {
            var added = false
            for key in order {
                if let values = groups[key], round < values.count { result.append(values[round]); added = true }
            }
            if !added { break }; round += 1
        }
        return result
    }
}

enum ViewingPreference: String, CaseIterable, Identifiable, Sendable {
    case any, movie, episode, shortVideo
    var id: String { rawValue }
    var title: String { switch self { case .any: "都可以"; case .movie: "电影"; case .episode: "剧集"; case .shortVideo: "短视频" } }
    func accepts(_ video: Video) -> Bool {
        switch self {
        case .any: true
        case .movie: video.mediaType == "Movie"
        case .episode: video.mediaType == "Episode"
        case .shortVideo: !["Movie", "Episode"].contains(video.mediaType ?? "") && video.duration <= 20 * 60
        }
    }
}

struct TimePick: Identifiable, Sendable {
    var video: Video
    var resumeAt: Double
    var remaining: Double
    var reasons: [String]
    var id: String { video.id }
}

/// Work identity is separate from an episode's title and from its playback source.
struct RecommendationMediaIdentity: Equatable {
    var title: String
    var episode: String?
    var facts: String?
    init(_ video: Video) {
        func clean(_ value: String?) -> String? {
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        let series = clean(video.seriesTitle), name = clean(video.title) ?? "未命名视频"
        let isEpisode = video.mediaType == "Episode" || series != nil || video.seriesID != nil
        title = isEpisode ? series ?? name : name
        var parts = [String]()
        if isEpisode {
            if let season = video.seasonNumber, season >= 0 { parts.append(season == 0 ? "特别篇" : "第 \(season) 季") }
            if let number = video.episodeNumber, number > 0 { parts.append("第 \(number) 集") }
            let compactName = name.lowercased().filter { !$0.isWhitespace }
            let generic = video.episodeNumber.map { ["第\($0)集", "episode\($0)", "ep\($0)", "e\($0)"].contains(compactName) } ?? false
            if let series, name != series, !generic { parts.append(name) }
            if series == nil { parts.append("剧名未提供") }
        }
        episode = parts.isEmpty ? nil : parts.joined(separator: " · ")
        var metadata = [String]()
        if isEpisode { metadata.append("剧集") }
        else if video.mediaType == "Movie" { metadata.append("电影") }
        else if video.mediaType == "MusicVideo" { metadata.append("音乐视频") }
        if let year = video.productionYear, (1800...9999).contains(year) { metadata.append(String(year)) }
        var seen = Set<String>()
        let genres = (video.genres ?? []).compactMap { clean($0) }.filter { seen.insert($0.lowercased()).inserted }.prefix(2)
        if !genres.isEmpty { metadata.append(genres.joined(separator: " / ")) }
        facts = metadata.isEmpty ? nil : metadata.joined(separator: " · ")
    }
}

enum TimePickPlanner {
    static func recommendations(_ videos: [Video], minutes: Int, preference: ViewingPreference, positions: [String: Double], limit: Int = 3, excluding: Set<String> = []) -> [TimePick] {
        guard (1...240).contains(minutes), limit > 0 else { return [] }
        var seen = Set<String>()
        let available = videos.filter { seen.insert($0.id).inserted && !ContinuousWatching.completed($0, positions: positions) }
        let firstEpisodes = Dictionary(grouping: available.filter { ChannelPlanner.seriesKey($0) != nil }) { ChannelPlanner.seriesKey($0)! }
            .compactMapValues { ContinuousWatching.ordered($0).first?.id }
        let picks = available.compactMap { video -> TimePick? in
            guard !excluding.contains(video.id), video.duration.isFinite, video.duration > 0,
                  preference.accepts(video) else { return nil }
            if let key = ChannelPlanner.seriesKey(video), firstEpisodes[key] != video.id { return nil }
            let raw = positions[video.id] ?? video.resume
            let start = raw.isFinite && WatchProgress.canResume(position: raw, duration: video.duration) ? raw : 0
            let remaining = video.duration - start
            guard remaining > 0, remaining <= Double(minutes * 60) else { return nil }
            var reasons = [start > 1 ? "继续上次观看" : "尚未看完", "可在 \(minutes) 分钟内看完"]
            if video.mediaType == "Episode" { reasons.append("按季集顺序的下一集") }
            return TimePick(video: video, resumeAt: start, remaining: remaining, reasons: reasons)
        }
        return Array(picks.sorted {
            if ($0.resumeAt > 1) != ($1.resumeAt > 1) { return $0.resumeAt > 1 }
            if $0.remaining != $1.remaining { return $0.remaining > $1.remaining }
            return $0.id < $1.id
        }.prefix(limit))
    }
}
