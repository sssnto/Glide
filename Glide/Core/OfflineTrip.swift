import Foundation

struct OfflineTrip: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var videoIDs: [String]
    var targetSeconds: Double
    var maximumBytes: Int64
    var createdAt = Date()
    var videos: [Video] = []
    var expectedSizes: [String: Int64] = [:]
    var accountBindings: [String: String] = [:]
    var sourceVersions: [String: String] = [:]
    func validated() throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty, value.name.count <= 60, !videoIDs.isEmpty, videoIDs.count <= 100,
              Set(videoIDs).count == videoIDs.count, targetSeconds.isFinite, targetSeconds > 0,
              maximumBytes > 0 else { throw MediaError.message("请输入行程名称，并选择 1–100 个视频及有效的时间、容量预算。") }
        return value
    }
}

extension OfflineTrip {
    private enum CodingKeys: String, CodingKey { case id, name, videoIDs, targetSeconds, maximumBytes, createdAt, videos, expectedSizes, accountBindings, sourceVersions }
    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        id = try value.decode(UUID.self, forKey: .id)
        name = try value.decode(String.self, forKey: .name)
        videoIDs = try value.decode([String].self, forKey: .videoIDs)
        targetSeconds = try value.decode(Double.self, forKey: .targetSeconds)
        maximumBytes = try value.decode(Int64.self, forKey: .maximumBytes)
        createdAt = try value.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        videos = try value.decodeIfPresent([Video].self, forKey: .videos) ?? []
        expectedSizes = try value.decodeIfPresent([String: Int64].self, forKey: .expectedSizes) ?? [:]
        accountBindings = try value.decodeIfPresent([String: String].self, forKey: .accountBindings) ?? [:]
        sourceVersions = try value.decodeIfPresent([String: String].self, forKey: .sourceVersions) ?? [:]
    }
}

struct OfflineTripCandidate: Identifiable, Equatable {
    var video: Video
    var bytes: Int64
    var alreadySaved = false
    var fileBytes: Int64? = nil
    var sourceVersionID: String? = nil
    var id: String { video.id }
    var remaining: Double {
        guard video.duration.isFinite, video.duration > 0 else { return 0 }
        let position = video.resume.isFinite ? max(0, min(video.resume, video.duration)) : 0
        return max(0, video.duration - position)
    }
}

enum OfflineTripPlanner {
    struct Plan {
        var items: [OfflineTripCandidate]
        var seconds: Double { items.reduce(0) { $0 + $1.remaining } }
        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }
    /// Never estimate missing sizes or silently exceed either budget. Series are
    /// supplied in episode order; a later episode cannot leapfrog a rejected one.
    static func plan(_ candidates: [OfflineTripCandidate], seconds: Double, bytes: Int64, limit: Int = 100) -> Plan {
        guard seconds.isFinite, seconds > 0, bytes > 0, limit > 0 else { return Plan(items: []) }
        var seen = Set<String>(), blockedSeries = Set<String>(), result = [OfflineTripCandidate]()
        var duration = 0.0, allocated: Int64 = 0
        for candidate in candidates where seen.insert(candidate.id).inserted {
            let series = ChannelPlanner.seriesKey(candidate.video)
            if let series, blockedSeries.contains(series) { continue }
            guard candidate.video.isWatched != true, candidate.remaining > 0, candidate.bytes > 0,
                  candidate.video.duration > 0, candidate.video.duration.isFinite else {
                if candidate.video.isWatched != true, let series { blockedSeries.insert(series) }
                continue
            }
            guard result.count < min(limit, 100), candidate.bytes <= bytes - allocated,
                  candidate.remaining <= seconds - duration else {
                if let series { blockedSeries.insert(series) }
                continue
            }
            result.append(candidate); duration += candidate.remaining; allocated += candidate.bytes
        }
        return Plan(items: result)
    }
    static func episodes(_ candidates: [OfflineTripCandidate], count: Int, bytes: Int64) -> Plan {
        guard Set(candidates.compactMap { ChannelPlanner.seriesKey($0.video) }).count == 1 else { return Plan(items: []) }
        guard let first = candidates.first(where: { $0.video.mediaType == "Episode" && $0.video.isWatched != true }),
              let series = ChannelPlanner.seriesKey(first.video) else { return Plan(items: []) }
        let ordered = candidates.filter { ChannelPlanner.seriesKey($0.video) == series }.sorted {
            let a = ($0.video.seasonNumber ?? 0, $0.video.episodeNumber ?? Int.max)
            let b = ($1.video.seasonNumber ?? 0, $1.video.episodeNumber ?? Int.max)
            return a != b ? a < b : $0.id < $1.id
        }
        return plan(ordered, seconds: 31_536_000, bytes: bytes, limit: max(0, count))
    }
}

struct OfflinePlaybackCheck: Codable, Equatable {
    var size: Int64
    var modified: Date
    var engine: PlaybackEngineID
    var checkedAt: Date
    var resourcesFingerprint: String? = nil
    func matches(size: Int64, modified: Date) -> Bool { self.size == size && self.modified == modified }
}
