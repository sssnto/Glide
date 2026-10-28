import Foundation

/// Stable, account-bound location; resolved URLs and authentication are never persisted.
struct MomentReference: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case demo, local, offline, catalog, smb, webDAV }
    var kind: Kind
    var videoID: String
    var sourceID: UUID?
    var accountID: String
    var mediaSourceID: String?
    var revision: String
    var sourceBinding: String? = nil
    func matches(_ server: MediaServer) -> Bool {
        sourceID == server.id && accountID == (server.userID ?? server.username)
    }
}

struct MediaMoment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var video: Video
    var reference: MomentReference
    var position: Double
    var duration: Double
    var name: String
    var createdAt = Date()
    func validated() throws -> MediaMoment {
        guard video.id == reference.videoID, !reference.revision.isEmpty,
              position.isFinite, duration.isFinite, duration > 0,
              position >= 0, position < duration else { throw MediaError.message("当前片段没有有效的时间或文件信息。") }
        var result = self
        result.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if result.name.isEmpty { result.name = "时刻 " + position.mediaTime }
        result.video = PersonalVideo(video: video).video
        result.video.url = nil; result.video.artwork = nil
        return result
    }
}

struct MapSegment: Identifiable, Equatable, Sendable {
    var start: Double
    var end: Double
    var id: String { "\(start):\(end)" }
}

enum ContentMapPlan {
    /// Small pages, independent of video length. Refinement never indexes the whole asset.
    static func segments(duration: Double, range: MapSegment? = nil, count: Int = 24) -> [MapSegment] {
        guard duration.isFinite, duration > 0, count > 0 else { return [] }
        if let range, !range.start.isFinite || !range.end.isFinite { return [] }
        let start = max(0, range?.start ?? 0), end = min(duration, range?.end ?? duration)
        guard start.isFinite, end.isFinite, end > start else { return [] }
        let number = min(24, count, max(1, Int(min(24, ceil((end - start) / (range == nil ? 1 : 0.125))))))
        let step = (end - start) / Double(number)
        return (0..<number).map { MapSegment(start: start + Double($0) * step, end: min(end, start + Double($0 + 1) * step)) }
    }
}

struct NavigationChapter: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var time: Double
    static func normalized(_ values: [NavigationChapter], duration: Double) -> [NavigationChapter] {
        guard duration.isFinite, duration > 0 else { return [] }
        var seen = Set<Double>()
        return values.filter { $0.time.isFinite && $0.time >= 0 && $0.time < duration }
            .sorted { $0.time < $1.time }.filter { seen.insert($0.time).inserted }.prefix(500).map { $0 }
    }
}

struct TrickplayInfo: Codable, Equatable, Sendable {
    var Width: Int
    var Height: Int
    var TileWidth: Int
    var TileHeight: Int
    var ThumbnailCount: Int
    var Interval: Int
    var valid: Bool {
        Width > 0 && Width <= 1024 && Height > 0 && Height <= 1024 &&
        TileWidth > 0 && TileWidth <= 64 && TileHeight > 0 && TileHeight <= 64 &&
        Width * TileWidth <= 8192 && Height * TileHeight <= 8192 &&
        Width * TileWidth * Height * TileHeight <= 16_777_216 &&
        ThumbnailCount > 0 && ThumbnailCount <= 1_000_000 && Interval > 0
    }
    struct Tile: Equatable { var sheet: Int; var x: Int; var y: Int; var time: Double }
    func tile(at time: Double) -> Tile? {
        guard valid, time.isFinite, time >= 0 else { return nil }
        let index = Int(min(Double(ThumbnailCount - 1), floor(time * 1000 / Double(Interval))))
        let capacity = TileWidth * TileHeight, cell = index % capacity
        return Tile(sheet: index / capacity, x: cell % TileWidth * Width, y: cell / TileWidth * Height, time: Double(index) * Double(Interval) / 1000)
    }
}

struct VideoNavigationMetadata: Decodable {
    var MediaSources: [CatalogItem.Source]?
    var Chapters: [Chapter]?
    var Trickplay: [String: [String: TrickplayInfo]?]?
    struct Chapter: Decodable { var Name: String?; var StartPositionTicks: Int64? }
    func source(_ id: String?) -> CatalogItem.Source? {
        guard let id else { return nil }
        return MediaSources?.first { $0.Id.caseInsensitiveCompare(id) == .orderedSame }
    }
    func trickplay(sourceID: String) -> TrickplayInfo? {
        let options = Trickplay?.first { $0.key.caseInsensitiveCompare(sourceID) == .orderedSame }?.value
        return options?.values.filter(\.valid).sorted { abs($0.Width - 320) < abs($1.Width - 320) }.first
    }
    func chapters(sourceID: String, duration: Double) -> [NavigationChapter] {
        // BaseItem chapters belong to its default version; never apply them to another cut.
        guard MediaSources?.first?.Id.caseInsensitiveCompare(sourceID) == .orderedSame else { return [] }
        return NavigationChapter.normalized((Chapters ?? []).enumerated().compactMap { index, chapter in
            guard let ticks = chapter.StartPositionTicks else { return nil }
            return NavigationChapter(id: "chapter-\(index)", name: chapter.Name ?? "章节 \(index + 1)", time: Double(ticks) / 10_000_000)
        }, duration: duration)
    }
}
