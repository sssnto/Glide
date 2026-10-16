import AVFoundation
import UIKit
import Darwin

@main @MainActor final class LabApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "CompatibilityLab", sessionRole: session.role)
        configuration.delegateClass = LabScene.self
        return configuration
    }
}

@MainActor final class LabScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = LabController(); window.makeKeyAndVisible(); self.window = window
    }
}

private enum LabFailure: Error { case check(String) }

/// Original bundled fixtures only; no server credentials, network inputs, or user files.
@MainActor final class LabController: UIViewController {
    private let engine = VLCPlaybackEngine()
    private let status = UILabel(), report = UITextView(), titleLabel = UILabel()
    private let continueButton = UIButton(type: .system)
    private var acknowledged = false
    private var results: [[String: Any]] = []
    private var work: Task<Void, Never>?
    private var started = false
    private let audioOwner = UUID()
    private var suite: String {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--suite"), arguments.indices.contains(index + 1) else { return "matrix" }
        return arguments[index + 1]
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        titleLabel.text = "Glide · 兼容内核验证"; titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        status.text = "待开始"; status.textColor = .systemGreen; status.accessibilityIdentifier = "lab.status"
        report.isEditable = false; report.backgroundColor = .secondarySystemBackground
        report.textColor = .white; report.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        report.accessibilityIdentifier = "lab.report"
        continueButton.setTitle("继续验证", for: .normal)
        continueButton.accessibilityIdentifier = "lab.continue"
        continueButton.isHidden = true
        continueButton.addAction(UIAction { [weak self] _ in self?.acknowledged = true }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [titleLabel, engine.surface, status, continueButton, report])
        stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            engine.surface.heightAnchor.constraint(equalTo: engine.surface.widthAnchor, multiplier: 9.0 / 16)
        ])
        engine.surface.backgroundColor = .black; engine.surface.accessibilityIdentifier = "lab.canvas"
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }; started = true
        UIApplication.shared.isIdleTimerDisabled = true
        work = Task { await run() }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); work?.cancel(); engine.stop(); PlaybackAudioSession.release(owner: audioOwner)
        UIApplication.shared.isIdleTimerDisabled = false
    }
    private func run() async {
        do {
            try await PlaybackAudioSession.activate(owner: audioOwner)
            if suite == "controls" { try await controls() }
            else if suite == "lifecycle" { try await lifecycle() }
            else if suite == "subtitle-controls" { try await subtitleControls() }
            else if suite == "endurance" { try await endurance() }
            else {
                let samples = suite == "edges" ? ["05-renamed-mkv.mp4", "06-truncated.mp4", "07-audio-only.mp4", "08-multi-track.mp4"]
                    : suite == "subtitles" ? ["09-ass.mkv", "10-dual-audio-ass.mkv"]
                    : ["01-h264-aac.mp4", "02-hevc-aac.mp4", "03-h264-aac.mkv", "04-mpeg4-mp3.avi"]
                for sample in samples { try Task.checkCancellation(); await validate(sample) }
            }
        } catch { results.append(["error": String(describing: error), "passed": false]) }
        engine.stop()
        let drained = await wait(10) { engine.retiringSessions == 0 }
        if !drained { results.append(["error": "Decoder did not finish asynchronous stop", "passed": false, "retiringSessions": engine.retiringSessions]) }
        PlaybackAudioSession.release(owner: audioOwner)
        let passed = !results.isEmpty && results.allSatisfy { $0["passed"] as? Bool == true }
        let result: [String: Any] = ["engine": "MobileVLCKit", "version": "3.7.3", "suite": suite, "runtime": engine.libraryVersion, "passed": passed, "results": results]
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        report.text = String(decoding: data, as: UTF8.self)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("lab-" + suite + ".json"), options: .atomic)
        status.text = passed ? "完成：通过" : "完成：存在失败"
        UIApplication.shared.isIdleTimerDisabled = false
    }
    private func resource(_ name: String) throws -> PlaybackResource {
        let url = Bundle.main.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LabFailure.check("Missing original fixture: " + name) }
        return PlaybackResource(url: url, delivery: .local)
    }
    private func load(_ name: String) async throws {
        try await engine.load(resource(name), preload: nil, options: PlaybackEngineOptions(allowsCellular: false, subtitleScale: 1, forwardBuffer: 0))
    }
    private func wait(_ seconds: Double = 8, for condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !Task.isCancelled, Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
    private func check(_ condition: Bool, _ message: String) throws { if !condition { throw LabFailure.check(message) } }
    private func validate(_ name: String) async {
        status.text = "验证：" + name
        var record: [String: Any] = ["sample": name]
        let start = Date()
        do {
            try await load(name)
            let ready = await wait(6) { engine.snapshot.ready || engine.snapshot.phase == .failed }
            if engine.snapshot.ready {
                if suite == "subtitles" {
                    guard let subtitle = engine.tracks.first(where: { $0.kind == .subtitle }) else { throw LabFailure.check("ASS track is missing") }
                    engine.selectTrack(subtitle.id, kind: .subtitle)
                }
                engine.play(rate: 1)
            }
            let expectFrame = name != "06-truncated.mp4" && name != "07-audio-only.mp4"
            let frame = await wait(expectFrame ? 8 : 2) { engine.snapshot.frameReady }
            record["ready"] = ready && engine.snapshot.ready
            record["displayedFrame"] = frame; record["decodedVideo"] = engine.decodedVideo
            record["displayedPictures"] = engine.displayedPictures
            record["duration"] = engine.snapshot.duration; record["clock"] = engine.snapshot.time
            record["audioTracks"] = engine.tracks.filter { $0.kind == .audio }.count
            record["subtitleChoices"] = engine.tracks.filter { $0.kind == .subtitle }.count
            // libVLC's decoded snapshot request needs a subsequent output
            // frame. Capture while playing; pause only for the separate on-screen
            // subtitle OCR, whose image must include the actual overlay.
            if frame { record["frameSeconds"] = Date().timeIntervalSince(start); record["image"] = try await capture(name) }
            if frame, name.hasPrefix("09-") || name.hasPrefix("10-") {
                try? await Task.sleep(for: .milliseconds(700))
                record["subtitleRefreshes"] = engine.subtitleRefreshCount
                engine.pause()
                try? await Task.sleep(for: .milliseconds(200))
            }
            if frame, suite == "subtitles", ProcessInfo.processInfo.arguments.contains("--visual") {
                try await visualStage(name)
            }
            try check(frame == expectFrame, "Unexpected frame outcome")
            record["passed"] = true
        } catch { record["passed"] = false; record["error"] = String(describing: error) }
        engine.stop(); results.append(record)
    }
    private func capture(_ name: String) async throws -> [String: Any] {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Snapshots")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(UUID().uuidString + ".png")
        engine.saveSnapshot(to: path)
        let exists = await wait(3) { FileManager.default.fileExists(atPath: path.path) }
        try check(exists, "Current-session decoded snapshot was not produced")
        guard let data = try? Data(contentsOf: path), let image = UIImage(data: data)?.cgImage else { throw LabFailure.check("Snapshot is not an image") }
        let colors = distinctColors(image)
        try check(colors > 8, "Snapshot does not contain the synthetic moving color pattern")
        let target = root.appendingPathComponent(name + ".png")
        try? FileManager.default.removeItem(at: target); try FileManager.default.moveItem(at: path, to: target)
        return ["width": image.width, "height": image.height, "distinctColorBins": colors]
    }
    private func distinctColors(_ image: CGImage) -> Int {
        var pixels = [UInt8](repeating: 0, count: 32 * 18 * 4)
        let result = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 18)); return true
        }
        guard result else { return 0 }
        var colors = Set<Int>()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index]) / 32, green = Int(pixels[index + 1]) / 32, blue = Int(pixels[index + 2]) / 32
            colors.insert(red * 64 + green * 8 + blue)
        }
        return colors.count
    }
    private func seek(_ target: Double) async throws -> Double {
        var result: (Bool, Double)?
        engine.seek(to: target, tolerance: 0.5) { result = ($0, $1) }
        let completed = await wait(4) { result != nil }
        try check(completed && result?.0 == true, "Seek did not settle: target=\(target), actual=\(result?.1 ?? engine.snapshot.time), cached=\(engine.cachedSDKTime), phase=\(engine.snapshot.phase)")
        return result!.1
    }
    private func visualStage(_ name: String) async throws {
        guard ProcessInfo.processInfo.arguments.contains("--visual") else { return }
        acknowledged = false; continueButton.isHidden = false
        status.text = "画面：" + name
        let confirmed = await wait(120) { acknowledged }
        continueButton.isHidden = true
        try check(confirmed, "On-screen capture was not acknowledged: " + name)
    }
    private func subtitleControls() async throws {
        status.text = "验证：字幕起播、关闭重开、暂停、倍速与定位竞争"
        try await load("10-dual-audio-ass.mkv")
        let ready = await wait { engine.snapshot.ready }; try check(ready, "Cannot prepare ASS input")
        let subtitle = try unwrapSubtitle()
        engine.selectTrack(subtitle.id, kind: .subtitle); engine.play(rate: 1)
        let frame = await wait { engine.snapshot.frameReady }; try check(frame, "No ASS video output")
        try? await Task.sleep(for: .milliseconds(700)); engine.pause()
        try? await Task.sleep(for: .milliseconds(300))
        let initial = engine.snapshot.time
        try await visualStage("control-initial")

        engine.selectTrack(nil, kind: .subtitle)
        try? await Task.sleep(for: .milliseconds(700))
        try check(engine.selectedSubtitleID == nil, "Subtitle stayed enabled")
        try check(abs(engine.snapshot.time - initial) < 0.5, "Disabling subtitles advanced paused playback")
        try await visualStage("control-off")

        engine.selectTrack(subtitle.id, kind: .subtitle)
        try? await Task.sleep(for: .milliseconds(700))
        let restored = engine.snapshot.time
        try? await Task.sleep(for: .milliseconds(700))
        try check(abs(engine.snapshot.time - restored) < 0.3 && abs(restored - initial) < 0.5, "Enabling subtitles resumed or moved paused playback")
        try await visualStage("control-paused-on")

        engine.play(rate: 2)
        engine.selectTrack(nil, kind: .subtitle); engine.selectTrack(subtitle.id, kind: .subtitle)
        let rateReady = await wait(3) { engine.isPlaying && engine.subtitleSettled && abs(engine.playbackRate - 2) < 0.001 }
        try check(rateReady, "2x input did not settle: rate=\(engine.playbackRate), phase=\(engine.snapshot.phase), subtitleSettled=\(engine.subtitleSettled)")
        // A queued subtitle seek can stall the decoder briefly even after the
        // input reports playing. Measure actual elapsed time after it advances.
        let startingClock = engine.snapshot.time
        let advancing = await wait(3) { engine.snapshot.time - startingClock > 0.3 }
        try check(advancing, "2x input stopped advancing: rate=\(engine.playbackRate), phase=\(engine.snapshot.phase)")
        let before = engine.snapshot.time
        let rateStart = ProcessInfo.processInfo.systemUptime
        try? await Task.sleep(for: .seconds(1.2))
        let rateElapsed = ProcessInfo.processInfo.systemUptime - rateStart
        let advance = engine.snapshot.time - before
        let measuredRate = advance / rateElapsed
        try check(measuredRate > 1.5 && measuredRate < 2.5, "Subtitle refresh lost 2x rate: advance=\(advance), elapsed=\(rateElapsed), measured=\(measuredRate), SDK=\(engine.playbackRate), phase=\(engine.snapshot.phase)")
        engine.pause(); try? await Task.sleep(for: .milliseconds(300))
        try await visualStage("control-rate")

        var obsolete = false
        engine.selectTrack(nil, kind: .subtitle); engine.selectTrack(subtitle.id, kind: .subtitle)
        engine.seek(to: 15, tolerance: 0.5) { _, _ in obsolete = true }
        let actual = try await seek(5)
        let cachedAtSeek = engine.cachedSDKTime
        try? await Task.sleep(for: .milliseconds(700))
        try check(!obsolete && abs(actual - 5) < 0.5 && abs(engine.snapshot.time - 5) < 0.5, "Subtitle refresh overrode the latest paused user seek: obsolete=\(obsolete), completion=\(actual), current=\(engine.snapshot.time), cached=\(engine.cachedSDKTime), phase=\(engine.snapshot.phase), playing=\(engine.isPlaying), refreshes=\(engine.subtitleRefreshCount)")
        let refreshes = engine.subtitleRefreshCount
        try await visualStage("control-seek")

        // Leave a subtitle refresh pending when closing. New input must own its choice.
        engine.selectTrack(nil, kind: .subtitle); engine.stop()
        try await load("09-ass.mkv")
        let newReady = await wait { engine.snapshot.ready }; try check(newReady, "Cannot reopen ASS input")
        engine.selectTrack(nil, kind: .subtitle); engine.play(rate: 1)
        let newFrame = await wait { engine.snapshot.frameReady }; try check(newFrame, "Reopen did not render")
        try? await Task.sleep(for: .milliseconds(700)); engine.pause()
        try? await Task.sleep(for: .milliseconds(300))
        try check(engine.selectedSubtitleID == nil, "Old subtitle choice escaped into a new input")
        try await visualStage("control-reopen-off")
        engine.selectTrack(try unwrapSubtitle().id, kind: .subtitle)
        try? await Task.sleep(for: .milliseconds(700))
        try await visualStage("control-reopen-on")
        results.append(["sample": "subtitle-controls", "passed": true, "initialClock": initial,
            "pausedClockAfterEnable": restored, "rate2xAdvance": advance,
            "rateMeasurementElapsed": rateElapsed, "measuredRate": measuredRate,
            "userSeekActual": actual, "cachedSDKTimeAtSeekCompletion": cachedAtSeek,
            "obsoleteSeekCompletion": obsolete, "firstInputSubtitleRefreshes": refreshes,
            "reopenedSubtitleRefreshes": engine.subtitleRefreshCount])
    }
    private func unwrapSubtitle() throws -> PlaybackTrack {
        guard let subtitle = engine.tracks.first(where: { $0.kind == .subtitle }) else { throw LabFailure.check("ASS track missing") }
        return subtitle
    }
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
    private func enduranceCheckpoint(_ value: [String: Any]) throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("endurance-progress.json"), options: .atomic)
    }
    private func endurance() async throws {
        var memory: [UInt64] = [], firstFrames: [Double] = [], stopTimes: [Double] = []
        for cycle in 0..<50 {
            status.text = "真机验证：重复打开／关闭 \(cycle + 1) / 50"
            let start = ProcessInfo.processInfo.systemUptime
            try await load("11-hd-dual-ass.mkv")
            engine.setVolume(0)
            let ready = await wait { engine.snapshot.ready }; try check(ready, "HD input did not prepare")
            engine.play(rate: 1)
            let frame = await wait { engine.snapshot.frameReady }; try check(frame, "HD input did not render")
            firstFrames.append(ProcessInfo.processInfo.systemUptime - start)
            let beforeStop = ProcessInfo.processInfo.systemUptime
            engine.stop(); stopTimes.append(ProcessInfo.processInfo.systemUptime - beforeStop)
            let drained = await wait(10) { engine.retiringSessions == 0 }
            try check(drained, "HD decoder did not retire")
            memory.append(residentBytes())
            try enduranceCheckpoint(["passed": false, "stage": "reopen", "cyclesCompleted": cycle + 1,
                "residentBytesAfterStop": memory, "firstFrameSeconds": firstFrames, "stopSeconds": stopTimes])
        }
        try await load("11-hd-dual-ass.mkv"); engine.setVolume(0)
        let ready = await wait { engine.snapshot.ready }; try check(ready, "Long HD input did not prepare")
        engine.selectTrack(try unwrapSubtitle().id, kind: .subtitle); engine.play(rate: 1)
        let frame = await wait { engine.snapshot.frameReady }; try check(frame, "Long HD input did not render")
        var activeSeconds = 0.0, last = ProcessInfo.processInfo.systemUptime, nextSample = 0.0
        var clockBefore = engine.snapshot.time, stalled = 0.0
        var samples: [[String: Any]] = []
        while activeSeconds < 1800 {
            try await Task.sleep(for: .milliseconds(500))
            let now = ProcessInfo.processInfo.systemUptime, delta = min(1, now - last); last = now
            if UIApplication.shared.applicationState != .active {
                engine.pause()
                let active = await wait(120) { UIApplication.shared.applicationState == .active }
                try check(active, "Foreground playback validation interrupted for over 120 seconds")
                engine.play(rate: 1); last = ProcessInfo.processInfo.systemUptime; continue
            }
            activeSeconds += delta
            let snapshot = engine.snapshot
            try check(snapshot.phase != .failed, "HD playback failed")
            if snapshot.time > 55 {
                _ = try await seek(1); engine.play(rate: 1); clockBefore = 1; stalled = 0
            } else {
                stalled = abs(snapshot.time - clockBefore) > 0.1 ? 0 : stalled + delta
                clockBefore = snapshot.time
                try check(stalled < 8, "HD playback clock stopped")
            }
            try check(ProcessInfo.processInfo.thermalState != .critical, "Device reached critical thermal state")
            status.text = "静音 1080p 长播：\(Int(activeSeconds)) / 1800 秒"
            if activeSeconds >= nextSample {
                samples.append(["activeSeconds": activeSeconds, "clock": snapshot.time,
                    "residentBytes": residentBytes(), "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                    "displayedPictures": engine.displayedPictures])
                try enduranceCheckpoint(["passed": false, "stage": "long-play", "cyclesCompleted": 50,
                    "activeSeconds": activeSeconds, "residentBytesAfterStop": memory,
                    "firstFrameSeconds": firstFrames, "stopSeconds": stopTimes, "samples": samples])
                nextSample += 30
            }
        }
        results.append(["sample": "1080p-endurance", "passed": true, "cyclesCompleted": 50,
            "activeSeconds": activeSeconds, "residentBytesAfterStop": memory,
            "firstFrameSeconds": firstFrames, "stopSeconds": stopTimes, "samples": samples,
            "audioMuted": true, "humanAudioListeningVerified": false])
    }
    private func controls() async throws {
        status.text = "验证：轨道、暂停、倍速与连续定位"
        try await load("08-multi-track.mp4")
        let ready = await wait { engine.snapshot.ready }; try check(ready, "Cannot prepare paused input")
        try check(engine.snapshot.time < 0.3, "Preparation advanced the clock")
        engine.play(rate: 1)
        let frame = await wait { engine.snapshot.frameReady }; try check(frame, "No video frame")
        let audio = engine.tracks.filter { $0.kind == .audio }, subtitles = engine.tracks.filter { $0.kind == .subtitle }
        try check(audio.count == 2 && !subtitles.isEmpty, "Expected two audio tracks and an embedded subtitle")
        engine.selectTrack(audio[1].id, kind: .audio)
        try check(engine.selectedAudioID == audio[1].id, "Audio selection did not stick")
        engine.selectTrack(subtitles[0].id, kind: .subtitle)
        let selected = await wait(1) { engine.selectedSubtitleID == subtitles[0].id }
        try check(selected, "Subtitle selection did not stick")
        try? await Task.sleep(for: .milliseconds(600))
        _ = try await capture("selected-subtitle")
        engine.selectTrack(nil, kind: .subtitle)
        let disabled = await wait(1) { engine.selectedSubtitleID == nil }
        try check(disabled, "Subtitle did not turn off")
        engine.pause(); try? await Task.sleep(for: .milliseconds(300))
        let paused = engine.snapshot.time; try? await Task.sleep(for: .milliseconds(700))
        try check(abs(engine.snapshot.time - paused) < 0.3, "Paused clock advanced")
        engine.play(rate: 1)
        var obsoleteCompletion = false
        engine.seek(to: 15, tolerance: 0.5) { _, _ in obsoleteCompletion = true }
        let actual = try await seek(5)
        try check(!obsoleteCompletion && abs(actual - 5) < 1, "An obsolete seek completion escaped")
        let before = engine.snapshot.time; engine.setRate(2, playing: true)
        try? await Task.sleep(for: .seconds(1.2))
        let advanced = engine.snapshot.time - before
        try check(advanced > 1.5 && advanced < 3.5, "2x rate was not reflected by the media clock")
        results.append(["sample": "controls", "passed": true, "audioChoices": audio.map(\.displayName), "subtitleChoices": subtitles.map(\.displayName), "seekTarget": 5, "seekActual": actual, "rate2xAdvanceIn1_2Seconds": advanced, "obsoleteSeekCompletion": obsoleteCompletion])
    }
    private func lifecycle() async throws {
        status.text = "验证：快速退出与重新打开"
        var staleSeek = false, durations: [Double] = []
        for delay in [0, 50, 100] {
            try await load("03-h264-aac.mkv"); engine.play(rate: 1)
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            let start = Date(); engine.stop(); durations.append(Date().timeIntervalSince(start))
            try check(!engine.snapshot.hasItem && !engine.snapshot.frameReady && engine.tracks.isEmpty, "Stopped resource leaked into a new session")
        }
        try await load("03-h264-aac.mkv"); engine.play(rate: 1)
        let frame = await wait { engine.snapshot.frameReady }; try check(frame, "Reopen did not render")
        engine.seek(to: 10, tolerance: 0.5) { _, _ in staleSeek = true }
        engine.stop()
        try await load("04-mpeg4-mp3.avi"); engine.play(rate: 1)
        let reopened = await wait { engine.snapshot.frameReady }; try check(reopened && !staleSeek, "Closed session completed a seek into the next file")
        _ = try await capture("reopened-avi")
        try check(durations.allSatisfy { $0 < 0.25 }, "Stop blocked the main thread")
        let drained = await wait(10) { engine.retiringSessions == 0 }
        try check(drained, "Retired decoders or file leases were not released")
        results.append(["sample": "lifecycle", "passed": true, "stopSeconds": durations, "staleSeekCompletion": staleSeek, "reopenedDisplayedPictures": engine.displayedPictures])
    }
}
