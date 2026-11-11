import Foundation

// Run with ProStore.swift; this checks the decision logic, not StoreKit transactions.
@main
struct CommerceStateCheck {
    @MainActor static func main() {
        precondition(ProStore.isProTransaction(productID: ProStore.productID, isNonConsumable: true))
        precondition(!ProStore.isProTransaction(productID: "another.product", isNonConsumable: true))
        precondition(!ProStore.isProTransaction(productID: ProStore.productID, isNonConsumable: false))
        precondition(ProStore.idleStatus(owned: true, productAvailable: false) == .owned)
        precondition(ProStore.idleStatus(owned: true, productAvailable: true) == .owned)
        precondition(ProStore.idleStatus(owned: false, productAvailable: true) == .available)
        precondition(ProStore.idleStatus(owned: false, productAvailable: false) == .unavailable)
        print("Commerce decision checks passed")
    }
}
