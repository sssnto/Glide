import Foundation
import Testing
@testable import GlideCore

private func clip(_ id: String) -> Video { Video(id: id, title: id, subtitle: "") }

@Test func expandingPreviewPreservesCurrentAndSequentialOrder() {
    var queue = PlaybackQueue(videos: [clip("B"), clip("C")], mode: .sequential, startID: "C")
    queue.replaceVideos([clip("A"), clip("B"), clip("C"), clip("D")])
    #expect(queue.current?.id == "C")
    #expect(queue.ordered.map(\.id) == ["A", "B", "C", "D"])
    let advanced = queue.move(1); #expect(advanced)
    #expect(queue.current?.id == "D")
}

@Test func expandingRandomPreviewKeepsPlayedHistory() {
    var queue = PlaybackQueue(videos: [clip("B"), clip("C")], mode: .random, startID: "B", shuffle: { $0.reversed() })
    let reachedSecond = queue.move(1); #expect(reachedSecond)
    queue.replaceVideos([clip("A"), clip("B"), clip("C"), clip("D")], shuffle: { $0.reversed() })
    #expect(queue.current?.id == "C")
    #expect(queue.ordered.map(\.id) == ["B", "C", "D", "A"])
    let returned = queue.move(-1); #expect(returned)
    #expect(queue.current?.id == "B")
}

@Test func recursivePlaybackRetainsSelectedDirectoryOnEveryPage() {
    for offset in [0, 200, 400] {
        let query = DirectoryQuery.playback(userID: "user", parentID: "selected-folder", start: offset)
        #expect(query["ParentId"] == "selected-folder")
        #expect(query["Recursive"] == "true")
        #expect(query["MediaTypes"] == "Video")
        #expect(query["IsFolder"] == "false")
        #expect(query["StartIndex"] == String(offset))
    }
    #expect(DirectoryQuery.items(userID: "user", parentID: "selected-folder", start: 0)["Recursive"] == "false")
}

@Test func sequentialQueueAndEndBoundaries() {
    var queue = PlaybackQueue(videos: [clip("A"), clip("B"), clip("C")], mode: .sequential)
    #expect(queue.current?.id == "A")
    let moved0 = queue.move(-1); #expect(!moved0)
    let moved1 = queue.move(1); #expect(moved1); #expect(queue.current?.id == "B")
    let moved2 = queue.move(1); #expect(moved2); #expect(queue.current?.id == "C")
    let moved3 = queue.move(1); #expect(!moved3); #expect(queue.current?.id == "C")
    let moved4 = queue.move(-1); #expect(moved4); #expect(queue.current?.id == "B")
}

@Test func randomVisitsWholeQueueOnceAndBackUsesHistory() {
    let videos = (0..<205).map { clip(String($0)) }
    var queue = PlaybackQueue(videos: videos + [videos[0]], mode: .random, shuffle: { $0.reversed() })
    #expect(queue.ordered.count == 205)
    #expect(queue.current?.id == "204")
    var seen: [String] = [queue.current!.id]
    while queue.move(1) { seen.append(queue.current!.id) }
    #expect(Set(seen).count == 205)
    #expect(Set(seen) == Set(videos.map(\.id)))
    let moved5 = queue.move(-1); #expect(moved5)
    #expect(queue.current?.id == seen[seen.count - 2])
    let moved6 = queue.move(1); #expect(moved6); #expect(queue.current?.id == seen.last)
}

@Test func changingModeKeepsCurrentVideoAndRestoresSequentialOrder() {
    let clips = [clip("A"), clip("B"), clip("C"), clip("D")]
    var queue = PlaybackQueue(videos: clips, mode: .sequential, startID: "B")
    queue.setMode(.random, shuffle: { $0.reversed() })
    #expect(queue.current?.id == "B")
    #expect(queue.ordered.map(\.id) == ["B", "D", "C", "A"])
    queue.setMode(.sequential)
    #expect(queue.current?.id == "B")
    let moved7 = queue.move(1); #expect(moved7); #expect(queue.current?.id == "C")
    let pinned = PlaybackQueue(videos: clips, mode: .random, startID: "C", shuffle: { $0.reversed() })
    #expect(pinned.current?.id == "C")
    #expect(Set(pinned.ordered.map(\.id)).count == 4)
}

