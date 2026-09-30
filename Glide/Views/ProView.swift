import SwiftUI

struct ProView: View {
    @State private var store = ProStore.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Glide Pro").font(.largeTitle.bold())
                Text(ProStore.paidFeaturesEnabled
                     ? "基础播放、播放恢复和续播永久免费。Pro 一次买断，解锁新建离线下载和个性化设置。"
                     : "商业版本正在准备中。基础播放、播放恢复和续播继续开放使用；测试期间离线下载和个性化设置也保持开放，无需付费。")
                    .foregroundStyle(.secondary)
                GroupBox("购买状态") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(statusText)
                        if let product = store.product {
                            Text("App Store 项目：\(product.displayName) · \(product.displayPrice)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let message = store.message {
                            Text(message).font(.callout).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if ProStore.paidFeaturesEnabled, let product = store.product, store.status != .owned {
                    Button("购买 Glide Pro · \(product.displayPrice)") { Task { await store.purchase() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.status == .purchasing || store.status == .pending)
                        .accessibilityIdentifier("pro.purchase")
                }
                Button("恢复购买") { Task { await store.restore() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pro.restore")
                Text("恢复购买由 Apple 验证。取消、待批准或验证失败均不会启用权益；退款或撤销后，权益会随 App Store 状态更新。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 640, alignment: .leading)
        }.navigationTitle("Glide Pro")
    }

    private var statusText: String {
        switch store.status {
        case .loading: "正在检查购买状态…"
        case .unavailable: "购买项目暂不可用"
        case .available: "尚未购买"
        case .purchasing: "正在购买…"
        case .pending: "等待购买批准"
        case .owned: "已拥有 Glide Pro"
        }
    }
}
