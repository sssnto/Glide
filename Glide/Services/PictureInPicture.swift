import AVKit
import Observation

@MainActor @Observable
final class PictureInPicture: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    private(set) var possible = false
    private(set) var active = false
    var message: String?
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private weak var layer: AVPlayerLayer?
    func attach(_ layer: AVPlayerLayer) {
        guard self.layer !== layer, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        self.layer = layer
        controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        observation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.possible = possible }
        }
    }
    func toggle() {
        message = nil
        if active { controller?.stopPictureInPicture() }
        else if possible { controller?.startPictureInPicture() }
        else { message = "此设备或当前播放流暂不能开启画中画。" }
    }
    func stop() { controller?.stopPictureInPicture() }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { active = true }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { active = false }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { active = false; message = "画中画未能启动，请待画面出现后重试。" }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
}
