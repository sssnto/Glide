import SwiftUI
import AVFoundation

@MainActor final class VideoInteractionState {
    let videoLayer = AVPlayerLayer()
    var identity = ""
    var viewportSize = CGSize.zero
    var zoom: CGFloat = 1
    var offset = CGPoint.zero
}

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
    var interactionState: VideoInteractionState? = nil
    var evidenceContext = ""
    var quarterTurn = VideoQuarterTurn.original
    func makeUIView(context: Context) -> GestureVideoView { let view = GestureVideoView(); updateUIView(view, context: context); return view }
    func updateUIView(_ view: GestureVideoView, context: Context) {
        if let interactionState { view.useInteraction(interactionState) }
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
        view.locked = locked; view.evidenceContext = evidenceContext; view.updateAccessibleActions()
        view.setQuarterTurn(quarterTurn)
        if view.interaction.identity != identity { view.interaction.identity = identity; view.resetZoom() }
        view.identity = identity
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
    var videoLayer: AVPlayerLayer { interaction.videoLayer }
    private let contentView = UIView()
    let assCanvas = ASSCanvasView()
    let secondaryASSCanvas = ASSCanvasView()
    var filled = false
    private(set) var quarterTurn = VideoQuarterTurn.original
    func setQuarterTurn(_ turn: VideoQuarterTurn) {
        guard quarterTurn != turn else { return }
        quarterTurn=turn;resetZoom();setNeedsLayout()
    }
    var subtitleSourceSize = CGSize(width: 1920, height: 1080)
    private var customView: UIView?
    var identity = ""
    var locked = false
    var onSwipe: ((Int) -> Void)?
    var onToggle: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onSpeedPreset: ((Float) -> Void)?
    var onHUD: ((String) -> Void)?
    var interaction = VideoInteractionState()
    var evidenceContext = "" { didSet { updateAccessibilityValue() } }
    private var viewportSize: CGSize { get { interaction.viewportSize } set { interaction.viewportSize = newValue } }
    private var zoom: CGFloat { get { interaction.zoom } set { interaction.zoom = newValue } }
    private var originZoom: CGFloat = 1
    private var offset: CGPoint { get { interaction.offset } set { interaction.offset = newValue } }
    private var originOffset = CGPoint.zero
    private var axis: Int = 0
    private var panningZoomedContent = false
    private var twoPanLastTranslation = CGPoint.zero
    private var zoomIndicator: UILabel?
    private var zoomIndicatorTask: Task<Void, Never>?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black; clipsToBounds = true
        contentView.isUserInteractionEnabled = false
        addSubview(contentView); contentView.layer.addSublayer(videoLayer)
        for canvas in [assCanvas, secondaryASSCanvas] {
            contentView.addSubview(canvas)
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
    func useInteraction(_ state: VideoInteractionState) {
        guard interaction !== state else { return }
        if videoLayer.superlayer === contentView.layer { videoLayer.removeFromSuperlayer() }
        interaction = state
        contentView.layer.addSublayer(videoLayer)
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        if viewportSize != bounds.size {
            if viewportSize.width > 0, viewportSize.height > 0 {
                let adjusted = VideoViewport.offset(CGSize(width: offset.x, height: offset.y), from: viewportSize, to: bounds.size, zoom: Double(zoom))
                offset = CGPoint(x: adjusted.width, y: adjusted.height)
                for gesture in gestureRecognizers ?? [] where gesture.state == .began || gesture.state == .changed {
                    gesture.isEnabled = false; gesture.isEnabled = true
                }
                axis = 0; panningZoomedContent = false; originOffset = offset; originZoom = zoom; twoPanLastTranslation = .zero
            }
            viewportSize = bounds.size
        }
        layoutContent()
        applyTransform()
        layoutZoomIndicator()
    }
    func updateAccessibleActions() {
        guard !locked else { accessibilityCustomActions = []; return }
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "播放或暂停", target: self, selector: #selector(accessibleToggle)),
            UIAccessibilityCustomAction(name: "下一个视频", target: self, selector: #selector(accessibleNext)),
            UIAccessibilityCustomAction(name: "上一个视频", target: self, selector: #selector(accessiblePrevious)),
            UIAccessibilityCustomAction(name: "快进", target: self, selector: #selector(accessibleForward)),
            UIAccessibilityCustomAction(name: "快退", target: self, selector: #selector(accessibleBackward)),
            UIAccessibilityCustomAction(name: "恢复画面大小", target: self, selector: #selector(accessibleReset))
        ]
    }
    @objc private func accessibleToggle() -> Bool { guard !locked else { return false }; onToggle?(); return true }
    @objc private func accessibleNext() -> Bool { guard !locked else { return false }; onSwipe?(1); return true }
    @objc private func accessiblePrevious() -> Bool { guard !locked else { return false }; onSwipe?(-1); return true }
    @objc private func accessibleForward() -> Bool { guard !locked else { return false }; onSeek?(PlaybackPreferences.seekInterval); return true }
    @objc private func accessibleBackward() -> Bool { guard !locked else { return false }; onSeek?(-PlaybackPreferences.seekInterval); return true }
    @objc private func accessibleReset() -> Bool { guard !locked else { return false }; resetZoom(); return true }
    func setCustomView(_ view: UIView?) {
        videoLayer.isHidden = view != nil
        guard customView !== view else { return }
        customView?.removeFromSuperview(); customView = view
        if let view { view.isUserInteractionEnabled = false; contentView.insertSubview(view, at: 0) }
        setNeedsLayout()
    }
    private var subtitleRect: CGRect {
        if customView == nil, !videoLayer.videoRect.isEmpty { return videoLayer.videoRect }
        let size = subtitleSourceSize
        guard size.width > 0, size.height > 0 else { return .zero }
        let viewport=contentView.bounds.size
        let scale = filled ? max(viewport.width / size.width, viewport.height / size.height) : min(viewport.width / size.width, viewport.height / size.height)
        return CGRect(x: (viewport.width - size.width * scale) / 2, y: (viewport.height - size.height * scale) / 2, width: size.width * scale, height: size.height * scale)
    }
    func resetZoom() { zoom = 1; offset = .zero; panningZoomedContent = false; applyTransform() }
    private func layoutContent() {
        // Decoder and libass geometry follows the viewport, never the pinch scale.
        // Use bounds/center: the content host can already have a non-identity transform.
        let size=quarterTurn.swapsAxes ? CGSize(width:bounds.height,height:bounds.width) : bounds.size
        let rect = CGRect(origin: .zero, size: size)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if contentView.bounds != rect { contentView.bounds = rect }
        if contentView.center != center { contentView.center = center }
        if videoLayer.bounds != rect { videoLayer.bounds = rect }
        let videoCenter = CGPoint(x: rect.midX, y: rect.midY)
        if videoLayer.position != videoCenter { videoLayer.position = videoCenter }
        for view in [customView, assCanvas, secondaryASSCanvas].compactMap({ $0 }) {
            // UIView geometry setters also resize VLCKit's autoresizing drawable.
            if view.bounds != rect { view.bounds = rect }
            if view.center != videoCenter { view.center = videoCenter }
        }
        CATransaction.commit()
    }
    private func applyTransform() {
        updateAccessibilityValue()
        accessibilityHint = zoom > 1.001
            ? "拖动画面查看放大区域，双指捏合恢复原大小。"
            : "轻点显示播放控制，上下滑动切换视频，左右滑动切换倍速，长按左侧快退、右侧快进。"
        let xLimit = bounds.width * (zoom - 1) / 2
        let yLimit = bounds.height * (zoom - 1) / 2
        offset.x = max(-xLimit, min(xLimit, offset.x)); offset.y = max(-yLimit, min(yLimit, offset.y))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let transform = CGAffineTransform(translationX: offset.x, y: offset.y).rotated(by:CGFloat(quarterTurn.degrees) * .pi/180).scaledBy(x: zoom, y: zoom)
        if contentView.transform != transform { contentView.transform = transform }
        CATransaction.commit()
    }
    private func updateAccessibilityValue() {
        let rendered = assCanvas.presentedLayerCount + secondaryASSCanvas.presentedLayerCount
        let value = String(format: "缩放 %.1f 倍", zoom) + "，方向 \(quarterTurn.degrees)°" + (rendered > 0 ? "，ASS已渲染 \(rendered) 层" : "") + evidenceContext
        if accessibilityValue != value { accessibilityValue = value }
    }
    @objc private func twoTapped() { if !locked { onToggle?() } }
    func setZoomScale(_ value: CGFloat) {
        guard value.isFinite else { return }
        zoom = max(1, min(4, value))
        applyTransform()
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard !locked else { return }
        if gesture.state == .began { originZoom = zoom; zoomIndicatorTask?.cancel() }
        setZoomScale(originZoom * gesture.scale)
        if gesture.state == .ended && zoom < 1.05 { resetZoom() }
        if gesture.state == .cancelled || gesture.state == .failed { zoomIndicator?.isHidden = true; return }
        showZoomIndicator()
        if gesture.state == .ended {
            zoomIndicatorTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                self?.zoomIndicator?.isHidden = true
            }
        }
    }
    private func showZoomIndicator() {
        if zoomIndicator == nil {
            let label = UILabel()
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.textColor = .white; label.textAlignment = .center
            label.backgroundColor = UIColor.black.withAlphaComponent(0.65)
            label.layer.cornerRadius = 20; label.clipsToBounds = true
            label.isAccessibilityElement = false; label.isUserInteractionEnabled = false
            addSubview(label); zoomIndicator = label; layoutZoomIndicator()
        }
        let text = String(format: "画面 %.1f×", zoom)
        if zoomIndicator?.text != text { zoomIndicator?.text = text }
        zoomIndicator?.isHidden = false
    }
    private func layoutZoomIndicator() {
        guard let zoomIndicator else { return }
        zoomIndicator.bounds = CGRect(x: 0, y: 0, width: min(120, max(0, bounds.width - 32)), height: 40)
        zoomIndicator.center = CGPoint(x: bounds.midX, y: bounds.midY)
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
    deinit { zoomIndicatorTask?.cancel() }
}
