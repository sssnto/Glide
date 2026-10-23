import UIKit
import AVFoundation

/// Shares the video surface's transform, so authored positions track fit/fill, rotation and pinch.
@MainActor final class ASSCanvasView: UIView {
    var onRender: (() -> Void)?
    var onStatus: ((String?) -> Void)?
    var clock: (() -> Double?)?
    var videoMatrix = ""
    var sourceSize = CGSize(width: 1920, height: 1080)
    var videoRect: (() -> CGRect)?
    var delay = 0.0
    private var subtitleID: UUID?
    private var worker: ASSRenderWorker?
    private var preparation: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var displayLink: CADisplayLink?
    private let caption = UIImageView()
    private var lastTime: Double?
    private var lastSize = CGSize.zero
    private var lastRect = CGRect.zero
    private var imageRect = CGRect.zero
    private var generation = UUID()
    private(set) var renderedImageCount = 0
    var presentedLayerCount: Int { !isHidden && !caption.isHidden && caption.image != nil ? renderedImageCount : 0 }
    @MainActor private final class TickTarget: NSObject {
        weak var owner: ASSCanvasView?
        @objc func tick() { owner?.tick() }
    }
    private let target = TickTarget()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; clipsToBounds = true
        caption.contentMode = .scaleToFill; addSubview(caption); target.owner = self
        accessibilityIdentifier = "player.subtitle.ass"
        isAccessibilityElement = false; accessibilityLabel = "ASS 原样字幕"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ subtitle: ASSSubtitle?) {
        guard subtitleID != subtitle?.id else { return }
        generation = UUID(); subtitleID = subtitle?.id
        stopDisplayLink()
        preparation?.cancel(); pending?.cancel(); pending = nil; worker = nil
        caption.image = nil; lastTime = nil; lastSize = .zero; renderedImageCount = 0
        onRender?()
        accessibilityValue = subtitle == nil ? "关闭" : "正在准备"
        isHidden = subtitle == nil
        guard let subtitle else { stopDisplayLink(); return }
        let token = generation
        preparation = Task { [weak self] in
            do {
                let work = Task.detached(priority: .userInitiated) { try await ASSRenderPreparation.shared.make(subtitle) }
                let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, let self, generation == token else { return }
                worker = value
                let missing = value.missingFonts
                if !missing.isEmpty { onStatus?("原字幕字体未提供：" + missing.joined(separator: "、") + "。当前使用替代字体；导入原字体后即可还原。") }
                else { onStatus?(subtitle.fontWarning) }
                accessibilityValue = "已就绪"; updateDisplayLink(); tick()
            } catch {
                guard !Task.isCancelled, let self, generation == token else { return }
                accessibilityValue = "渲染失败"; onStatus?("ASS 原样渲染失败，请重新选择字幕。")
            }
        }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); updateDisplayLink() }
    override func layoutSubviews() { super.layoutSubviews(); tick() }
    private func updateDisplayLink() {
        guard window != nil, subtitleID != nil, worker != nil else { stopDisplayLink(); return }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: target, selector: #selector(TickTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common); displayLink = link
    }
    private func stopDisplayLink() { displayLink?.invalidate(); displayLink = nil }
    private func tick() {
        guard pending == nil, let worker, let time = clock?(), time.isFinite, let rect = videoRect?(), !rect.isEmpty,
              rect.width.isFinite, rect.height.isFinite else {
            if clock?() == nil { setCaptionHidden(true) }
            return
        }
        setCaptionHidden(false)
        if rect != lastRect, lastSize.width > 0, lastSize.height > 0 {
            positionCaption(rect: rect, size: lastSize)
        }
        lastRect = rect
        // Rasterize at display density, bounded independently of a 4K/8K source.
        let density = window?.screen.scale ?? 2
        let scale = min(density, 2048 / max(rect.width, rect.height))
        let size = CGSize(width: max(1, (rect.width * scale).rounded()), height: max(1, (rect.height * scale).rounded()))
        let now = time - delay
        guard lastTime != now || size != lastSize else { return }
        let token = generation, oldTime = lastTime
        // Do not leave a pre-seek frame visible while the new frame is being shaped.
        if let oldTime, abs(oldTime - now) > 0.5 { setCaptionHidden(true) }
        lastTime = now; lastSize = size
        let source = sourceSize, matrix = videoMatrix
        pending = Task { [weak self] in
            let frame = await worker.render(time: now, width: Int(size.width), height: Int(size.height), source: source, matrix: matrix)
            guard !Task.isCancelled, let self, generation == token else { return }
            pending = nil
            if let current = clock?() { setCaptionHidden(abs(current - delay - now) > 0.5) }
            else { setCaptionHidden(true) }
            guard frame.changed else { onRender?(); return }
            caption.image = frame.image; renderedImageCount = Int(frame.imageCount)
            onRender?()
            imageRect = frame.rect
            positionCaption(rect: rect, size: size)
            accessibilityValue = frame.image == nil ? "当前无字幕" : "已渲染 \(frame.imageCount) 层"
        }
    }
    private func setCaptionHidden(_ value: Bool) {
        guard caption.isHidden != value else { return }
        caption.isHidden = value; onRender?()
    }
    private func positionCaption(rect: CGRect, size: CGSize) {
        let r = imageRect
        caption.frame = CGRect(x: rect.minX + r.minX / size.width * rect.width, y: rect.minY + r.minY / size.height * rect.height,
            width: r.width / size.width * rect.width, height: r.height / size.height * rect.height)
    }
    deinit { displayLink?.invalidate(); preparation?.cancel(); pending?.cancel() }
}
