import Foundation
import Testing
@testable import GlideCore

@Test func scopedSearchRetainsDirectoryAndPagination() {
    for offset in [0, 200, 400] {
        let query = DirectoryQuery.playback(userID: "u", parentID: "chosen", start: offset, search: "  北境 & coast  ")
        #expect(query["ParentId"] == "chosen")
        #expect(query["Recursive"] == "true")
        #expect(query["StartIndex"] == String(offset))
        #expect(query["SearchTerm"] == "北境 & coast")
        let url = ServerURL.endpoint(URL(string: "https://media.example/jellyfin")!, "Items", query: query)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "SearchTerm" }?.value == "北境 & coast")
    }
    #expect(DirectoryQuery.playback(userID: "u", parentID: "chosen", start: 0, search: " \n")["SearchTerm"] == nil)
}

@Test func historySnapshotDoesNotPersistPlaybackCredentials() throws {
    let video = Video(id: "a", title: "A", subtitle: "", remoteID: "remote", url: URL(string: "https://media.example/stream?api_key=SECRET")!, artwork: URL(string: "https://media.example/image?api_key=SECRET")!)
    let item = PersonalVideo(video: video, lastPlayedAt: Date(timeIntervalSince1970: 123))
    let data = try JSONEncoder().encode(item)
    #expect(!String(decoding: data, as: UTF8.self).contains("SECRET"))
    #expect(try JSONDecoder().decode(PersonalVideo.self, from: data) == item)
    let dav = PersonalVideo(video: Video(id: "dav", title: "DAV", subtitle: "", url: URL(string: "https://user:password@nas.example/video/a.mp4?token=SECRET#test")))
    #expect(dav.video.url?.absoluteString == "https://nas.example/video/a.mp4")
    let demo = PersonalVideo(video: Video(id: "demo", title: "Demo", subtitle: "", url: URL(fileURLWithPath: "/old-bundle/demo0.mp4"), demoIndex: 0))
    #expect(demo.video.url == nil) // Resolve the current app bundle after an update.
}

@Test func resumeExcludesNewCompletedAndInvalidPositions() {
    #expect(!WatchProgress.canResume(position: 0, duration: 12))
    #expect(WatchProgress.canResume(position: 4, duration: 12))
    #expect(!WatchProgress.canResume(position: 10, duration: 12))
    #expect(!WatchProgress.canResume(position: 96, duration: 100))
    #expect(!WatchProgress.canResume(position: .infinity, duration: 100))
    #expect(!WatchProgress.canResume(position: .nan, duration: 100))
    #expect(!WatchProgress.canResume(position: -5, duration: 100))
    #expect(WatchProgress.canResume(position: 20, duration: 0))
}


@Test func browsingMetadataPreservesDiscoveredRuntimeAndHistoryDate() {
    let date = Date(timeIntervalSince1970: 100)
    let saved = PersonalVideo(video: Video(id: "dav", title: "Old title", subtitle: "", duration: 100), lastPlayedAt: date)
    let refreshed = saved.updatingMetadata(Video(id: "dav", title: "New title", subtitle: "", duration: 0))
    #expect(refreshed.video.title == "New title")
    #expect(refreshed.video.duration == 100)
    #expect(refreshed.lastPlayedAt == date)
    #expect(!WatchProgress.canResume(position: 98, duration: refreshed.video.duration))
    #expect(saved.updatingMetadata(Video(id: "dav", title: "New", subtitle: "", duration: 120)).video.duration == 120)
}
