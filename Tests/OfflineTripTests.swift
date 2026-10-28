import Foundation
import Testing
@testable import GlideCore

private func tripCandidate(_ id: String, seconds: Double = 100, bytes: Int64 = 100, source: UUID? = nil, series: String? = nil, season: Int = 1, episode: Int = 1) -> OfflineTripCandidate {
    .init(video: Video(id: id, title: id, subtitle: "", sourceID: source, duration: seconds, mediaType: series == nil ? "Movie" : "Episode", seriesID: series, seasonNumber: season, episodeNumber: episode), bytes: bytes)
}

@Test func tripBudgetsUseFullFileBytesAndRemainingViewingTime() {
    var continuing = tripCandidate("continued", seconds: 100, bytes: 70)
    continuing.video.resume = 60
    let plan = OfflineTripPlanner.plan([continuing, tripCandidate("second", seconds: 60, bytes: 30), tripCandidate("third", seconds: 1, bytes: 1)], seconds: 100, bytes: 100)
    #expect(plan.items.map(\.id) == ["continued", "second"])
    #expect(plan.seconds == 100)
    #expect(plan.bytes == 100)
}

@Test func tripRejectsUnknownNonfiniteAndOverflowBudgets() {
    for time in [Double.nan, .infinity, 0, -1] { #expect(OfflineTripPlanner.plan([tripCandidate("a")], seconds: time, bytes: 100).items.isEmpty) }
    let plan = OfflineTripPlanner.plan([tripCandidate("a", seconds: .nan), tripCandidate("b", bytes: 0), tripCandidate("c", bytes: -1), tripCandidate("d", bytes: Int64.max), tripCandidate("e", bytes: 1)], seconds: 100, bytes: 1)
    #expect(plan.items.map(\.id) == ["e"])
    #expect(OfflineTripPlanner.plan([tripCandidate("a")], seconds: 100, bytes: 0).items.isEmpty)
}

@Test func tripDeduplicatesSharedDownloadsWithoutDroppingTheirSize() {
    var candidate = tripCandidate("same"); candidate.alreadySaved = true
    let plan = OfflineTripPlanner.plan([candidate, candidate, tripCandidate("b")], seconds: 300, bytes: 100)
    #expect(plan.items.count == 1)
    #expect(plan.bytes == 100)
}

@Test func episodeTripKeepsNumericOrderAndSkipsWatchedAcrossSeasons() {
    var watched = tripCandidate("s1e2", series: "show", episode: 2); watched.video.isWatched = true
    let values = [tripCandidate("s2e1", series: "show", season: 2), tripCandidate("s1e3", series: "show", episode: 3), watched, tripCandidate("s1e1", series: "show")]
    #expect(OfflineTripPlanner.episodes(values, count: 3, bytes: 1000).items.map(\.id) == ["s1e1", "s1e3", "s2e1"])
}

@Test func episodeTripDoesNotJumpOverAnUnfittingOrUnknownEpisode() {
    for bytes in [Int64(0), 101] {
        let values = [tripCandidate("first", bytes: bytes, series: "show"), tripCandidate("second", bytes: 1, series: "show", episode: 2)]
        #expect(OfflineTripPlanner.episodes(values, count: 3, bytes: 100).items.isEmpty)
    }
}

@Test func episodeTripRequiresOneAccountBoundSeriesAndHonorsCount() {
    let a = UUID(), b = UUID()
    let mixed = [tripCandidate("one", source: a, series: "show"), tripCandidate("two", source: b, series: "show")]
    #expect(OfflineTripPlanner.episodes(mixed, count: 3, bytes: 1000).items.isEmpty)
    let values = (1...10).map { tripCandidate("e\($0)", series: "show", episode: $0) }
    #expect(OfflineTripPlanner.episodes(values.reversed(), count: 5, bytes: 1000).items.map(\.id) == ["e1", "e2", "e3", "e4", "e5"])
    #expect(OfflineTripPlanner.episodes(values, count: 0, bytes: 1000).items.isEmpty)
}

@Test func tripSnapshotRecoveryAndValidationRetainStableReferences() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RecoverableStore<[OfflineTrip]>(file: directory.appendingPathComponent("trips.json"))
    let original = try OfflineTrip(name: " 火车旅程 ", videoIDs: ["server-account-video"], targetSeconds: 14400, maximumBytes: 1024).validated()
    #expect(original.name == "火车旅程")
    try store.save([original]); try store.save([])
    try Data("corrupt".utf8).write(to: store.file)
    let restored = try store.load()
    #expect(restored?.recovered == true)
    #expect(restored?.value.first?.videoIDs == original.videoIDs)
    #expect(throws: MediaError.self) { try OfflineTrip(name: "", videoIDs: [], targetSeconds: .nan, maximumBytes: 0).validated() }
    #expect(throws: MediaError.self) { try OfflineTrip(name: "重复", videoIDs: ["same", "same"], targetSeconds: 10, maximumBytes: 10).validated() }
}

@Test func offlineCheckExpiresWhenFileChangesAndLocalOnlyFlagSurvivesCoding() throws {
    let now = Date()
    let check = OfflinePlaybackCheck(size: 100, modified: now, engine: .vlc, checkedAt: now)
    #expect(check.matches(size: 100, modified: now))
    #expect(!check.matches(size: 101, modified: now))
    #expect(!check.matches(size: 100, modified: now.addingTimeInterval(1)))
    var video = tripCandidate("offline").video; video.offlineOnly = true
    #expect(try JSONDecoder().decode(Video.self, from: JSONEncoder().encode(video)).offlineOnly == true)
}

@Test func tripOlderSnapshotWithoutNewVersionMetadataStillDecodes() throws {
    let trip = OfflineTrip(name: "兼容快照", videoIDs: ["one"], targetSeconds: 100, maximumBytes: 100)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trip)) as! [String: Any]
    for key in ["sourceVersions", "accountBindings", "expectedSizes", "videos"] { json.removeValue(forKey: key) }
    let restored = try JSONDecoder().decode(OfflineTrip.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored.id == trip.id)
    #expect(restored.sourceVersions.isEmpty)
}

@Test func offlineDiskReservationsProtectTheWholeQueueAndCannotOverflow() {
    #expect(OfflineMediaFiles.canReserve(bytes: 40, availableBytes: 100, reservations: [20, 20], safetyMargin: 20))
    #expect(!OfflineMediaFiles.canReserve(bytes: 41, availableBytes: 100, reservations: [20, 20], safetyMargin: 20))
    #expect(!OfflineMediaFiles.canReserve(bytes: 1, availableBytes: 100, reservations: [Int64.max, Int64.max], safetyMargin: 20))
    #expect(!OfflineMediaFiles.canReserve(bytes: 1, availableBytes: -1, reservations: [], safetyMargin: 20))
    #expect(!OfflineMediaFiles.canReserve(bytes: 0, availableBytes: 100, reservations: [], safetyMargin: 20))
    #expect(!OfflineMediaFiles.canReserve(bytes: 1, availableBytes: 100, reservations: [-1], safetyMargin: 20))
}
