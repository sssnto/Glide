import Foundation

/// VLC may leave its audio clock running after an SMB read has stopped.
/// Cached video is allowed to drain: recovery needs both input and pictures stale.
struct SMBReadStall {
    private var lastFrames: UInt64?
    private var lastBytes: UInt64?
    private var pictureAt: TimeInterval = 0
    private var inputAt: TimeInterval = 0

    mutating func sample(at now: TimeInterval, eligible: Bool, frames: UInt64, bytes: UInt64) -> Bool {
        guard eligible, frames > 0 else { self = Self(); return false }
        if lastFrames == nil || frames != lastFrames { pictureAt = now }
        if lastBytes == nil || bytes != lastBytes { inputAt = now }
        lastFrames = frames; lastBytes = bytes
        return now - pictureAt >= 12 && now - inputAt >= 8
    }
}
