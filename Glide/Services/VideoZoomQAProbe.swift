#if DEBUG
import SwiftUI
import AVFoundation

/// Measures UIKit geometry work, not decoder FPS. No saved accounts or private media.
struct VideoZoomQAProbe: View {
    @State private var status = "正在验证"
    var body: some View {
        Text(status).accessibilityIdentifier("zoom.probe.status")
            .task {
                let report = VideoZoomQA.run()
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoZoomQA.json")
                do {
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                    status = report["passed"] as? Bool == true ? "验证通过" : "验证失败"
                } catch { status = "报告写入失败" }
            }
    }
}

@MainActor private final class ZoomDrawableProbe: UIView {
    var frameWrites = 0
    var boundsWrites = 0
    var transformWrites = 0
    override var frame: CGRect { didSet { frameWrites += 1 } }
    override var bounds: CGRect { didSet { boundsWrites += 1 } }
    override var transform: CGAffineTransform { didSet { transformWrites += 1 } }
    func resetCounts() { frameWrites = 0; boundsWrites = 0; transformWrites = 0 }
}

@MainActor enum VideoZoomQA {
    static func run() -> [String: Any] {
        var checks = [String: Bool]()
        let view = GestureVideoView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let state = VideoInteractionState()
        view.useInteraction(state)
        let drawable = ZoomDrawableProbe()
        let child = UIView(); child.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        drawable.addSubview(child)
        view.setCustomView(drawable); view.layoutIfNeeded()
        child.frame = drawable.bounds
        let initialBounds = drawable.bounds, initialChildBounds = child.bounds
        drawable.resetCounts()
        let start = CACurrentMediaTime()
        for step in 0..<480 {
            view.setZoomScale(1 + 3 * CGFloat(step < 240 ? step : 479 - step) / 239)
            view.layoutIfNeeded()
        }
        let elapsed = (CACurrentMediaTime() - start) * 1000
        let writes: [String: Int] = ["frame": drawable.frameWrites, "bounds": drawable.boundsWrites, "transform": drawable.transformWrites]
        checks["pinch-does-not-relayout-decoder"] = writes.values.allSatisfy { $0 == 0 }
        checks["decoder-and-autoresizing-child-keep-viewport"] = drawable.bounds == initialBounds && child.bounds == initialChildBounds
        view.setZoomScale(3)
        let point = CGPoint(x: 60, y: 90)
        checks["ass-and-video-stay-aligned"] = drawable.convert(point, to: view) == view.assCanvas.convert(point, to: view)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 400); view.layoutIfNeeded()
        checks["real-resize-updates-decoder-and-child"] = drawable.bounds.size == view.bounds.size && child.bounds.size == view.bounds.size
        checks["real-resize-keeps-zoom"] = state.zoom == 3
        let player = AVPlayer(), layer = view.videoLayer
        view.setCustomView(nil); layer.player = player; view.layoutIfNeeded()
        let nativeBounds = layer.bounds
        for step in 0..<120 { view.setZoomScale(1 + CGFloat(step % 4)) }
        checks["native-layer-player-and-bounds-stable"] = view.videoLayer === layer && layer.player === player && layer.bounds == nativeBounds
        checks["native-and-ass-stay-aligned"] = layer.convert(point, to: view.layer) == view.assCanvas.convert(point, to: view)
        view.setZoomScale(.infinity)
        checks["invalid-scale-rejected"] = state.zoom.isFinite
        view.resetZoom()
        checks["reset-restores-unit-scale-and-offset"] = state.zoom == 1 && state.offset == .zero
        let rotated=GestureVideoView(frame:CGRect(x:0,y:0,width:400,height:800))
        let rotatedDrawable=ZoomDrawableProbe(),rotatedPlayer=AVPlayer(),retainedLayer=rotated.videoLayer
        rotated.setCustomView(rotatedDrawable);retainedLayer.player=rotatedPlayer;rotated.layoutIfNeeded()
        rotated.setQuarterTurn(.clockwise);rotated.layoutIfNeeded()
        checks["rotation-swaps-decoder-viewport"]=rotatedDrawable.bounds.size==CGSize(width:800,height:400)
        checks["rotation-retains-layer-and-player"]=rotated.videoLayer === retainedLayer && retainedLayer.player === rotatedPlayer
        checks["rotation-keeps-ass-with-video"]=rotatedDrawable.convert(point,to:rotated)==rotated.assCanvas.convert(point,to:rotated)
        rotatedDrawable.resetCounts()
        for step in 0..<120 { rotated.setZoomScale(1+CGFloat(step%4));rotated.layoutIfNeeded() }
        checks["rotated-pinch-does-not-relayout-decoder"]=rotatedDrawable.frameWrites==0 && rotatedDrawable.boundsWrites==0 && rotatedDrawable.transformWrites==0
        rotated.setQuarterTurn(.original);rotated.layoutIfNeeded()
        checks["rotation-reset-restores-viewport"]=rotatedDrawable.bounds.size==CGSize(width:400,height:800)
        return ["passed": checks.values.allSatisfy { $0 }, "checks": checks,
                "zoomUpdates": 480, "decoderGeometryWrites": writes, "synchronousLoopMilliseconds": elapsed,
                "scope": "Actual GestureVideoView and UIKit autoresizing; geometry regression, not measured video FPS",
                "timestamp": ISO8601DateFormatter().string(from: Date())]
    }
}

