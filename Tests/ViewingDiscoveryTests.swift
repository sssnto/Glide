import Foundation
import Testing
@testable import GlideCore

struct ViewingDiscoveryTests {
    private let source = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private func video(_ id: String, duration: Double = 1200, type: String = "Movie", series: String? = nil, season: Int? = nil, episode: Int? = nil, resume: Double = 0) -> Video {
        Video(id: id, title: id, subtitle: "", sourceID: source, duration: duration, resume: resume, mediaType: type, seriesID: series, seasonNumber: season, episodeNumber: episode)
    }
    private func episode(_ id: String, _ show: String, _ number: Int, season: Int = 1) -> Video {
        video(id, type: "Episode", series: show, season: season, episode: number)
    }
    @Test func roundRobinKeepsStoryAndNumericSeasonOrderAcrossOverlappingScopes() {
        let scope = DiscoveryScope.demo
        let a1 = episode("a1", "A", 1), a2 = episode("a2", "A", 2), a10 = episode("a10", "A", 10)
        let b1 = episode("b1", "B", 1), b2 = episode("b2", "B", 2)
        let batch = DiscoveryBatch(scope: scope, videos: [a10, b2, a2, b1, a1])
        let channel = PrivateChannel(name: "频道", scopes: [scope])
        let result = ChannelPlanner.queue([batch, DiscoveryBatch(scope: scope, videos: [a1, b1])], channel: channel, positions: [:])
        #expect(result.map(\.id) == ["a1", "b1", "a2", "b2", "a10"])
        #expect(ChannelPlanner.queue([], channel: channel, positions: [:]).isEmpty)
    }
    @Test func sameSeriesIDFromDifferentServersStaysIndependent() {
        var other = episode("other1", "A", 1); other.sourceID = UUID()
        let batch = DiscoveryBatch(scope: .demo, videos: [episode("a2", "A", 2), other, episode("a1", "A", 1)])
        let result = ChannelPlanner.queue([batch], channel: PrivateChannel(name: "频道", scopes: [.demo]), positions: [:])
        #expect(result.map(\.id) == ["a1", "other1", "a2"])
    }
    @Test func recentEpisodeNeverSkipsAnUnfinishedStoryButCompletedEpisodeCanAdvance() {
        let now = Date(), a1 = episode("a1", "A", 1), a2 = episode("a2", "A", 2)
        var channel = PrivateChannel(name: "频道", scopes: [.demo]); channel.lastStarted = ["a1": now]
        let batch = DiscoveryBatch(scope: .demo, videos: [a2, a1])
        #expect(ChannelPlanner.queue([batch], channel: channel, positions: ["a1": 300], now: now).map(\.id) == ["a1", "a2"])
        #expect(ChannelPlanner.queue([batch], channel: channel, positions: ["a1": 1200], now: now).map(\.id) == ["a2"])
        channel.unwatchedOnly = true
        #expect(ChannelPlanner.queue([batch], channel: channel, positions: ["a1": 1200], now: now).map(\.id) == ["a2"])
    }
    @Test func recentMovieWindowAndRuleCanBeChangedWithoutDeletingMedia() {
        let now = Date(), a = video("a"), b = video("b")
        var channel = PrivateChannel(name: "频道", scopes: [.demo]); channel.lastStarted = ["a": now, "b": now.addingTimeInterval(-8 * 86400)]
        let batch = DiscoveryBatch(scope: .demo, videos: [a, b])
        #expect(ChannelPlanner.queue([batch], channel: channel, positions: [:], now: now).map(\.id) == ["b"])
        channel.avoidRecent = false
        #expect(Set(ChannelPlanner.queue([batch], channel: channel, positions: [:], now: now).map(\.id)) == ["a", "b"])
    }
    @Test func timeBudgetUsesRemainingTimeAndContinuesBeforeStartingAnotherMovie() {
        let long = video("long", duration: 5400, resume: 4500), short = video("short", duration: 1200)
        let result = TimePickPlanner.recommendations([short, long], minutes: 20, preference: .movie, positions: [:])
        #expect(result.map(\.id) == ["long", "short"])
        #expect(result.first?.resumeAt == 4500 && result.first?.remaining == 900)
        #expect(result.first?.reasons.contains("继续上次观看") == true)
    }
    @Test func timeBudgetNeverTruncatesLongMoviesOrSubstitutesUnknownDuration() {
        let candidates = [video("long", duration: 1201), video("unknown", duration: 0), video("bad", duration: .nan), video("infinite", duration: .infinity), video("negative", duration: -10)]
        #expect(TimePickPlanner.recommendations(candidates, minutes: 20, preference: .any, positions: [:]).isEmpty)
        for minutes in [0, -1, 241, Int.max] {
            #expect(TimePickPlanner.recommendations([video("a")], minutes: minutes, preference: .any, positions: [:]).isEmpty)
        }
    }
    @Test func shortLaterEpisodeCannotBypassLongNextEpisode() {
        var a1 = episode("a1", "A", 1); a1.duration = 3600
        var a2 = episode("a2", "A", 2); a2.duration = 600
        #expect(TimePickPlanner.recommendations([a2, a1], minutes: 20, preference: .episode, positions: [:]).isEmpty)
        #expect(TimePickPlanner.recommendations([a2, a1], minutes: 20, preference: .episode, positions: ["a1": 3600]).map(\.id) == ["a2"])
    }
    @Test func atMostOneEpisodePerStoryAndExclusionsDoNotRevealLaterEpisodes() {
        let candidates = [episode("a2", "A", 2), episode("a1", "A", 1), episode("b1", "B", 1), video("movie")]
        #expect(TimePickPlanner.recommendations(candidates, minutes: 45, preference: .any, positions: [:]).count == 3)
        #expect(TimePickPlanner.recommendations(candidates, minutes: 45, preference: .episode, positions: [:], excluding: ["a1"]).map(\.id) == ["b1"])
    }
    @Test func watchedMetadataAndExplicitRestartRespectExistingProgressPolicy() {
        var watched = video("watched"); watched.isWatched = true
        #expect(TimePickPlanner.recommendations([watched], minutes: 20, preference: .any, positions: [:]).isEmpty)
        #expect(TimePickPlanner.recommendations([watched], minutes: 20, preference: .any, positions: ["watched": 0]).count == 1)
        #expect(TimePickPlanner.recommendations([video("complete")], minutes: 20, preference: .any, positions: ["complete": 1200]).isEmpty)
    }
    @Test func typePreferencesAndDuplicateInputsAreExplicit() {
        let candidates = [video("movie"), video("clip", duration: 600, type: "Video"), episode("ep", "show", 1)]
        #expect(TimePickPlanner.recommendations(candidates + candidates, minutes: 45, preference: .any, positions: [:]).count == 3)
        #expect(TimePickPlanner.recommendations(candidates, minutes: 45, preference: .shortVideo, positions: [:]).map(\.id) == ["clip"])
        #expect(TimePickPlanner.recommendations(candidates, minutes: 45, preference: .movie, positions: [:]).map(\.id) == ["movie"])
    }
    @Test func scopeValidationRejectsEscapesAndChannelInputIsBounded() throws {
        for path in ["/outside", "../outside", "ok/../outside", "a\\b", "a\u{0000}b"] {
            #expect(throws: (any Error).self) { try DiscoveryScope(kind: .directory, sourceID: source, key: path, name: "目录").validated() }
        }
        #expect(throws: (any Error).self) { try PrivateChannel(name: " ", scopes: [.demo]).validated() }
        #expect(throws: (any Error).self) { try PrivateChannel(name: "a", scopes: []).validated() }
        #expect(throws: (any Error).self) { try PrivateChannel(name: String(repeating: "a", count: 61), scopes: [.demo]).validated() }
        #expect(try PrivateChannel(name: "  频道  ", scopes: [.demo, .demo]).validated().scopes.count == 1)
    }
    @Test func channelMetadataRoundTripsWithoutResolvedPlaybackURLs() throws {
        var channel = PrivateChannel(name: "频道", scopes: [.demo]); channel.unwatchedOnly = true; channel.recordStart("demo-0", at: Date(timeIntervalSince1970: 100))
        let data = try JSONEncoder().encode(channel)
        #expect(try JSONDecoder().decode(PrivateChannel.self, from: data) == channel)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("https:") && !text.contains("Authorization") && !text.contains("token"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoverableStore<[PrivateChannel]>(file: root.appendingPathComponent("channels.json"))
        try store.save([channel]); channel.name = "改名"; try store.save([channel])
        #expect(try store.load()?.value.first?.name == "改名")
        try Data("broken".utf8).write(to: store.file)
        #expect(try store.load()?.recovered == true)
        #expect(try store.load()?.value.first?.name == "频道")
    }
    @Test func savedScopeRequiresTheSameSourceAndAccount() throws {
        var server = MediaServer(id: source, name: "Fixture", kind: .jellyfin, address: URL(string: "https://fixture.invalid")!, username: "demo", userID: "user-a")
        let scope = DiscoveryScope(kind: .catalog, sourceID: source, accountID: "user-a", key: "library", name: "影视库")
        #expect(scope.matches(server))
        server.userID = "user-b"; #expect(!scope.matches(server))
        server.userID = "user-a"; server.id = UUID(); #expect(!scope.matches(server))
        #expect(throws: (any Error).self) { try DiscoveryScope(kind: .video, sourceID: source, key: "", name: "视频").validated() }
    }
    @Test func channelStartHistoryEvictsOldestEntriesAndRemainsBounded() {
        var channel = PrivateChannel(name: "频道", scopes: [.demo])
        channel.lastStarted = Dictionary(uniqueKeysWithValues: (0..<500).map { (String($0), Date(timeIntervalSince1970: Double($0))) })
        channel.recordStart("latest", at: Date(timeIntervalSince1970: 1000))
        #expect(channel.lastStarted.count == 500 && channel.lastStarted["0"] == nil && channel.lastStarted["latest"] != nil)
    }
}
