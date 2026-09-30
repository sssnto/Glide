import Foundation
import AVFoundation
import Testing
@testable import GlideCore

@Test func downloadedMovieRetainsContainerAndCanBePublishedAfterRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("glide-offline-test-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Glide/Resources/demo0.mp4")
    let temporary = root.appendingPathComponent("URLSession-download.tmp")
    try FileManager.default.copyItem(at: source, to: temporary)
    let directory = root.appendingPathComponent("OfflineMedia", isDirectory: true)
    let filename = UUID().uuidString + ".mp4"
    try OfflineMediaFiles(directory: directory).stage(temporary, filename: filename)
    #expect(!FileManager.default.fileExists(atPath: temporary.path))

    // Reconstruct the storage after staging, as when an app is relaunched.
    let recovered = OfflineMediaFiles(directory: directory)
    let pending = recovered.pendingURL(filename)
    let expected = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value
    try OfflineMediaFiles.validateSize(pending, expectedBytes: expected)
    let asset = AVURLAsset(url: pending)
    #expect(try await asset.load(.isPlayable))
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    try recovered.commit(filename)
    #expect(!FileManager.default.fileExists(atPath: pending.path))
    let completed = AVURLAsset(url: recovered.fileURL(filename))
    #expect(try await completed.load(.isPlayable))
    recovered.remove(filename)
    #expect(!FileManager.default.fileExists(atPath: recovered.fileURL(filename).path))
}

@Test func offlineDownloadRejectsErrorPagesAndIncompleteFiles() throws {
    for status in [401, 403, 404, 500] {
        #expect(throws: MediaError.self) { try OfflineMediaFiles.validateResponse(status: status, mimeType: "video/mp4") }
    }
    for type in ["text/html", "application/json", "application/problem+json", "application/xml", "application/vnd.apple.mpegurl"] {
        #expect(throws: MediaError.self) { try OfflineMediaFiles.validateResponse(status: 200, mimeType: type) }
    }
    try OfflineMediaFiles.validateResponse(status: 200, mimeType: "video/mp4")
    try OfflineMediaFiles.validateResponse(status: 206, mimeType: "application/octet-stream")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data().write(to: url)
    #expect(throws: MediaError.self) { try OfflineMediaFiles.validateSize(url, expectedBytes: nil) }
    try Data([1, 2, 3]).write(to: url)
    #expect(throws: MediaError.self) { try OfflineMediaFiles.validateSize(url, expectedBytes: 4) }
    try OfflineMediaFiles.validateSize(url, expectedBytes: 3)
}

@Test func offlineDownloadDoesNotStageFilesOutsideItsDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = OfflineMediaFiles(directory: directory)
    for filename in ["../movie.mp4", "/tmp/movie.mp4", "movie", "movie.html"] {
        #expect(throws: MediaError.self) { try storage.stage(URL(fileURLWithPath: "/nonexistent"), filename: filename) }
    }
}
