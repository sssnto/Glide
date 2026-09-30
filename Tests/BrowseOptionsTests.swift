import Foundation
import Testing
@testable import GlideCore

@Test func explicitScopeAndSortApplyToEveryPageAndSearch() {
    let options = BrowseOptions(includesDescendants: false, sort: .nameDescending)
    for page in [0, 200, 400] {
        let query = DirectoryQuery.playback(userID: "user", parentID: "folder", start: page, search: "旅行", options: options)
        #expect(query["ParentId"] == "folder")
        #expect(query["Recursive"] == "false")
        #expect(query["SortBy"] == "SortName")
        #expect(query["SortOrder"] == "Descending")
        #expect(query["SearchTerm"] == "旅行")
        #expect(query["StartIndex"] == String(page))
    }
    #expect(BrowseOptions().includesDescendants)
}

@Test @MainActor func directWebDAVScopeDoesNotFetchDescendants() async throws {
    let root = URL(string: "https://nas.example/video/")!
    var fetched: [URL] = []
    let files = try await ScopedQueueCollector.webDAV(root: root, recursive: false, fetch: { url in
        fetched.append(url)
        return [DAVEntry(url: root.appendingPathComponent("child/"), name: "child", isDirectory: true),
                DAVEntry(url: root.appendingPathComponent("direct.mp4"), name: "direct", isDirectory: false)]
    }, progress: { _ in })
    #expect(fetched == [root])
    #expect(files.map(\.name) == ["direct"])
}

@Test func naturalSortHasDeterministicTiesAndQueueKeepsItsOrder() {
    let videos = [Video(id: "b", title: "clip2", subtitle: ""), Video(id: "10", title: "clip10", subtitle: ""), Video(id: "a", title: "clip2", subtitle: "")]
    #expect(VideoSort.nameAscending.sorted(videos).map(\.id) == ["a", "b", "10"])
    let descending = VideoSort.nameDescending.sorted(videos)
    #expect(descending.map(\.id) == ["10", "a", "b"])
    var queue = PlaybackQueue(videos: descending, mode: .sequential, startID: "a")
    queue.setMode(.random, shuffle: { $0.reversed() })
    queue.setMode(.sequential)
    #expect(queue.ordered.map(\.id) == ["10", "a", "b"])
    #expect(queue.current?.id == "a")
}

@Test func addedDateSortUsesServerFieldAndKeepsUndatedVideosLast() {
    let oldest = Date(timeIntervalSince1970: 1_700_000_000)
    let newest = Date(timeIntervalSince1970: 1_800_000_000)
    let videos = [Video(id: "no-date", title: "A", subtitle: ""),
                  Video(id: "new", title: "B", subtitle: "", addedAt: newest),
                  Video(id: "old", title: "C", subtitle: "", addedAt: oldest)]
    #expect(VideoSort.addedNewest.sorted(videos).map(\.id) == ["new", "old", "no-date"])
    #expect(VideoSort.addedOldest.sorted(videos).map(\.id) == ["old", "new", "no-date"])
    for sort in [VideoSort.addedNewest, .addedOldest] {
        let options = BrowseOptions(includesDescendants: true, sort: sort)
        for page in [0, 200] {
            let query = DirectoryQuery.playback(userID: "user", parentID: "home", start: page, options: options)
            #expect(query["ParentId"] == "home")
            #expect(query["SortBy"] == "DateCreated")
            #expect(query["SortOrder"] == sort.jellyfinOrder)
        }
    }
}

@Test func bookmarkAndPerDirectoryPreferencesRoundTripWithoutColliding() throws {
    let sourceA = UUID(), sourceB = UUID()
    let first = DirectoryBookmark(sourceID: sourceA, name: "Movies", jellyPath: [MediaFolder(id: "lib", name: "Movies", isLibrary: true)], davPath: [])
    let second = DirectoryBookmark(sourceID: sourceB, name: "Movies", jellyPath: first.jellyPath, davPath: [])
    #expect(first.id != second.id)
    #expect(try JSONDecoder().decode(DirectoryBookmark.self, from: JSONEncoder().encode(first)) == first)
    let preferences = [first.id: BrowseOptions(includesDescendants: false, sort: .nameDescending), second.id: BrowseOptions()]
    #expect(try JSONDecoder().decode([String: BrowseOptions].self, from: JSONEncoder().encode(preferences)) == preferences)
}

@Test func olderSavedFoldersWithoutArtworkStillDecode() throws {
    let legacy = Data(#"{"id":"home","name":"家庭视频","isLibrary":true,"collectionType":"homevideos"}"#.utf8)
    let folder = try JSONDecoder().decode(MediaFolder.self, from: legacy)
    #expect(folder.primaryImageTag == nil)
    #expect(folder.addedAt == nil)
}

@Test func folderSortUsesServerOrderForEveryPageAndSortsUndatedEntriesLast() {
    for sort in FolderSort.allCases {
        for start in [0, 100, 200] {
            let query = DirectoryQuery.items(userID: "user", parentID: "home", start: start, sort: sort)
            #expect(query["ParentId"] == "home")
            #expect(query["Recursive"] == "false")
            #expect(query["SortBy"] == "IsFolder,\(sort.jellyfinField)")
            #expect(query["SortOrder"] == sort.jellyfinOrder)
            #expect(query["StartIndex"] == String(start))
        }
    }
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    let new = Date(timeIntervalSince1970: 1_800_000_000)
    let folders = [MediaFolder(id: "undated", name: "10", addedAt: nil),
                   MediaFolder(id: "new", name: "2", addedAt: new),
                   MediaFolder(id: "old", name: "1", addedAt: old)]
    #expect(FolderSort.nameAscending.sorted(folders).map(\.id) == ["old", "new", "undated"])
    #expect(FolderSort.addedNewest.sorted(folders).map(\.id) == ["new", "old", "undated"])
    #expect(FolderSort.addedOldest.sorted(folders).map(\.id) == ["old", "new", "undated"])
    let root = URL(string: "https://nas.example/videos/")!
    let directories = [DAVEntry(url: root.appendingPathComponent("a"), name: "A", isDirectory: true, createdAt: old),
                       DAVEntry(url: root.appendingPathComponent("b"), name: "B", isDirectory: true, createdAt: new)]
    #expect(FolderSort.addedNewest.sorted(directories).map(\.name) == ["B", "A"])
}
