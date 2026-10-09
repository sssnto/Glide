import Foundation

struct ContinueWatchingItem: Identifiable {
    var id: String
    var video: Video
    var historyIDs: [String]
    var lastPlayedAt: Date
    var finished: Bool = false
    var title: String { video.seriesTitle ?? video.title }
    var episodeLabel: String {
        [video.seasonNumber.map { "第 \($0) 季" }, video.episodeNumber.map { "第 \($0) 集" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

enum ContinuousWatching {
    static func seriesKey(_ video: Video) -> String? {
        guard video.mediaType == "Episode", let source = video.sourceID, let series = video.seriesID else { return nil }
        return source.uuidString + ":series:" + series
    }
    static func ordered(_ videos: [Video]) -> [Video] {
        videos.sorted {
            let a = ($0.seasonNumber ?? Int.max, $0.episodeNumber ?? Int.max)
            let b = ($1.seasonNumber ?? Int.max, $1.episodeNumber ?? Int.max)
            if a != b { return a < b }
            return $0.id < $1.id
        }
    }
    static func completed(_ video: Video, positions: [String: Double]) -> Bool {
        // Explicit local progress overrides stale server watched metadata.
        let position = positions[video.id] ?? video.resume
        if positions[video.id] != nil && position <= 1 { return false }
        if position > 1 { return video.duration > 0 && !WatchProgress.canResume(position: position, duration: video.duration) }
        return video.isWatched == true
    }
    static func items(records: [PersonalVideo], positions: [String: Double], episodes: [String: [Video]]) -> [ContinueWatchingItem] {
        let groups = Dictionary(grouping: records.filter { $0.lastPlayedAt != nil }) { seriesKey($0.video) ?? $0.id }
        return groups.compactMap { key, group in
            guard let latest = group.max(by: { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }),
                  let date = latest.lastPlayedAt else { return nil }
            var video = latest.video
            let ids = group.map(\.id)
            if seriesKey(video) == nil {
                guard WatchProgress.canResume(position: positions[video.id] ?? video.resume, duration: video.duration) else { return nil }
                return ContinueWatchingItem(id: key, video: video, historyIDs: ids, lastPlayedAt: date)
            }
            if !completed(video, positions: positions) {
                return ContinueWatchingItem(id: key, video: video, historyIDs: ids, lastPlayedAt: date)
            }
            let candidates = ordered(episodes[key] ?? group.map(\.video)).filter {
                video.seasonNumber == 0 ? $0.seasonNumber == 0 : $0.seasonNumber != 0
            }
            if let index = candidates.firstIndex(where: { $0.id == video.id }),
               let next = candidates.dropFirst(index + 1).first(where: { !completed($0, positions: positions) }) {
                video = next
                return ContinueWatchingItem(id: key, video: video, historyIDs: ids, lastPlayedAt: date)
            }
            // No catalog yet: retain an actionable series entry and let the view refresh it.
            if episodes[key] != nil, let remaining = candidates.first(where: { !completed($0, positions: positions) }) {
                return ContinueWatchingItem(id: key, video: remaining, historyIDs: ids, lastPlayedAt: date)
            }
            let knownComplete = episodes[key] != nil && !candidates.isEmpty
            if knownComplete { video = candidates.first ?? video }
            return ContinueWatchingItem(id: key, video: video, historyIDs: ids, lastPlayedAt: date, finished: knownComplete)
        }.sorted { $0.lastPlayedAt > $1.lastPlayedAt }
    }
}

enum OfflineQueuePolicy {
    static func next(queued: [String], active: Set<String>) -> String? {
        active.isEmpty ? queued.first : nil
    }
}
