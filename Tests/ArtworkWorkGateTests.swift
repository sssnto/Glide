import Foundation
import Testing
@testable import GlideCore

struct ArtworkWorkGateTests {
    @Test func cancelledOffscreenJobsNeverOccupyDecoderSlots() async throws {
        let gate=ArtworkWorkGate(limit:2)
        let a=try await gate.acquire(key:"a"),b=try await gate.acquire(key:"b")
        let waiting=Task { try await gate.acquire(key:"offscreen") }
        let deadline=Date().addingTimeInterval(2)
        while await gate.counts.queued == 0,Date()<deadline { await Task.yield() }
        #expect(await gate.counts.queued == 1)
        waiting.cancel()
        do { _=try await waiting.value;Issue.record("An offscreen job received a decoder") } catch is CancellationError {} catch { throw error }
        #expect(await gate.counts.active == 2)
        #expect(await gate.counts.queued == 0)
        await gate.release(a);await gate.release(b)
        #expect(await gate.counts.active == 0)
    }
    @Test func duplicateKeysSerializeWhileOtherVideosCanProgress() async throws {
        let gate=ArtworkWorkGate(limit:2)
        let a=try await gate.acquire(key:"same-file")
        let duplicate=Task { try await gate.acquire(key:"same-file") }
        let b=try await gate.acquire(key:"other-file")
        #expect(await gate.counts.active == 2)
        await gate.release(b)
        #expect(await gate.counts.active == 1)
        await gate.release(a)
        let next=try await duplicate.value
        #expect(await gate.counts.active == 1)
        await gate.release(next)
        #expect(await gate.counts.active == 0)
    }
}
