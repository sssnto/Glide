import XCTest
@testable import GlideCore

final class RotationQueueTests: XCTestCase {
    func testBatchGatePreservesSingleSaveCompatibility() throws {
        let decoder = JSONDecoder()
        func capability(_ version: String) throws -> JellyfinRotationCapability {
            try decoder.decode(JellyfinRotationCapability.self, from: Data("{\"protocolVersion\":1,\"pluginVersion\":\"\(version)\",\"available\":true}".utf8))
        }
        XCTAssertTrue(try capability("1.0.3").supportsSafePublication)
        XCTAssertFalse(try capability("1.0.3").supportsBatchRotation)
        XCTAssertTrue(try capability("1.1.0").supportsBatchRotation)
        XCTAssertFalse(try capability("1.1.0-preview").supportsBatchRotation)
    }
    @MainActor func testBatchCollectionRejectsOversizedScopeBeforeLoadingRemainingPages() async throws {
        var requests: [Int] = []
        do {
            _ = try await ScopedQueueCollector.pages(limit: 1000, fetch: { start in
                requests.append(start)
                return VideoPage(videos: [], total: 1001, nextIndex: 200)
            }, progress: { _ in XCTFail("Oversized scope must not publish partial selection") })
            XCTFail("Expected limit rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("1,000")) }
        XCTAssertEqual(requests, [0])
    }
    func testQueueSnapshotDecodesUncertainAndCancelledCountsWithoutTreatingThemAsSaved() throws {
        let json = """
        {"batchId":"00000000-0000-0000-0000-000000000001","requestId":"00000000-0000-0000-0000-000000000002","quarterTurns":1,"state":"needs_verification","total":10,"completed":3,"failed":1,"remaining":2,"cancelled":3,"needsVerification":1,"updatedAt":"2026-11-11T00:00:00Z","current":null,"items":null}
        """
        let batch = try JSONDecoder().decode(RotationBatch.self, from: Data(json.utf8))
        XCTAssertEqual(batch.completed, 3)
        XCTAssertEqual(batch.finishedCount + batch.remaining, batch.total)
        XCTAssertFalse(batch.active)
        XCTAssertEqual(batch.stateTitle, "需要核对")
    }
    func testStableSubmissionIdentitySurvivesPersistence() throws {
        let request = RotationBatchRequest(requestId: UUID(), quarterTurns: 3, items: [RotationBatchItem(itemId: UUID().uuidString, title: "原创短片")])
        let persisted = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(RotationBatchRequest.self, from: persisted), request)
        let text = String(decoding: persisted, as: UTF8.self)
        XCTAssertFalse(text.contains("token")); XCTAssertFalse(text.contains("/media/")); XCTAssertFalse(text.contains("password"))
    }
}