@Test func emptyAndSingleVideoQueues() {
    var empty = PlaybackQueue(videos: [], mode: .random)
    #expect(empty.current == nil); let moved8 = empty.move(1); #expect(!moved8)
    empty.setMode(.sequential); #expect(empty.current == nil)
    var one = PlaybackQueue(videos: [clip("A")], mode: .random)
    #expect(!one.canGoBack && !one.canGoForward)
    one.setMode(.sequential); #expect(one.current?.id == "A")
}

@Test func selectingEpisodeKeepsQueueOrderAndAdjacentNavigation() {
    var queue = PlaybackQueue(videos: [clip("S1E1"), clip("S1E2"), clip("S2E1")], mode: .sequential)
    let selectedLast = queue.select("S2E1"); #expect(selectedLast)
    #expect(queue.current?.id == "S2E1")
    #expect(!queue.canGoForward)
    let movedBack = queue.move(-1); #expect(movedBack)
    #expect(queue.current?.id == "S1E2")
    let selectedMissing = queue.select("removed-episode"); #expect(!selectedMissing)
    #expect(queue.current?.id == "S1E2")
    let selectedCurrent = queue.select("S1E2"); #expect(selectedCurrent)
    #expect(queue.ordered.map(\.id) == ["S1E1", "S1E2", "S2E1"])
    let selectedFirst = queue.select("S1E1"); #expect(selectedFirst)
    #expect(!queue.canGoBack)
    let movedForward = queue.move(1); #expect(movedForward)
    #expect(queue.current?.id == "S1E2")
}

@Test @MainActor func completeCollectionIncludesLaterPagesAndDeduplicates() async throws {
    var offsets: [Int] = [], counts: [Int] = []
    let videos = try await ScopedQueueCollector.pages(fetch: { offset in
        offsets.append(offset)
        return offset == 0 ? VideoPage(videos: [clip("child/A"), clip("child/B")], total: 4, nextIndex: 2) : VideoPage(videos: [clip("child/B"), clip("other-child/C")], total: 4, nextIndex: 4)
    }, progress: { counts.append($0) })
    #expect(offsets == [0, 2])
    #expect(videos.map(\.id) == ["child/A", "child/B", "other-child/C"])
    #expect(counts == [2, 3])
}

@Test @MainActor func incompletePaginationDoesNotSilentlyReturnPartialQueue() async {
    await #expect(throws: (any Error).self) {
        try await ScopedQueueCollector.pages(fetch: { _ in VideoPage(videos: [], total: 10, nextIndex: 0) }, progress: { _ in })
    }
}

@Test @MainActor func webDAVRecursionStaysInsideRootAndStopsCycles() async throws {
    let root = URL(string: "https://nas.example/video/chosen/")!
    let child = root.appendingPathComponent("season/")
    var fetched: [URL] = []
    let result = try await ScopedQueueCollector.webDAV(root: root, fetch: { directory in
        fetched.append(directory)
        if directory == root {
            return [DAVEntry(url: child, name: "season", isDirectory: true),
                    DAVEntry(url: URL(string: "https://nas.example/video/chosen-other/leak.mp4")!, name: "leak", isDirectory: false),
                    DAVEntry(url: URL(string: "https://foreign.example/video/chosen/leak.mp4")!, name: "foreign", isDirectory: false)]
        }
        return [DAVEntry(url: root, name: "cycle", isDirectory: true),
                DAVEntry(url: child.appendingPathComponent("02.mp4"), name: "02", isDirectory: false),
                DAVEntry(url: child.appendingPathComponent("01.mp4"), name: "01", isDirectory: false),
                DAVEntry(url: child.appendingPathComponent("notes.txt"), name: "notes", isDirectory: false)]
    }, progress: { _ in })
    #expect(fetched == [root, child])
    #expect(result.map(\.name) == ["01", "02"])
    #expect(!DirectoryScope.contains(root: root, child: URL(string: "https://nas.example/video/chosen/../outside/a.mp4")!))
}

@Test @MainActor func cancellationDoesNotStartCollection() async {
    var fetched = false
    let task = Task { @MainActor in
        try await ScopedQueueCollector.pages(fetch: { _ in
            fetched = true
            return VideoPage(videos: [clip("A")], total: 1, nextIndex: 1)
        }, progress: { _ in })
    }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled collection returned a queue") }
    catch { #expect(error is CancellationError) }
    #expect(!fetched)
}
