import AVFoundation

/// Serializes audio-session transitions across player instances without blocking UI work.
@MainActor
enum PlaybackAudioSession {
    private static var owners: Set<UUID> = []
    private static var tail: Task<Void, Never>?
    private nonisolated static let queue = DispatchQueue(label: "cn.sssnto.glide.audio-session", qos: .userInitiated)

    static func activate(owner: UUID) async throws {
        try Task.checkCancellation()
        owners.insert(owner)
        let previous = tail
        let operation = Task {
            await previous?.value
            guard owners.contains(owner) else { throw CancellationError() }
            try await configure()
            guard owners.contains(owner) else { throw CancellationError() }
            try await setActive(true)
        }
        // Keep the complete asynchronous operation ordered, including system callbacks.
        tail = Task { _ = try? await operation.value }
        try await operation.value
        try Task.checkCancellation()
    }

    static func release(owner: UUID) {
        guard owners.remove(owner) != nil else { return }
        let previous = tail
        tail = Task {
            await previous?.value
            // A closing player must not deactivate a newly opened player's session.
            guard owners.isEmpty else { return }
            try? await setActive(false)
        }
    }

    private nonisolated static func configure() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                assert(!Thread.isMainThread)
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func setActive(_ active: Bool) async throws {
        if #available(iOS 27.0, *) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let session = AVAudioSession.sharedInstance()
                if active {
                    session.activate(options: []) { activated, error in
                        if let error { continuation.resume(throwing: error) }
                        else if activated { continuation.resume() }
                        else { continuation.resume(throwing: SessionError.activation) }
                    }
                } else {
                    session.deactivate(options: .notifyOthersOnDeactivation) { deactivated, error in
                        if let error { continuation.resume(throwing: error) }
                        else if deactivated { continuation.resume() }
                        else { continuation.resume(throwing: SessionError.deactivation) }
                    }
                }
            }
        } else {
            try await setActiveOnQueue(active)
        }
    }

    private nonisolated static func setActiveOnQueue(_ active: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                assert(!Thread.isMainThread)
                do {
                    let options: AVAudioSession.SetActiveOptions = active ? [] : .notifyOthersOnDeactivation
                    try AVAudioSession.sharedInstance().setActive(active, options: options)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private enum SessionError: LocalizedError {
        case activation, deactivation
        var errorDescription: String? {
            switch self {
            case .activation: "无法启用播放声音。"
            case .deactivation: "无法停用播放声音。"
            }
        }
    }
}
