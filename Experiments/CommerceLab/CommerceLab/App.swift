import SwiftUI

@main struct CommerceLabApp: App {
    @State private var store = ProStore.shared
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("Glide StoreKit 本地测试").font(.title)
                Text("仅用于 Xcode StoreKit 测试，不连接正式销售。")
                Text(String(describing: store.status))
                #if targetEnvironment(simulator)
                if let product = store.product {
                    Text("\(product.displayName) · \(product.displayPrice)")
                    Button("测试购买") { Task { await store.purchase() } }.disabled(store.status != .available)
                }
                #endif
                Button("重新加载") { Task { await store.load() } }
                Button("测试恢复") { Task { await store.restore() } }
                if let message = store.message { Text(message) }
            }.padding()
        }
    }
}
