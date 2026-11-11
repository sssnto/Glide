import Foundation

/// Cancel offscreen work while queued, cap decoders, and serialize the same
/// cache key so a second tile can reuse the first tile's persisted frame.
actor ArtworkWorkGate {
    struct Permit: Hashable, Sendable { let id: UUID; let key: String }
    private struct Waiter { let permit: Permit; let continuation: CheckedContinuation<Permit, Error> }
    private let limit: Int
    private var running = Set<Permit>()
    private var waiting: [Waiter] = []
    init(limit: Int = 2) { self.limit = max(1, limit) }
    func acquire(key: String) async throws -> Permit {
        let permit = Permit(id: UUID(), key: key)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiting.append(Waiter(permit: permit, continuation: continuation)); drain()
            }
        } onCancel: { Task { await self.cancel(permit) } }
    }
    func release(_ permit: Permit) { running.remove(permit); drain() }
    private func cancel(_ permit: Permit) {
        guard let index = waiting.firstIndex(where: { $0.permit == permit }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func drain() {
        while running.count < limit,
              let index = waiting.firstIndex(where: { next in !running.contains(where: { $0.key == next.permit.key }) }) {
            let next = waiting.remove(at: index); running.insert(next.permit)
            next.continuation.resume(returning: next.permit)
        }
    }
    var counts: (active: Int, queued: Int) { (running.count, waiting.count) }
}
