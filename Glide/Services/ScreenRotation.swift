import UIKit

@MainActor enum ScreenRotation {
    static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    }
    static func request(_ orientation: UIInterfaceOrientationMask, onError: @escaping (String) -> Void) {
        guard let scene = activeScene else { onError("当前窗口暂时不能旋转。"); return }
        let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
        root?.setNeedsUpdateOfSupportedInterfaceOrientations()
        var presented = root
        while let next = presented?.presentedViewController { presented = next }
        presented?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in
            Task { @MainActor in onError("当前窗口不支持此方向，请尝试全屏显示后旋转。") }
        }
    }
    static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }
}
