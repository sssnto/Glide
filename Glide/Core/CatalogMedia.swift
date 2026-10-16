import Foundation

enum LibraryExperience {
    case movies, shows, home
    init(collectionType: String?) {
        switch collectionType?.lowercased() {
        case "movies": self = .movies
        case "tvshows": self = .shows
        default: self = .home
        }
    }
}

/// Jellyfin metadata is optional: untagged titles remain browsable and playable.
struct CatalogItem: Codable, Identifiable, Equatable {
    var Id: String
    var Name: String
    var `Type`: String?
    var Overview: String?
    var ProductionYear: Int?
    var OfficialRating: String?
    var CommunityRating: Double?
    var Genres: [String]?
    var Tags: [String]?
    var RunTimeTicks: Int64?
    var IndexNumber: Int?
    var ParentIndexNumber: Int?
    var SeriesName: String?
    var SeriesId: String?
    var ImageTags: [String: String]?
    var SeriesPrimaryImageTag: String?
    var People: [Person]?
    var MediaSources: [Source]?
    var UserData: Progress?
    var id: String { Id }
    struct Person: Codable, Equatable {
        var Name: String
        var `Type`: String?
        var Role: String?
        var Id: String?
        var PrimaryImageTag: String?
        var personID: String? { Id.flatMap { $0.isEmpty ? nil : $0 } }
        var credit: String {
            if let Role, !Role.isEmpty { return Role }
            switch Type {
            case "Director": return "导演"
            case "Actor": return "演员"
            case "Writer": return "编剧"
            case "Producer": return "制片人"
            case "Composer": return "作曲"
            default: return Type ?? "演职人员"
            }
        }
    }
    struct Progress: Codable, Equatable { var PlaybackPositionTicks: Int64?; var LastPlayedDate: String?; var Played: Bool? }
    struct Source: Codable, Identifiable, Equatable {
        var Id: String; var Name: String?; var Container: String?; var Size: Int64?; var MediaStreams: [Stream]?
        var Path: String?
        var id: String { Id }
    }
    struct Stream: Codable, Identifiable, Equatable {
        var Index: Int; var `Type`: String; var DisplayTitle: String?; var Language: String?; var Codec: String?; var IsDefault: Bool?; var IsForced: Bool?; var Width: Int?; var Height: Int?; var BitDepth: Int?; var Profile: String?; var Level: Double?; var CodecTag: String?
        var VideoRangeType: String?; var DvProfile: Int?
        var ColorTransfer: String?; var ColorPrimaries: String?; var ColorSpace: String?
        var BitRate: Int?; var RealFrameRate: Double?; var AverageFrameRate: Double?
        var id: Int { Index }
        var label: String { DisplayTitle ?? [Language, Codec].compactMap { $0 }.joined(separator: " · ").nonempty ?? "轨道 \(Index)" }
    }
    var episodeLabel: String {
        [ParentIndexNumber.map { "第 \($0) 季" }, IndexNumber.map { "第 \($0) 集" }].compactMap { $0 }.joined(separator: " · ")
    }
    var facts: String {
        [ProductionYear.map(String.init), OfficialRating, CommunityRating.map { "★ " + String(format: "%.1f", $0) },
         RunTimeTicks.flatMap { $0 <= 0 ? nil : $0 < 600_000_000 ? "\($0 / 10_000_000) 秒" : "\($0 / 600_000_000) 分钟" }].compactMap { $0 }.joined(separator: " · ")
    }
    func video(server: MediaServer) -> Video {
        Video(id: server.id.uuidString + Id, title: Name,
              subtitle: [SeriesName, episodeLabel.nonempty, facts.nonempty].compactMap { $0 }.joined(separator: " · "),
              sourceID: server.id, remoteID: Id,
              artwork: ServerURL.endpoint(server.address, "Items/\(Id)/Images/Primary", query: ["maxWidth": "700"]),
              duration: Double(RunTimeTicks ?? 0) / 10_000_000,
              resume: Double(UserData?.PlaybackPositionTicks ?? 0) / 10_000_000,
              mediaType: Type, seriesID: SeriesId, seriesTitle: SeriesName,
              seasonNumber: ParentIndexNumber, episodeNumber: IndexNumber, isWatched: UserData?.Played)
    }
    static func episodeOrder(_ items: [CatalogItem]) -> [CatalogItem] {
        items.sorted {
            let a = ($0.ParentIndexNumber ?? 0, $0.IndexNumber ?? Int.max)
            let b = ($1.ParentIndexNumber ?? 0, $1.IndexNumber ?? Int.max)
            if a != b { return a < b }
            let order = $0.Name.localizedStandardCompare($1.Name)
            return order == .orderedSame ? $0.Id < $1.Id : order == .orderedAscending
        }
    }
}
private extension String { var nonempty: String? { isEmpty ? nil : self } }

struct TrackSelection: Equatable {
    var mediaSourceID: String?
    var audioIndex: Int?
    /// nil: server default; -1: explicitly off.
    var subtitleIndex: Int?
    var requiresServerSelection: Bool { audioIndex != nil || (subtitleIndex != nil && subtitleIndex != -1) }
    func apply(to body: inout [String: Any]) {
        body["MediaSourceId"] = mediaSourceID
        body["AudioStreamIndex"] = audioIndex
        body["SubtitleStreamIndex"] = subtitleIndex
        if requiresServerSelection {
            body["EnableDirectPlay"] = false
            body["EnableDirectStream"] = false
        }
    }
}


struct PersonMediaPage: Codable {
    var Items: [CatalogItem]
    var TotalRecordCount: Int
}
enum PersonMediaQuery {
    static func items(userID: String, personID: String, start: Int) throws -> [String: String] {
        guard !personID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MediaError.message("服务器未提供人员标识，暂时无法查询相关媒体。") }
        return ["UserId": userID, "PersonIds": personID, "Recursive": "true",
                "IncludeItemTypes": "Movie,Series,Video,MusicVideo", "Fields": "Overview,Genres",
                "EnableUserData": "true", "SortBy": "SortName", "SortOrder": "Ascending",
                "StartIndex": String(max(0, start)), "Limit": "60"]
    }
}


struct CatalogFacet: Hashable, Identifiable {
    enum Kind: String { case tag = "Tags", genre = "Genres" }
    var kind: Kind
    var name: String
    var id: String { kind.rawValue + ":" + name }
    static func facets(_ item: CatalogItem) -> [CatalogFacet] {
        var seen = Set<String>()
        return [(Kind.genre, item.Genres ?? []), (Kind.tag, item.Tags ?? [])].flatMap { kind, names in
            names.compactMap { value in
                let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                let facet = CatalogFacet(kind: kind, name: name)
                return !name.isEmpty && seen.insert(facet.id).inserted ? facet : nil
            }
        }
    }
    func query(user: String, start: Int) -> [String: String] {
        [kind.rawValue: name, "UserId": user, "Recursive": "true", "IncludeItemTypes": "Movie,Series,Video,MusicVideo",
         "Fields": "Overview,Genres,Tags", "SortBy": "SortName", "SortOrder": "Ascending", "StartIndex": String(start), "Limit": "60"]
    }
}
