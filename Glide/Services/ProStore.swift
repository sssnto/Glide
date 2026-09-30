import Foundation
import Observation
import StoreKit

@MainActor @Observable
final class ProStore {
    static let shared = ProStore()
    static let productID = "com.songpeng.glide.pro.lifetime"
    // Monetization is deferred; keep every existing feature available in all builds.
    static let paidFeaturesEnabled = false

    enum Status: Equatable {
        case loading
        case unavailable
        case available
        case purchasing
        case pending
        case owned
    }

    private(set) var status: Status = .loading
    private(set) var product: Product?
    private(set) var message: String?
    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = result {
                    await self.refreshEntitlement()
                    await transaction.finish()
                } else {
                    self.message = "购买凭证未通过系统验证，权益尚未启用。"
                }
            }
        }
        Task { await load() }
    }

    var canUsePaidFeatures: Bool { !Self.paidFeaturesEnabled || status == .owned }

    func load() async {
        await refreshEntitlement()
        do {
            product = try await Product.products(for: [Self.productID]).first { $0.id == Self.productID && $0.type == .nonConsumable }
            if product == nil && status != .owned { status = .unavailable }
        } catch {
            if status != .owned { status = .unavailable }
            message = "暂时无法从 App Store 获取购买项目，请稍后重试。"
        }
    }

    func refreshEntitlement() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.productID,
                  transaction.productType == .nonConsumable,
                  transaction.revocationDate == nil else { continue }
            owned = true
        }
        status = owned ? .owned : (product == nil ? .loading : .available)
    }

    func purchase() async {
        guard let product, status != .purchasing, status != .owned else { return }
        status = .purchasing
        message = nil
        do {
            switch try await product.purchase() {
            case .success(let result):
                switch result {
                case .verified(let transaction):
                    await refreshEntitlement()
                    await transaction.finish()
                case .unverified:
                    status = .available
                    message = "购买凭证未通过系统验证，未启用权益。"
                }
            case .pending:
                status = .pending
                message = "购买正在等待批准；批准后会自动更新权益。"
            case .userCancelled:
                status = .available
            @unknown default:
                status = .available
                message = "购买尚未完成，请稍后重试。"
            }
        } catch {
            await refreshEntitlement()
            message = "购买未完成：\(error.localizedDescription)"
        }
    }

    func restore() async {
        message = nil
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            message = status == .owned ? "已恢复 Glide Pro。" : "当前 Apple 账户没有可恢复的 Glide Pro 购买。"
        } catch {
            message = "恢复失败，请检查 Apple 账户与网络后重试。"
        }
    }
}
