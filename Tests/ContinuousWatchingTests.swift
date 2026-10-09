import Foundation
import Testing
@testable import GlideCore

private func episode(_ id: String, source: UUID, season: Int, number: Int, resume: Double = 0, watched: Bool = false) -> Video {
    Video(id: source.uuidString + ":" + id, title: id, subtitle: "", sourceID: source, remoteID: id, duration: 1000, resume: resume,
          mediaType: "Episode", seriesID: "show", seriesTitle: "节目", seasonNumber: season, episodeNumber: number, isWatched: watched)
}
@Test func legacyBookmarksDecodeAndNewRulesRoundTrip() throws {
    let id = UUID()
    let legacy = Data("{\"sourceID\":\"\(id)\",\"name\":\"旧目录\",\"jellyPath\":[],\"davPath\":[]}".utf8)
    var bookmark = try JSONDecoder().decode(DirectoryBookmark.self, from: legacy)
    #expect(bookmark.options == nil && bookmark.mode == nil && bookmark.accountID == nil)
    let identity = bookmark.id
    bookmark.options = BrowseOptions(includesDescendants: false, sort: .addedNewest); bookmark.mode = .random; bookmark.accountID = "account"
    #expect(bookmark.id == identity)
    #expect(try JSONDecoder().decode(DirectoryBookmark.self, from: JSONEncoder().encode(bookmark)) == bookmark)
}
@Test func seriesContinueGroupsHistoryWithoutMixingSourcesOrFavorites() {
    let source = UUID(), other = UUID()
    let a = episode("a", source: source, season: 1, number: 1, resume: 300)
    let b = episode("b", source: source, season: 1, number: 2, resume: 200)
    let c = episode("c", source: other, season: 1, number: 1, resume: 100)
    let records = [PersonalVideo(video: a, lastPlayedAt: Date(timeIntervalSince1970: 1)),
                   PersonalVideo(video: b, lastPlayedAt: Date(timeIntervalSince1970: 3)),
                   PersonalVideo(video: c, lastPlayedAt: Date(timeIntervalSince1970: 2)), PersonalVideo(video: a)]
    let items = ContinuousWatching.items(records: records, positions: [:], episodes: [:])
    #expect(items.count == 2)
    #expect(items.first?.video.id == b.id)
    #expect(Set(items.first!.historyIDs) == Set([a.id, b.id]))
    #expect(items.last?.video.id == c.id)
}
@Test func completedEpisodeAdvancesAcrossSeasonsAndSkipsSpecialsAndWatchedEpisodes() {
    let source = UUID()
    let done = episode("end", source: source, season: 1, number: 10, resume: 990)
    let special = episode("special", source: source, season: 0, number: 1)
    let seen = episode("seen", source: source, season: 2, number: 1, watched: true)
    let next = episode("next", source: source, season: 2, number: 2)
    let records = [PersonalVideo(video: done, lastPlayedAt: Date())]
    let key = ContinuousWatching.seriesKey(done)!
    let result = ContinuousWatching.items(records: records, positions: [:], episodes: [key: [next, special, done, seen]])
    #expect(result.first?.video.id == next.id)
    #expect(result.first?.finished == false)
}
@Test func localResetOverridesServerWatchedAndUnknownCatalogRetainsEntry() {
    let source = UUID()
    let done = episode("end", source: source, season: 1, number: 1, resume: 990, watched: true)
    #expect(!ContinuousWatching.completed(done, positions: [done.id: 0]))
    #expect(!ContinuousWatching.completed(done, positions: [done.id: 200]))
    let records = [PersonalVideo(video: done, lastPlayedAt: Date())]
    #expect(ContinuousWatching.items(records: records, positions: [:], episodes: [:]).first?.finished == false)
    let key = ContinuousWatching.seriesKey(done)!
    #expect(ContinuousWatching.items(records: records, positions: [:], episodes: [key: [done]]).first?.finished == true)
}
@Test func gapsRemainActionableInsteadOfClaimingSeriesComplete() {
    let source = UUID()
    let gap = episode("gap", source: source, season: 1, number: 1)
    let done = episode("end", source: source, season: 1, number: 2, resume: 990)
    let records = [PersonalVideo(video: done, lastPlayedAt: Date())]
    let result = ContinuousWatching.items(records: records, positions: [:], episodes: [ContinuousWatching.seriesKey(done)!: [done, gap]])
    #expect(result.first?.video.id == gap.id)
    #expect(result.first?.finished == false)
}
@Test func completedMoviesDisappearButPartiallyWatchedMoviesRemain() {
    let film = Video(id: "film", title: "电影", subtitle: "", duration: 1000, resume: 400, mediaType: "Movie")
    let done = Video(id: "done", title: "看完电影", subtitle: "", duration: 1000, resume: 999, mediaType: "Movie")
    let items = ContinuousWatching.items(records: [film, done].map { PersonalVideo(video: $0, lastPlayedAt: Date()) }, positions: [:], episodes: [:])
    #expect(items.map(\.id) == ["film"])
}
@Test func queueWaitsForActiveTransferAndAdvancesInInsertionOrder() {
    #expect(OfflineQueuePolicy.next(queued: ["a", "b"], active: ["running"]) == nil)
    #expect(OfflineQueuePolicy.next(queued: ["a", "b"], active: []) == "a")
    #expect(OfflineQueuePolicy.next(queued: ["b"], active: []) == "b")
    #expect(OfflineQueuePolicy.next(queued: [], active: []) == nil)
}
