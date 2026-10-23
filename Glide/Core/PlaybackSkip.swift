import Foundation

enum SkipSegmentKind: String, Codable, CaseIterable, Sendable {
    case intro = "Intro", outro = "Outro", recap = "Recap", preview = "Preview", commercial = "Commercial"
    var title: String {
        switch self { case .intro: "跳过片头"; case .outro: "跳过片尾"; case .recap: "跳过前情"; case .preview: "跳过预告"; case .commercial: "跳过广告" }
    }
}
struct SkipSegment: Identifiable, Equatable, Sendable {
    var id: String
    var kind: SkipSegmentKind
    var start: Double
    var end: Double
    var manual = false
    func valid(duration: Double) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start && duration.isFinite && duration > 0 && end <= duration + 0.05 && start < duration - 0.2
    }
    func contains(_ time: Double) -> Bool { time.isFinite && time >= start && time < end - 0.15 }
    func target(duration: Double) -> Double { min(end, max(0, duration - 0.1)) }
}
struct PlaybackSkipRule: Codable, Equatable, Sendable {
    var enabled = true
    var automatic = false
    var serverMarkers = true
    var intro = 0.0
    var outro = 0.0
    func validate(duration: Double? = nil) throws {
        guard intro.isFinite, outro.isFinite, (0...1800).contains(intro), (0...1800).contains(outro),
              duration.map({ $0 > 0 && intro + outro < $0 - 0.2 }) ?? true else {
            throw MediaError.message("片头、片尾各为 0–1800 秒，合计需小于视频时长。")
        }
    }
    func segments(duration: Double, server: [SkipSegment]) -> [SkipSegment] {
        guard enabled, (try? validate(duration: duration)) != nil else { return [] }
        var values = serverMarkers ? server.filter { (intro == 0 || $0.kind != .intro) && (outro == 0 || $0.kind != .outro) } : []
        if intro > 0 { values.append(SkipSegment(id: "manual-intro", kind: .intro, start: 0, end: intro, manual: true)) }
        if outro > 0 { values.append(SkipSegment(id: "manual-outro", kind: .outro, start: duration - outro, end: duration, manual: true)) }
        return values.filter { $0.valid(duration: duration) }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
}
struct PlaybackSkipMemory: Codable, Equatable, Sendable {
    var sourceID: UUID?
    var videoID: String
    var rule: PlaybackSkipRule
}
struct JellyfinSegmentResponse: Decodable {
    struct Item: Decodable {
        var Id: String?
        var ItemId: String?
        var type: String?
        var StartTicks: Int64?
        var EndTicks: Int64?
        enum CodingKeys: String, CodingKey { case Id, ItemId, type = "Type", StartTicks, EndTicks }
    }
    var Items: [Item]
    func segments(itemID: String) -> [SkipSegment] {
        func normalized(_ id: String) -> String { id.replacingOccurrences(of: "-", with: "").lowercased() }
        var seen = Set<String>()
        return Items.compactMap { item in
            guard let kind = item.type.flatMap(SkipSegmentKind.init(rawValue:)),
                  let start = item.StartTicks, let end = item.EndTicks, start >= 0, end > start,
                  item.ItemId.map({ normalized($0) == normalized(itemID) }) ?? false else { return nil }
            let id = item.Id ?? "\(kind.rawValue):\(start):\(end)"
            guard seen.insert(id).inserted else { return nil }
            return SkipSegment(id: "server:" + id, kind: kind, start: Double(start) / 10_000_000, end: Double(end) / 10_000_000)
        }
    }
}
