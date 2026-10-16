import XCTest
import Vision

final class CompatibilityPlaybackUITests: XCTestCase {
    @MainActor func testJellyfinOriginalTransportRecoveryAndOfflineRetention() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_4K_TRANSPORT_FIXTURE"] == "1" else { throw XCTSkip("Run the authored 4K transport fixture") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-network-buffer-probe", "--glide-transport-recovery", "-localPlaybackEngine", "avPlayer",
            "-preferredAudioLanguage", "", "-preferredSubtitleLanguage", "", "-forcedSubtitlesOnly", "NO"]
        app.launch()
        let status = app.staticTexts["network.probe.status"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ OR label == %@", "4K 网络验证通过", "4K 网络验证未通过"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 210), .completed)
        let report = app.staticTexts["network.probe.report"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(string: report.label)
        attachment.name = "Preferred original transport and offline retention"; attachment.lifetime = .keepAlways; add(attachment)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(status.label, "4K 网络验证通过", report.label)
    }
    @MainActor func testJellyfin4KNetworkBufferingAndUserIntent() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_4K_FIXTURE"] == "1" else { throw XCTSkip("Run the authored progressive 4K fixture server") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-network-buffer-probe", "-localPlaybackEngine", "avPlayer",
            "-preferredAudioLanguage", "", "-preferredSubtitleLanguage", "", "-forcedSubtitlesOnly", "NO"]
        app.launch()
        let status = app.staticTexts["network.probe.status"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ OR label == %@", "4K 网络验证通过", "4K 网络验证未通过"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 175), .completed)
        let report = app.staticTexts["network.probe.report"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(string: report.label)
        attachment.name = "Actual 4K progressive network playback"; attachment.lifetime = .keepAlways; add(attachment)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(status.label, "4K 网络验证通过", report.label)
    }
    @MainActor private func fixtureApp(engine: String = "vlc", subtitles: String = "off", paused: Bool = false) throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["GLIDE_FORMAT_FIXTURES"] == "1" else { throw XCTSkip("Install authored FormatFixtures in the QA app sandbox") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-format-fixtures", "-localPlaybackEngine", engine,
            "-controlsDelay", "120", "-preferredAudioLanguage", "", "-preferredSubtitleLanguage", subtitles,
            "-forcedSubtitlesOnly", "NO", "-glideQAStartPaused", paused ? "YES" : "NO"]
        app.launch()
        wait(app.buttons["sources.open"], "label CONTAINS 'FormatFixtures'", seconds: 25)
        return app
    }
    @MainActor private func wait(_ element: XCUIElement, _ predicate: String, seconds: Double = 15) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)], timeout: seconds), .completed, predicate + ": " + element.label)
    }
    @MainActor private func open(_ name: String, in app: XCUIApplication) {
        let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video.' AND identifier ENDSWITH %@", ":local:" + name)).firstMatch
        for _ in 0..<10 { if video.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(video.waitForExistence(timeout: 10), name); video.tap()
    }
    @MainActor private func picture(_ app: XCUIApplication) {
        wait(app.otherElements["player.canvas"], "label CONTAINS '已显示画面'", seconds: 25)
        XCTAssertFalse(app.staticTexts["player.error"].exists)
    }
    @MainActor private func settings(_ app: XCUIApplication) {
        if !app.buttons["播放设置"].exists { app.otherElements["player.canvas"].tap() }
        XCTAssertTrue(app.buttons["播放设置"].waitForExistence(timeout: 5))
        app.buttons["播放设置"].tap()
        XCTAssertTrue(app.buttons["player.settings.done"].waitForExistence(timeout: 8))
        // Expand the medium sheet before scrolling its lazily loaded Form.
        // On iOS 27, swiping the Form can be consumed by the sheet itself.
        let done = app.buttons["player.settings.done"]
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: app.frame.midX, dy: done.frame.minY - 15))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)), withVelocity: .slow, thenHoldForDuration: 0.2)
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication, upwards: Bool = true) {
        let form = app.collectionViews["player.settings.list"]
        for _ in 0..<10 {
            // A clipped row can report hittable while its tap point lies under
            // the home indicator. Require the complete row inside the viewport.
            if element.isHittable, element.frame.minY >= app.buttons["player.settings.done"].frame.maxY + 8,
               element.frame.maxY <= app.frame.maxY - 40 { return }
            if upwards { form.swipeUp() } else { form.swipeDown() }
        }
        XCTAssertTrue(element.isHittable)
        XCTAssertGreaterThanOrEqual(element.frame.minY, app.buttons["player.settings.done"].frame.maxY + 8)
        XCTAssertLessThanOrEqual(element.frame.maxY, app.frame.maxY - 40)
    }
    @MainActor private func subtitleVisible(_ app: XCUIApplication, expected: Bool) throws {
        let shot = app.screenshot(), attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = expected ? "ASS visible in Glide" : "ASS disabled in Glide"
        attachment.lifetime = .keepAlways; add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(shot.image.cgImage), options: [:]).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        XCTAssertEqual(text.contains("glide ass subtitle"), expected, text)
    }
    private func seconds(_ text: String) -> Int {
        text.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }
    @MainActor func testCompatibilityChineseASS() throws {
        try verifyChineseSubtitle("12-cjk-ass.mkv", expected: "中文字幕正常显示")
    }
    @MainActor func testCompatibilityMissingFontTraditionalASS() throws {
        try verifyChineseSubtitle("13-cjk-ass.mkv", expected: "繁體字幕正常顯示")
    }
    @MainActor func testCompatibilityChineseSRT() throws {
        try verifyChineseSubtitle("14-cjk-srt.mkv", expected: "中文字幕正常显示")
    }
    @MainActor private func verifyChineseSubtitle(_ sample: String, expected: String) throws {
        let app = try fixtureApp(subtitles: "zh", paused: true)
        open(sample, in: app); picture(app)
        settings(app)
        let subtitle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.subtitle.'")).firstMatch
        reveal(subtitle, in: app); subtitle.tap()
        wait(subtitle, "label CONTAINS '✓'")
        app.buttons["player.settings.done"].tap(); picture(app)
        app.descendants(matching: .any)["player.seekBar"].firstMatch.movePlaybackThumb(to: 0.2)
        wait(app.staticTexts["player.elapsed"], "label >= '00:03' AND label <= '00:05'")
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = sample; attachment.lifetime = .keepAlways; add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(shot.image.cgImage), options: [:]).perform([request])
        let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined().filter { !$0.isWhitespace }
        XCTAssertTrue(recognized.contains(expected), sample + ": " + recognized)
        app.terminate()
    }
    @MainActor func testCompatibilityLocalFormatsAndDiagnostics() throws {
        for sample in ["03-h264-aac.mkv", "04-mpeg4-mp3.avi", "05-renamed-mkv.mp4"] {
            let app = try fixtureApp(paused: true)
            open(sample, in: app); picture(app)
            settings(app)
            XCTAssertTrue(app.buttons["player.engine.compatibility"].label.contains("✓"))
            XCTAssertFalse(app.buttons["player.pip"].exists)
            app.buttons["player.diagnostic"].tap()
            let report = app.staticTexts["diagnostic.json"]
            XCTAssertTrue(report.waitForExistence(timeout: 8))
            XCTAssertTrue(report.label.contains("engine_vlc"))
            XCTAssertFalse(report.label.contains("file://"))
            let attachment = XCTAttachment(data: Data(report.label.utf8), uniformTypeIdentifier: "public.json")
            attachment.name = sample; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
    }
    @MainActor func testEngineSwitchPreservesPausePositionAndQueue() throws {
        let app = try fixtureApp(engine: "avPlayer")
        open("08-multi-track.mp4", in: app); picture(app)
        let elapsed = app.staticTexts["player.elapsed"]
        wait(elapsed, "label >= '00:03'")
        app.buttons["暂停"].tap()
        let paused = seconds(elapsed.label)
        settings(app); app.buttons["player.engine.compatibility"].tap()
        wait(app.buttons["player.engine.compatibility"], "label CONTAINS '✓'")
        XCTAssertFalse(app.buttons["player.pip"].exists)
        app.buttons["player.settings.done"].tap(); picture(app)
        XCTAssertTrue(app.buttons["播放"].exists)
        XCTAssertLessThanOrEqual(abs(seconds(elapsed.label) - paused), 1)
        settings(app); app.buttons["player.engine.native"].tap()
        wait(app.buttons["player.engine.native"], "label CONTAINS '✓'")
        XCTAssertTrue(app.buttons["player.pip"].exists)
        app.buttons["player.settings.done"].tap(); picture(app)
        XCTAssertTrue(app.buttons["播放"].exists)
        XCTAssertLessThanOrEqual(abs(seconds(elapsed.label) - paused), 1)
        settings(app); app.buttons["player.engine.compatibility"].tap()
        wait(app.buttons["player.engine.compatibility"], "label CONTAINS '✓'")
        app.buttons["player.settings.done"].tap(); picture(app)
        app.buttons["下一个视频"].tap(); picture(app)
        settings(app)
        XCTAssertTrue(app.buttons["player.engine.compatibility"].label.contains("✓"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Compatibility settings after engine switch"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testNativeFailureCanRetryWithCompatibility() throws {
        let app = try fixtureApp(engine: "avPlayer")
        open("03-h264-aac.mkv", in: app)
        XCTAssertTrue(app.buttons["player.switchAfterFailure"].waitForExistence(timeout: 30))
        app.buttons["player.switchAfterFailure"].tap(); picture(app)
        settings(app)
        XCTAssertTrue(app.buttons["player.engine.compatibility"].label.contains("✓"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Compatibility settings after native failure"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testCompatibilityASSAndAudioSelection() throws {
        let app = try fixtureApp(subtitles: "en", paused: true)
        open("10-dual-audio-ass.mkv", in: app); picture(app)
        if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
        // The short authored sample may finish while XCTest resolves its UI.
        // Seek back while paused so the active cue has a deterministic time.
        app.descendants(matching: .any)["player.seekBar"].firstMatch.movePlaybackThumb(to: 0.2)
        settings(app)
        let audio = app.buttons["player.audio.audio-2"]
        reveal(audio, in: app)
        audio.tap()
        wait(audio, "label CONTAINS '✓'")
        let subtitle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.subtitle.'")).firstMatch
        reveal(subtitle, in: app, upwards: false)
        subtitle.tap(); wait(subtitle, "label CONTAINS '✓'")
        app.buttons["player.settings.done"].tap(); picture(app)
        try subtitleVisible(app, expected: true)
        settings(app)
        let off = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '关闭字幕'")).firstMatch
        reveal(off, in: app); off.tap(); wait(off, "label CONTAINS '✓'")
        app.buttons["player.settings.done"].tap()
        try subtitleVisible(app, expected: false)
    }
    @MainActor func testCompatibility1080pSeekAndPause() throws {
        let app = try fixtureApp(paused: true)
        open("11-hd-dual-ass.mkv", in: app); picture(app)
        let slider = app.descendants(matching: .any)["player.seekBar"].firstMatch
        let elapsed = app.staticTexts["player.elapsed"]
        let width = slider.frame.width
        let fraction = Double(seconds(elapsed.label)) / 60
        let from = slider.coordinate(withNormalizedOffset: CGVector(dx: (15 + (width - 30) * fraction) / width, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.2)
        wait(elapsed, "label >= '00:28' AND label <= '00:32'")
        XCTAssertTrue(app.buttons["播放"].exists)
        app.buttons["播放"].tap()
        wait(elapsed, "label >= '00:33' AND label <= '00:45'")
        app.buttons["暂停"].tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Glide 1080p compatibility playback"; attachment.lifetime = .keepAlways; add(attachment)
        settings(app)
        XCTAssertTrue(app.buttons["player.engine.compatibility"].label.contains("✓"))
    }
}

extension XCUIElement {
    @MainActor func movePlaybackThumb(to fraction: Double, hold: Double = 0.2) {
        let width = frame.width
        let target = (15 + (width - 30) * fraction) / width
        coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: coordinate(withNormalizedOffset: CGVector(dx: target, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: hold)
    }
}
