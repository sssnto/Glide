import Foundation

/// Only media identity and display metadata; never save a resolved playback resource/token.
struct PersonalVideo: Codable, Identifiable, Equatable {
    var video: Video
    var lastPlayedAt: Date?
    var id: String { video.id }
    func updatingMetadata(_ incoming: Video) -> PersonalVideo {
        var metadata = incoming
        if (!metadata.duration.isFinite || metadata.duration <= 0), video.duration.isFinite, video.duration > 0 {
            metadata.duration = video.duration
        }
        return PersonalVideo(video: metadata, lastPlayedAt: lastPlayedAt)
    }
    init(video: Video, lastPlayedAt: Date? = nil) {
        self.video = video
        self.video.offlineOnly = nil // Session intent must not force future online history entries offline.
        self.lastPlayedAt = lastPlayedAt
        self.video.artwork = nil // Rebuild from the current server address when displaying.
        if video.remoteID != nil || video.demoIndex != nil || video.localRelativePath != nil { self.video.url = nil }
        else if let url = video.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
            self.video.url = components.url
        }
    }
}

enum WatchProgress {
    static func canResume(position: Double, duration: Double) -> Bool {
        guard position.isFinite, position > 1 else { return false }
        guard duration.isFinite, duration > 0 else { return true }
        return position < duration - 3 && position / duration < 0.95
    }
}
