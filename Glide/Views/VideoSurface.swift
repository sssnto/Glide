import SwiftUI
import AVFoundation

struct VideoSurface: UIViewRepresentable {
    let presentation: PlaybackPresentation
    var onLayer: (AVPlayerLayer?) -> Void
    let identity: String
    var title: String
    var frameReady: Bool
    var locked: Bool
    var filled: Bool
    var onSwipe: (Int) -> Void
    var onToggle: () -> Void
    var onSeek: (Double) -> Void
    var onSpeedPreset: (Float) -> Void
    var onHUD: (String) -> Void
    var subtitleSession: SubtitleSession? = nil
    var secondarySubtitleSession: SubtitleSession? = nil
    var subtitleClock: (() -> Double?)? = nil
    var subtitleVideoMatrix = ""
    var subtitleSourceSize = CGSize(width: 1920, height: 1080)
    func makeUIView(context: Context) -> GestureVideoView { let view = GestureVideoView(); updateUIView(view, context: context); return view }
    func updateUIView(_ view: GestureVideoView, context: Context) {
        switch presentation {
        case .native(let player):
            view.setCustomView(nil)
            if view.videoLayer.player !== player { view.videoLayer.player = player }
            onLayer(view.videoLayer)
        case .custom(let surface):
            view.videoLayer.player = nil
            view.setCustomView(surface)
            onLayer(nil)
        }
        view.accessibilityLabel = "视频画面，" + title + (frameReady ? "，已显示画面" : "，正在准备画面")
        view.onSwipe = onSwipe; view.onToggle = onToggle; view.onSeek = onSeek
        view.onSpeedPreset = onSpeedPreset; view.onHUD = onHUD
        view.locked = locked
        if view.identity != identity { view.identity = identity; view.resetZoom() }
        view.videoLayer.videoGravity = filled ? .resizeAspectFill : .resizeAspect
        view.filled = view.videoLayer.player != nil && filled; view.subtitleSourceSize = subtitleSourceSize
        for (canvas, session) in [(view.assCanvas, subtitleSession), (view.secondaryASSCanvas, secondarySubtitleSession)] {
            canvas.videoMatrix = subtitleVideoMatrix; canvas.clock = subtitleClock; canvas.sourceSize = subtitleSourceSize; canvas.delay = session?.delay ?? 0
            canvas.onStatus = { [weak session] warning in session?.message = warning }
            canvas.configure(session?.ass)
        }
    }
}

