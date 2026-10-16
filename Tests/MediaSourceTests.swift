import Foundation
import Testing
@testable import GlideCore

@Test func localIdentitySurvivesSourceRelocationAndRetainsNamespaces() throws {
    let id = UUID(), root = URL(fileURLWithPath: "/old/Documents"), moved = URL(fileURLWithPath: "/new/Documents")
    let relative = try LocalMediaIdentity.relativePath(root: root, file: root.appendingPathComponent("旅行/片段 01.mp4"))
    let restored = try LocalMediaIdentity.fileURL(root: moved, relativePath: relative)
    #expect(restored.path == "/new/Documents/旅行/片段 01.mp4")
    #expect(LocalMediaIdentity.id(sourceID: id, relativePath: relative) == LocalMediaIdentity.id(sourceID: id, relativePath: try LocalMediaIdentity.relativePath(root: moved, file: restored)))
    #expect(LocalMediaIdentity.id(sourceID: id, relativePath: relative) != LocalMediaIdentity.id(sourceID: UUID(), relativePath: relative))
    for invalid in ["../secret.mp4", "/outside.mp4", "child/../../secret.mp4", "./clip.mp4"] {
        #expect(throws: MediaError.self) { try LocalMediaIdentity.fileURL(root: root, relativePath: invalid) }
    }
    #expect(throws: MediaError.self) { try LocalMediaIdentity.relativePath(root: root, file: URL(fileURLWithPath: "/old/Documents-other/a.mp4")) }
}

@Test func localEnumerationSkipsHiddenFilesAndSymlinksAndHonorsQueueScope() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("子目录"), withIntermediateDirectories: true)
    for name in ["one.mp4", ".hidden.mp4", "notes.txt", "子目录/two.mov"] { try Data([1]).write(to: root.appendingPathComponent(name)) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.mp4"), withDestinationURL: root.appendingPathComponent("one.mp4"))
    let entries = try LocalDirectoryIndex.entries(root: root, directory: root)
    #expect(!entries.contains { $0.name == ".hidden.mp4" || $0.name == "alias.mp4" })
    let all = try await ScopedQueueCollector.webDAV(root: root, fetch: { try LocalDirectoryIndex.entries(root: root, directory: $0) }, progress: { _ in })
    #expect(Set(all.map(\.name)) == ["one.mp4", "two.mov"])
    let direct = try await ScopedQueueCollector.webDAV(root: root, recursive: false, fetch: { try LocalDirectoryIndex.entries(root: root, directory: $0) }, progress: { _ in })
    #expect(direct.map(\.name) == ["one.mp4"])
    let outside = root.appendingPathComponent("escape.mp4")
    try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: root.deletingLastPathComponent())
    #expect(throws: MediaError.self) { try LocalMediaIdentity.fileURL(root: root, relativePath: "escape.mp4/private.mp4") }
}

@Test func localSourcesDoNotAdvertiseServerProgressOrDownload() throws {
    #expect(SourceKind.local.capabilities.contains(.recursiveQueue))
    #expect(!SourceKind.local.capabilities.contains(.credentials))
    #expect(!SourceKind.local.capabilities.contains(.progressReporting))
    #expect(!SourceKind.webDAV.capabilities.contains(.download))
    let old = Data(#"{"name":"Old","kind":"jellyfin","address":"https://example.test","username":"tester","id":"00000000-0000-0000-0000-000000000001"}"#.utf8)
    #expect(try JSONDecoder().decode(MediaServer.self, from: old).localBookmark == nil)
    let root = URL(fileURLWithPath: "/old/root")
    let video = Video(id: "local", title: "clip", subtitle: "", url: root.appendingPathComponent("clip.mp4"), localRelativePath: "clip.mp4")
    #expect(PersonalVideo(video: video).video.url == nil)
    #expect(PersonalVideo(video: video).video.localRelativePath == "clip.mp4")
}

@Test func snapshotRecoversLastValidBackupAndDoesNotReplaceItWithCorruptData() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecoverableStore<[String]>(file: root.appendingPathComponent("state.json"))
    #expect(try store.load() == nil)
    try store.save(["first"]); try store.save(["second"])
    try Data("broken".utf8).write(to: store.file)
    let recovered = try #require(try store.load())
    #expect(recovered.recovered && recovered.value == ["first"])
    try store.save(["third"])
    try Data("broken again".utf8).write(to: store.file)
    #expect(try store.load()?.value == ["first"])
    try Data("also broken".utf8).write(to: store.backup)
    #expect(throws: (any Error).self) { try store.load() }
}

@Test func migrationPreservesOldRecordsAndRejectsCorruptLegacyJSON() throws {
    let suite = "glide-migration-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let server = MediaServer(name: "Old", kind: .webDAV, address: URL(string: "https://example.test")!, username: "tester")
    defaults.set(try JSONEncoder().encode([server]), forKey: "servers")
    defaults.set(["favorite"], forKey: "favorites"); defaults.set(["favorite": 123.0], forKey: "positions")
    let state = try LibrarySnapshot.legacy(from: defaults)
    #expect(state.servers == [server] && state.favorites == ["favorite"] && state.positions["favorite"] == 123)
    #expect(defaults.data(forKey: "servers") != nil)
    defaults.set(Data("bad json".utf8), forKey: "personalVideos.v1")
    #expect(throws: (any Error).self) { try LibrarySnapshot.legacy(from: defaults) }
}

@Test func futureSnapshotIsNeverDowngradedToAnOlderBackup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RecoverableStore<[String]>(file: root.appendingPathComponent("state.json"))
    try store.save(["old"]); try store.save(["current"])
    let future = Data(#"{"schema":2,"value":{"different":"format"}}"#.utf8)
    try future.write(to: store.file)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(throws: (any Error).self) { try store.save(["downgrade"]) }
    #expect(try Data(contentsOf: store.file) == future)
}
