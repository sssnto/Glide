import XCTest
import StoreKit
import StoreKitTest
@testable import CommerceLab

final class CommerceLabTests: XCTestCase {
    @MainActor func testPurchaseRestoreAndRefund() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Glide", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        defer { session.clearTransactions() }
        let store = ProStore.shared
        await store.load()
        XCTAssertEqual(store.status, .available)
        _ = try XCTUnwrap(store.product)
        await store.purchase()
        XCTAssertEqual(store.status, .owned, store.message ?? "")
        await store.restore()
        XCTAssertEqual(store.status, .owned, store.message ?? "")
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        await store.refreshEntitlement()
        XCTAssertEqual(store.status, .available)
    }
}
