# CommerceLab（本地交易实验）

这是独立的 iOS 测试 App，直接编译 `Glide/Services/ProStore.swift`，不把支付代码接入 Glide 正式目标。商品、价格和名称仅在 `CommerceLabTests/Glide.storekit` 中供本地测试使用，不是已配置的商店商品或定价。只在模拟器上提供购买按钮；不要修改为正式 App 的 bundle ID，也不要用于发布。

在 Xcode 中打开 `CommerceLab.xcodeproj`，选择共享的 `CommerceLab` scheme 和 iPhone 模拟器。Run scheme 已指定本地 StoreKit 配置；确认 Xcode 的 Scheme > Run > Options 中确实选中 `Glide.storekit`，并确认交易对话框标明为 Xcode 测试后再尝试。Test scheme 运行 `CommerceLabTests`：测试会清除该测试 App 的本地 StoreKit 测试交易，执行购买、恢复和模拟退款；不要对有需要保留的测试交易运行。测试应串行运行，不能与其他 StoreKit 测试并发共享测试环境。

命令行示例：`xcodebuild test -project CommerceLab.xcodeproj -scheme CommerceLab -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO`。模拟器名称要与本机实际设备一致。

2026-11-02 在 Xcode 27.1、iOS 26.3 模拟器上的命令行测试曾在商品加载阶段失败（`unavailable`），未到购买、恢复和退款步骤。macOS 无 App 宿主的实验还出现 StoreKit 测试服务配置错误。尚不能断言根因；请在 Xcode GUI 中核对配置并复测，记录测试环境与结果。不要把这个失败或能编译当作购买验证通过。

尚需测试：取消、待批准、不可用和验证失败、重复购买、重启、恢复、退款撤销、离线及跨设备；还需用 App Store Connect 正确配置测试商品和沙盒账号，在真机完成沙盒交易。Xcode 本地交易与 Apple 沙盒或正式销售是不同环境。
