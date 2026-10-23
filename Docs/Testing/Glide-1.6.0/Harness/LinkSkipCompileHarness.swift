import Foundation
@MainActor protocol DirectorySourceProvider { func entries(server: MediaServer, directory: URL?) async throws -> [DAVEntry] }
enum Credentials { static func read(_ id: UUID) -> String? { nil }; static func save(_ value: String, for id: UUID) throws {}; static func delete(_ id: UUID) {} }
@MainActor enum LocalMediaStore {
 static func playback(_ video: Video, server: MediaServer) throws -> PlaybackResource {
  PlaybackResource(url: video.url ?? server.address, localAccess: LocalFileAccess(root: server.address))
 }
}
@MainActor enum PlaybackPreferences {
 static var subtitleLanguage: String { "" }
 static var forcedOnly: Bool { false }
}

@MainActor final class LibraryStore { func removeStreamLinkRecords(_ id: String) {} }
final class MediaClient: Sendable { static let shared = MediaClient(); func mediaSegments(server: MediaServer, itemID: String) async throws -> [SkipSegment] { [] } }