/// Runs real playback through the production zoom path without an XCTest touch driver.
/// Display-link gaps describe main-thread callback cadence, not decoded video FPS.
@MainActor enum VideoZoomPlaybackQA {
    static func run(playback: PlaybackController, interaction: VideoInteractionState) async {
        let engine = playback.engineDescriptor.id.rawValue
        var checks = [String: Bool](), measurements = [String: Any]()
        var failure = ""
        let monitor = ZoomDisplayMonitor()
        do {
            try await Task.sleep(for: .seconds(1))
            guard let host = interaction.videoLayer.superlayer?.delegate as? UIView,
                  let surface = host.superview as? GestureVideoView else { throw MediaError.message("验证画布不可用") }
            let layer = surface.videoLayer, player = layer.player
            let identity = surface.identity, opens = playback.openAttemptCount, start = playback.time
            let size = playback.subtitleVideoSize
            checks["actual-4k-decoded-size"] = size.width == 3840 && size.height == 2160
            measurements["decodedWidth"] = size.width; measurements["decodedHeight"] = size.height
            measurements["startTime"] = start
            monitor.start()
            func cycle() async throws {
                for step in 0...96 {
                    try Task.checkCancellation()
                    let ramp = step <= 48 ? step : 96 - step
                    surface.setZoomScale(1 + CGFloat(ramp) / 16)
                    try await Task.sleep(for: .milliseconds(16))
                }
                surface.resetZoom()
            }
            for _ in 0..<3 { try await cycle() }
            checks["playing-clock-advances"] = playback.time > start + 2
            checks["playback-request-preserved"] = playback.isPlaybackRequested
            measurements["playingEndTime"] = playback.time
            playback.pause()
            try await Task.sleep(for: .milliseconds(400))
            let paused = playback.time
            try await cycle()
            checks["paused-clock-and-request-preserved"] = !playback.isPlaybackRequested && abs(playback.time - paused) < 0.25
            measurements["pausedTime"] = paused; measurements["pausedEndTime"] = playback.time
            checks["same-media-engine-and-open-count"] = surface.identity == identity && playback.openAttemptCount == opens && playback.engineDescriptor.id.rawValue == engine
            checks["same-native-layer-and-player"] = surface.videoLayer === layer && layer.player === player
            checks["frame-ready-without-error"] = playback.frameReady && playback.error == nil
            checks["zoom-reset"] = interaction.zoom == 1 && interaction.offset == .zero
            checks["foreground-display-callbacks"] = monitor.gaps.count >= 100
            measurements["openAttempts"] = playback.openAttemptCount
            playback.play()
        } catch { failure = Task.isCancelled ? "验证已取消" : error.localizedDescription }
        monitor.stop()
        measurements["displayCallbackCount"] = monitor.gaps.count
        measurements["displayCallbackMaxGapMs"] = (monitor.gaps.max() ?? 0) * 1000
        let sorted = monitor.gaps.sorted()
        if !sorted.isEmpty { measurements["displayCallbackP95GapMs"] = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000 }
        let report: [String: Any] = ["passed": failure.isEmpty && !checks.isEmpty && checks.values.allSatisfy { $0 },
            "checks": checks, "measurements": measurements, "error": failure, "engine": engine,
            "timestamp": ISO8601DateFormatter().string(from: Date()), "os": UIDevice.current.systemVersion,
            "scope": "Production PlayerView, actual authored 4K decode; zoom method driven in-app, not physical touch automation; display callback cadence is not video FPS"]
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoZoomPlaybackQA-" + engine + ".json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: file, options: .atomic) }
    }
}

@MainActor private final class ZoomDisplayMonitor: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private(set) var gaps = [CFTimeInterval]()
    func start() {
        let value = CADisplayLink(target: self, selector: #selector(tick))
        value.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        value.add(to: .main, forMode: .common); link = value
    }
    @objc private func tick() {
        let now = CACurrentMediaTime()
        if let last { gaps.append(now - last) }
        last = now
    }
    func stop() { link?.invalidate(); link = nil }
}
#endif