final class GestureVideoView: UIView, UIGestureRecognizerDelegate {
    let videoLayer = AVPlayerLayer()
    let assCanvas = ASSCanvasView()
    let secondaryASSCanvas = ASSCanvasView()
    var filled = false
    var subtitleSourceSize = CGSize(width: 1920, height: 1080)
    private var customView: UIView?
    var identity = ""
    var locked = false
    var onSwipe: ((Int) -> Void)?
    var onToggle: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onSpeedPreset: ((Float) -> Void)?
    var onHUD: ((String) -> Void)?
    private var zoom: CGFloat = 1
    private var originZoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var originOffset = CGPoint.zero
    private var axis: Int = 0
    private var panningZoomedContent = false
    private var twoPanLastTranslation = CGPoint.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; clipsToBounds = true; layer.addSublayer(videoLayer)
        for canvas in [assCanvas, secondaryASSCanvas] {
            addSubview(canvas)
            canvas.videoRect = { [weak self] in self?.subtitleRect ?? .zero }
            canvas.onRender = { [weak self] in self?.updateAccessibilityValue() }
        }
        let twoTap = UITapGestureRecognizer(target: self, action: #selector(twoTapped)); twoTap.numberOfTouchesRequired = 2
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:))); pan.maximumNumberOfTouches = 1
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.allowableMovement = 16
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let twoPan = UIPanGestureRecognizer(target: self, action: #selector(twoPanned(_:))); twoPan.minimumNumberOfTouches = 2; twoPan.maximumNumberOfTouches = 2
        for gesture in [twoTap, pan, longPress, pinch, twoPan] { gesture.delegate = self; addGestureRecognizer(gesture) }
        isAccessibilityElement = true
        accessibilityLabel = "视频画面"
        accessibilityIdentifier = "player.canvas"
        accessibilityHint = "轻点显示播放控制，上下滑动切换视频，左右滑动切换倍速，长按左侧快退、右侧快进。"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); applyTransform() }
    func setCustomView(_ view: UIView?) {
        guard customView !== view else { return }
        customView?.removeFromSuperview(); customView = view
        if let view { view.isUserInteractionEnabled = false; insertSubview(view, at: 0) }
        videoLayer.isHidden = view != nil
        setNeedsLayout()
    }
    private var subtitleRect: CGRect {
        if customView == nil, !videoLayer.videoRect.isEmpty { return videoLayer.videoRect }
        let size = subtitleSourceSize
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = filled ? max(bounds.width / size.width, bounds.height / size.height) : min(bounds.width / size.width, bounds.height / size.height)
        return CGRect(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2, width: size.width * scale, height: size.height * scale)
    }
    func resetZoom() { zoom = 1; offset = .zero; panningZoomedContent = false; applyTransform() }
    private func applyTransform() {
        updateAccessibilityValue()
        accessibilityHint = zoom > 1.001
            ? "拖动画面查看放大区域，双指捏合恢复原大小。"
            : "轻点显示播放控制，上下滑动切换视频，左右滑动切换倍速，长按左侧快退、右侧快进。"
        let xLimit = bounds.width * (zoom - 1) / 2
        let yLimit = bounds.height * (zoom - 1) / 2
        offset.x = max(-xLimit, min(xLimit, offset.x)); offset.y = max(-yLimit, min(yLimit, offset.y))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let transform = CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: zoom, y: zoom)
        if let customView {
            // UIView's setter lays out the decoder's autoresizing drawable.
            // Updating only layer.frame leaves that child at its initial zero size.
            customView.transform = .identity
            customView.frame = bounds
            customView.transform = transform
        } else {
            videoLayer.setAffineTransform(.identity); videoLayer.frame = bounds
            videoLayer.setAffineTransform(transform)
        }
        for canvas in [assCanvas, secondaryASSCanvas] {
            canvas.transform = .identity; canvas.frame = bounds; canvas.transform = transform
        }
        CATransaction.commit()
    }
    private func updateAccessibilityValue() {
        let rendered = assCanvas.presentedLayerCount + secondaryASSCanvas.presentedLayerCount
        accessibilityValue = String(format: "缩放 %.1f 倍", zoom) + (rendered > 0 ? "，ASS已渲染 \(rendered) 层" : "")
    }
    @objc private func twoTapped() { if !locked { onToggle?() } }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard !locked else { return }
        if gesture.state == .began { originZoom = zoom }
        zoom = max(1, min(4, originZoom * gesture.scale))
        if gesture.state == .ended && zoom < 1.05 { zoom = 1; offset = .zero }
        applyTransform()
        onHUD?(String(format: "画面 %.1f×", zoom))
    }
    @objc private func twoPanned(_ gesture: UIPanGestureRecognizer) {
        guard !locked else { return }
        if gesture.state == .began { twoPanLastTranslation = .zero }
        let translation = gesture.translation(in: self)
        let delta = CGPoint(x: translation.x - twoPanLastTranslation.x, y: translation.y - twoPanLastTranslation.y)
        twoPanLastTranslation = translation
        guard zoom > 1 else { return }
        offset = CGPoint(x: offset.x + delta.x, y: offset.y + delta.y)
        applyTransform()
    }
    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard !locked, zoom <= 1, gesture.state == .began else { return }
        let interval = PlaybackPreferences.seekInterval
        let seconds = gesture.location(in: self).x < bounds.midX ? -interval : interval
        onSeek?(seconds)
        onHUD?(seconds > 0 ? "快进 \(Int(interval)) 秒" : "快退 \(Int(interval)) 秒")
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard !locked else { return }
        let translation = gesture.translation(in: self)
        if gesture.state == .began {
            axis = 0
            panningZoomedContent = zoom > 1
            if panningZoomedContent { originOffset = offset }
        }
        if panningZoomedContent {
            if gesture.state == .changed {
                offset = CGPoint(x: originOffset.x + translation.x, y: originOffset.y + translation.y)
                applyTransform()
            }
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                panningZoomedContent = false
            }
            return
        }
        guard zoom <= 1 else { return }
        if axis == 0 && max(abs(translation.x), abs(translation.y)) > 12 { axis = abs(translation.x) > abs(translation.y) * 1.2 ? 1 : 2 }
        if gesture.state == .ended {
            if axis == 2, abs(translation.y) > 65 { onSwipe?(translation.y < 0 ? 1 : -1) }
            if axis == 1, abs(translation.x) > 65 {
                let speed: Float = translation.x > 0 ? 2 : 1
                onSpeedPreset?(speed); onHUD?(speed == 1 ? "正常速度" : "2× 播放")
            }
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer && (otherGestureRecognizer as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2) || (otherGestureRecognizer is UIPinchGestureRecognizer && (gestureRecognizer as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2)
    }
}
