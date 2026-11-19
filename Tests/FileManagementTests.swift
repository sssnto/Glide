import Foundation
import Testing
@testable import GlideCore

struct FileManagementTests {
    private func item(_ id: String) -> FileActionItem { FileActionItem(itemId: id, mediaSourceId: id + "-source", expectedVersion: "v1", title: id) }
    @Test func moveRequiresExplicitDestination() {
        let request = FileActionRequest(requestId: UUID(), operation: .move, items: [item("a")])
        #expect(throws: FileManagementFailure.self) { try request.validate() }
        var ready = request; ready.destinationId = "folder"
        #expect(throws: Never.self) { try ready.validate() }
    }
    @Test func emptyDuplicateAndOversizedBatchesRefused() {
        for items in [[FileActionItem](), [item("a"), item("A")], (0..<501).map { item(String($0)) }] {
            let request = FileActionRequest(requestId: UUID(), operation: .trash, items: items)
            #expect(throws: FileManagementFailure.self) { try request.validate() }
        }
    }
    @Test func restoreRequiresOriginalReceiptAndVersion() {
        let missing = FileActionRequest(requestId: UUID(), operation: .restore, items: [item("a")])
        #expect(throws: FileManagementFailure.self) { try missing.validate() }
        var ready = missing; ready.restoreBatchId = UUID()
        #expect(throws: Never.self) { try ready.validate() }
        let unverified = FileActionRequest(requestId: UUID(), operation: .trash, items: [FileActionItem(itemId: "a", mediaSourceId: "", expectedVersion: "", title: "a")])
        #expect(throws: FileManagementFailure.self) { try unverified.validate() }
    }
    @Test func requestRoundTripPreservesIdempotency() throws {
        let request = FileActionRequest(requestId: UUID(), operation: .move, items: [item("a"), item("b")], destinationId: "destination")
        #expect(try JSONDecoder().decode(FileActionRequest.self, from: JSONEncoder().encode(request)) == request)
    }
    @Test func serverReceiptSeparatesCompletedFromRetryAndRestore() throws {
        let data = Data("""
        {"batchId":"00000000-0000-0000-0000-000000000001","requestId":"00000000-0000-0000-0000-000000000002","operation":"trash","destinationName":"回收目录","state":"finished","updatedAt":"2026-11-16","total":2,"completed":1,"failed":1,"remaining":0,"cancelled":0,"needsVerification":0,"canRestore":true,"refreshPending":false,"items":[{"itemId":"a","mediaSourceId":"a","title":"A.mp4","state":"completed","relatedFiles":1},{"itemId":"b","mediaSourceId":"b","title":"B.mp4","state":"failed","errorCode":"destination_exists","relatedFiles":0}]}
        """.utf8)
        let receipt = try JSONDecoder().decode(FileActionBatch.self, from: data)
        #expect(receipt.restoreItems.map(\.itemId) == ["a"])
        #expect(receipt.attention && !receipt.active && receipt.finished == 2)
        #expect(receipt.canRestore && receipt.failed == 1)
    }
}
