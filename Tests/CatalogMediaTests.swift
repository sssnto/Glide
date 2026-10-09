import Foundation
import Testing
@testable import GlideCore

@Test func libraryTypesAndLegacyPaths() throws {
    #expect(LibraryExperience(collectionType: "movies") == .movies)
    #expect(LibraryExperience(collectionType: "tvshows") == .shows)
    #expect(LibraryExperience(collectionType: "homevideos") == .home)
    #expect(LibraryExperience(collectionType: nil) == .home)
    let old = try JSONDecoder().decode(MediaFolder.self, from: Data(#"{"id":"old","name":"Old","isLibrary":true}"#.utf8))
    #expect(old.collectionType == nil)
}
@Test func episodeOrderUsesNumbersAndKeepsSpecials() {
    let items = [CatalogItem(Id: "10", Name: "A", Type: "Episode", IndexNumber: 10, ParentIndexNumber: 1),
                 CatalogItem(Id: "2", Name: "Z", Type: "Episode", IndexNumber: 2, ParentIndexNumber: 1),
                 CatalogItem(Id: "special", Name: "Special", Type: "Episode", IndexNumber: 1, ParentIndexNumber: 0),
                 CatalogItem(Id: "s2", Name: "Next", Type: "Episode", IndexNumber: 1, ParentIndexNumber: 2)]
    #expect(CatalogItem.episodeOrder(items).map(\.id) == ["special", "2", "10", "s2"])
}

@Test func episodePlaybackMetadataSurvivesPersistenceAndOldRecordsStillDecode() throws {
    let server = MediaServer(name: "Fixture", kind: .jellyfin, address: URL(string: "https://example.com")!, username: "demo")
    let item = CatalogItem(Id: "episode", Name: "Premiere", Type: "Episode", IndexNumber: 1,
                           ParentIndexNumber: 2, SeriesName: "A show", SeriesId: "series")
    let video = try JSONDecoder().decode(Video.self, from: JSONEncoder().encode(item.video(server: server)))
    #expect(video.mediaType == "Episode")
    #expect(video.seriesID == "series" && video.seriesTitle == "A show")
    #expect(video.seasonNumber == 2 && video.episodeNumber == 1)
    let old = try JSONDecoder().decode(Video.self, from: Data(#"{"id":"old","title":"Episode","subtitle":"","duration":12,"resume":0,"mediaType":"Episode"}"#.utf8))
    #expect(old.seasonNumber == nil && old.episodeNumber == nil && old.seriesID == nil)
}
@Test func absentMetadataAndIndexedTracksDecode() throws {
    let data = Data(#"{"Id":"film","Name":"Untitled","Type":"Movie","MediaSources":[{"Id":"source","MediaStreams":[{"Index":3,"Type":"Audio","Language":"eng","Codec":"aac"},{"Index":8,"Type":"Subtitle","DisplayTitle":"简体中文"}]}]}"#.utf8)
    let item = try JSONDecoder().decode(CatalogItem.self, from: data)
    #expect(item.Overview == nil)
    #expect(item.MediaSources?.first?.MediaStreams?.last?.Index == 8)
    #expect(item.MediaSources?.first?.MediaStreams?.first?.label == "eng · aac")
}

@Test func sourcePathsDecodePerVersionAndDisplayWithoutURLCredentials() throws {
    let item = try JSONDecoder().decode(CatalogItem.self, from: Data(#"{"Id":"film","Name":"Film","MediaSources":[{"Id":"original","Path":"/media/家庭视频/春节.mp4"},{"Id":"edition","Path":"D:\\Movies\\Film.mkv"}]}"#.utf8))
    #expect(item.MediaSources?.first?.Path == "/media/家庭视频/春节.mp4")
    #expect(item.MediaSources?.last?.Path == #"D:\Movies\Film.mkv"#)
    #expect(MediaFilePath.display(" /media/家庭视频/春节.mp4 ") == "/media/家庭视频/春节.mp4")
    #expect(MediaFilePath.display("https://user:password@nas.test:8443/videos/%E5%AE%B6%E5%BA%AD.mp4?api_key=secret#token") == "https://nas.test:8443/videos/家庭.mp4")
    #expect(MediaFilePath.display("file:///var/mobile/OfflineMedia/Film%20A.mp4") == "/var/mobile/OfflineMedia/Film A.mp4")
    #expect(MediaFilePath.display(nil) == nil)
    #expect(MediaFilePath.display(" \n ") == nil)
    #expect(MediaFilePath.display("https:///missing-host") == nil)
    #expect(MediaFilePath.display(#"D:\Movies\Film.mkv"#) == #"D:\Movies\Film.mkv"#)
}
@Test func selectedTracksAreSentWithoutConfusingOffWithDefault() {
    var body = JellyfinPlaybackPolicy.body(userID: "user", quality: .automatic)
    TrackSelection(mediaSourceID: "edition", audioIndex: 3, subtitleIndex: -1).apply(to: &body)
    #expect(body["MediaSourceId"] as? String == "edition")
    #expect(body["AudioStreamIndex"] as? Int == 3)
    #expect(body["SubtitleStreamIndex"] as? Int == -1)
    #expect(body["EnableDirectPlay"] as? Bool == false)
    #expect(body["EnableTranscoding"] as? Bool == true)
    var defaults = JellyfinPlaybackPolicy.body(userID: "user", quality: .original)
    TrackSelection().apply(to: &defaults)
    #expect(defaults["SubtitleStreamIndex"] == nil)
    #expect(defaults["EnableDirectPlay"] as? Bool == true)
    #expect(TrackSelection(subtitleIndex: -1).requiresServerSelection == false)
    var withoutSubtitles = JellyfinPlaybackPolicy.body(userID: "user", quality: .automatic)
    TrackSelection(subtitleIndex: -1).apply(to: &withoutSubtitles)
    #expect(withoutSubtitles["EnableDirectPlay"] as? Bool == true)
}


@Test func catalogFacetsPreserveKindAndEncodeFilters() throws {
    let item = try JSONDecoder().decode(CatalogItem.self, from: Data(#"{"Id":"film","Name":"Movie","Tags":["精彩 & 推荐","精彩 & 推荐"," "],"Genres":["Adventure"]}"#.utf8))
    let facets = CatalogFacet.facets(item)
    #expect(facets.count == 2)
    let tag = facets.first { $0.kind == .tag }!
    let query = tag.query(user: "u", start: 60)
    #expect(query["Tags"] == "精彩 & 推荐")
    #expect(query["UserId"] == "u")
    #expect(query["StartIndex"] == "60")
    #expect(query["ParentId"] == nil)
    #expect(query["IncludeItemTypes"]?.contains("Episode") == false)
    #expect(facets[0].query(user: "u", start: 0)["Genres"] == "Adventure")
}
