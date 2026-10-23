import Foundation
@MainActor protocol DirectorySourceProvider { func entries(server: MediaServer, directory: URL?) async throws -> [DAVEntry] }
enum Credentials { static func read(_ id: UUID) -> String? { nil } }
@MainActor enum LocalMediaStore {
 static func playback(_ video: Video, server: MediaServer) throws -> PlaybackResource {
  PlaybackResource(url: video.url ?? server.address, localAccess: LocalFileAccess(root: server.address))
 }
}
@MainActor enum PlaybackPreferences {
 static var subtitleLanguage: String { "" }
 static var forcedOnly: Bool { false }
}
