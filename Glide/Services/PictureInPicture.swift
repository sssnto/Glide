import AVKit
import Observation

@MainActor @Observable
final class PictureInPicture: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    private(set) var possible = false
    private(set) var active = false
    private(set) var starting = false
    var keepsPlaybackInBackground: Bool { active || starting }
    var message: String?
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private weak var layer: AVPlayerLayer?
    @ObservationIgnored var onEvent: ((String) -> Void)?
#if DEBUG
    var diagnostics: [String: Any] {
        ["supported": supported, "hasController": controller != nil,
         "observedPossible": possible, "controllerPossible": controller?.isPictureInPicturePossible ?? false,
         "pipLayerAttached": layer?.superlayer != nil, "pipLayerReady": layer?.isReadyForDisplay ?? false,
         "pipPlayerItemReady": layer?.player?.currentItem?.status == .readyToPlay,
         "audioCategory": AVAudioSession.sharedInstance().category.rawValue]
    }
#endif
    func attach(_ layer: AVPlayerLayer) {
        guard self.layer !== layer, supported else { return }
        self.layer = layer
        controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        observation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self, weak controller] in
                guard let self, let controller, self.controller === controller else { return }
                self.possible = possible
            }
        }
    }
    func detach() {
        if active || starting { onEvent?("pip_detach") }
        controller?.stopPictureInPicture(); observation = nil; controller?.delegate = nil
        controller = nil; layer = nil; possible = false; active = false; starting = false
    }
    func toggle() {
        guard !starting else { return }
        message = nil
        if active { controller?.stopPictureInPicture() }
        else if possible, let controller {
            // Protect playback if the app backgrounds before AVKit finishes its animation.
            starting = true
            onEvent?("pip_start_requested")
            controller.startPictureInPicture()
        }
        else { message = "此设备或当前播放流暂不能开启画中画。" }
    }
    func stop() {
        if active || starting { onEvent?("pip_stop_requested") }
        controller?.stopPictureInPicture()
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        active = true; starting = false
        onEvent?("pip_started")
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        active = false; starting = false
        onEvent?("pip_stopped")
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard controller === pictureInPictureController else { return }
        active = false; starting = false; message = "画中画未能启动，请待画面出现后重试。"
        onEvent?("pip_start_failed")
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
}
