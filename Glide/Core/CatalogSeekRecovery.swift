import Foundation

/// A bad copied-HLS index must not leave the user at the wrong position.
struct CatalogSeekRecovery {
    private(set) var attempted = false
    mutating func returnToOriginal(kind: SourceKind, container: String?, delivery: PlaybackDelivery,
                                  originalWasPlayable: Bool, hasServerTracks: Bool, target: Double, actual: Double, tolerance: Double) -> Bool {
        guard !attempted, kind == .emby, originalWasPlayable, !hasServerTracks,
              ["mp4", "m4v", "mov"].contains(container?.lowercased() ?? ""),
              delivery == .remux || delivery == .audioConversion,
              target.isFinite, actual.isFinite, tolerance.isFinite,
              target >= 0, actual >= 0,
              abs(actual - target) > max(0, tolerance) + 0.15 else { return false }
        attempted = true
        return true
    }
}
