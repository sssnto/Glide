import XCTest

final class GlideUITests: XCTestCase {
    @MainActor func testOfflineDownloadIntegrityRetryAndRestart() throws {
        guard let fixtureID = ProcessInfo.processInfo.environment["GLIDE_DOWNLOAD_FIXTURE_ID"] else {
            throw XCTSkip("Run the download fixture with GLIDE_DOWNLOAD_FIXTURE_ID")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "30"]
        app.launch()
        func open(_ button: XCUIElement, until element: XCUIElement) {
            for _ in 0..<3 {
                if element.exists { return }
                if button.isHittable { button.press(forDuration: 0.15) }
                if element.waitForExistence(timeout: 4) { return }
            }
            XCTAssertTrue(element.exists)
        }
        if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { open(app.buttons["媒体库"], until: app.buttons["sources.open"]) }
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 8))
        open(app.buttons["sources.open"], until: app.buttons["sources.add"])
        let name = app.textFields["名称（可选）"]
        open(app.buttons["sources.add"], until: name)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let fixtureName = "Glide Offline Fixture " + String(UUID().uuidString.prefix(6))
        name.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { name.tap() }
        name.typeText(fixtureName)
        let address = app.textFields["服务器地址"]
        address.tap(); address.typeText("http://127.0.0.1:8768/mock/jellyfin")
        app.textFields["用户名"].tap(); app.textFields["用户名"].typeText("demo")
        app.secureTextFields["密码"].tap(); app.secureTextFields["密码"].typeText("demo\n")
        let connect = app.buttons["sources.connect"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: connect)], timeout: 5), .completed)
        connect.press(forDuration: 0.1)
        let connected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", fixtureName)).firstMatch
        if !connected.waitForExistence(timeout: 10), connect.isHittable { connect.press(forDuration: 0.1) }
        XCTAssertTrue(connected.waitForExistence(timeout: 15))
        let done = app.buttons["完成"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: done)], timeout: 5), .completed)
        done.press(forDuration: 0.1)
        let movie = app.buttons["catalog." + fixtureID]
        XCTAssertTrue(app.buttons["folder.fixture-movies"].waitForExistence(timeout: 10))
        open(app.buttons["folder.fixture-movies"], until: movie)
        open(movie, until: app.buttons["detail.play"])
        let download = app.buttons["detail.download"]
        for _ in 0..<5 { if download.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(download.isHittable); download.press(forDuration: 0.15)
        XCTAssertTrue(app.buttons["加入下载队列"].firstMatch.waitForExistence(timeout: 5)); app.buttons["加入下载队列"].firstMatch.tap()
        let state = app.staticTexts["download.state." + fixtureID]
        open(app.buttons["离线下载"], until: state)
        // First fixture response is truncated; integrity validation must reject it.
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "下载失败"), object: state)], timeout: 20), .completed)
        XCTAssertTrue(app.staticTexts["文件大小不完整，请重试下载。"].exists)
        let offline = app.buttons["offline.play." + fixtureID]
        open(app.buttons["download.resume." + fixtureID], until: offline)
        XCTAssertTrue(offline.waitForExistence(timeout: 30), "The complete MP4 must pass validation and become available offline")
        XCTAssertEqual(state.label, "已完成")
        XCTAssertFalse(app.staticTexts["正在重新下载。"].exists)
        XCTAssertEqual(fixtureMetric("/mock/jellyfin/Items/" + fixtureID + "/Download"), 2)
        // Reopening the downloads page must not misclassify a finished transfer.
        open(app.navigationBars.buttons.element(boundBy: 0), until: app.buttons["detail.play"])
        open(app.buttons["离线下载"], until: offline)
        XCTAssertTrue(offline.waitForExistence(timeout: 10)); XCTAssertEqual(state.label, "已完成")
        app.terminate(); app.launch()
        open(app.tabBars.buttons["离线"], until: offline)
        XCTAssertTrue(offline.waitForExistence(timeout: 10)); XCTAssertEqual(state.label, "已完成")
        let streamPath = "/mock/jellyfin/Videos/" + fixtureID + "/stream"
        let streamsBefore = fixtureMetric(streamPath)
        let canvas = app.otherElements["player.canvas"]
        open(offline, until: canvas)
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)], timeout: 15), .completed)
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5)); app.buttons["暂停"].tap()
        XCTAssertEqual(fixtureMetric(streamPath), streamsBefore, "Offline playback must not request the remote video stream")
        XCTAssertEqual(fixtureMetric("/mock/jellyfin/Items/" + fixtureID + "/Download"), 2, "Restart must reuse the local file")
        app.buttons["返回片库"].tap()
        app.tabBars.buttons["片库"].tap()
        app.buttons["媒体库"].tap()
        app.buttons["sources.open"].tap()
        let fixture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", fixtureName)).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 5)); fixture.swipeLeft()
        app.buttons["移除"].tap(); app.buttons["移除来源，保留已下载影片"].firstMatch.tap(); app.buttons["完成"].tap()
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(offline.waitForExistence(timeout: 10), "Removing a source may retain completed local files")
        let afterRemove = fixtureMetric(streamPath)
        open(offline, until: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)], timeout: 15), .completed)
        XCTAssertEqual(fixtureMetric(streamPath), afterRemove)
        app.buttons["返回片库"].tap()
        offline.swipeLeft(); app.buttons["删除"].firstMatch.tap()
        XCTAssertFalse(offline.exists)
    }

    @MainActor func testPreparedLocalNextItem() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "30", "-preferredAudioLanguage", "", "-preferredSubtitleLanguage", "", "-forcedSubtitlesOnly", "NO"]
        app.launch()
        if !app.buttons["demo.play"].exists {
            if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
            app.buttons["sources.open"].tap(); app.buttons["离线演示片库"].tap()
        }
        app.segmentedControls.buttons["顺序播放"].tap(); app.buttons["demo.play"].tap()
        let canvas = app.otherElements["player.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        let elapsed = app.staticTexts["player.elapsed"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label >= %@", "00:03"), object: elapsed)], timeout: 10), .completed)
        app.buttons["下一个视频"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)], timeout: 15), .completed)
        app.buttons["暂停"].tap()
        app.buttons["播放设置"].tap(); app.buttons["player.diagnostic"].tap()
        XCTAssertTrue(app.buttons["diagnostic.share"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "warmup_hit")).firstMatch.exists, "A completed local asset preparation is reused by the next item")
        app.buttons["完成"].tap(); app.buttons["返回片库"].tap()
    }

    @MainActor func testRapidReopenKeepsNativePlaybackResponsive() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "30"]
        app.launch()
        if !app.buttons["demo.play"].exists {
            if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
            app.buttons["sources.open"].tap()
            app.buttons["离线演示片库"].tap()
        }
        app.segmentedControls.buttons["顺序播放"].tap()
        let play = app.buttons["demo.play"]
        let canvas = app.otherElements["player.canvas"]
        for attempt in 0..<3 {
            XCTAssertTrue(play.waitForExistence(timeout: 10))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: play)], timeout: 10), .completed)
            play.tap()
            XCTAssertTrue(canvas.waitForExistence(timeout: 10))
            // Exit during startup; an old session release must not affect the next player.
            let close = app.buttons["返回片库"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: close)], timeout: 5), .completed)
            close.press(forDuration: 0.1)
            let dismissed = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: canvas)], timeout: 5)
            if dismissed != .completed {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways; add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.lifetime = .keepAlways; add(hierarchy)
            }
            XCTAssertEqual(dismissed, .completed, "Return must work on attempt \(attempt + 1)")
        }
        play.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)], timeout: 15), .completed)
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5))
        app.buttons["暂停"].tap()
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 3))
        app.buttons["播放"].tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5))
        app.buttons["返回片库"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
    }

    @MainActor func testIdleAutoHideThenTapShowsControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Accessibility snapshots can arrive >2 seconds after a tap. Keep the
        // controls visible long enough to observe one wake-up after auto-hide.
        app.launchArguments += ["-controlsDelay", "6"]
        app.launch()
        if !app.buttons["demo.play"].exists {
            if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
            app.buttons["sources.open"].tap()
            app.buttons["离线演示片库"].tap()
        }
        let play = app.buttons["video.demo-0"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: play)], timeout: 10), .completed)
        play.tap()
        let canvas = app.otherElements["player.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let settings = app.buttons["播放设置"]
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false OR hittable == false"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 12), .completed,
                       "Controls should auto-hide without user interaction")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: settings)], timeout: 3), .completed,
                      "One short tap after automatic hiding must bring controls back")
    }

    @MainActor func testPlayingSwipeThenTapShowsControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "8"]
        app.launch()
        if !app.buttons["demo.play"].exists {
            if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
            app.buttons["sources.open"].tap()
            app.buttons["离线演示片库"].tap()
        }
        XCTAssertTrue(app.buttons["demo.play"].waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["demo.play"])
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        app.buttons["video.demo-0"].tap()
        let canvas = app.otherElements["player.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["播放设置"].waitForExistence(timeout: 5))
        canvas.swipeRight(velocity: .slow)
        canvas.swipeLeft(velocity: .slow)
        let settings = app.buttons["播放设置"]
        if settings.exists { canvas.tap() }
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        canvas.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 2), "A tap after speed swipes must show controls while video is playing")
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let slightMove = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.54, dy: 0.45))
        start.press(forDuration: 0.1, thenDragTo: slightMove)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: settings)], timeout: 3), .completed,
                       "A short touch with slight finger movement must not be swallowed by the pan recognizer")
        canvas.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 2))
    }

    @MainActor func testTapControlsAndHoldToSeek() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "8", "-seekInterval", "5"]
        app.launch()
        if !app.buttons["demo.play"].exists {
            if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
            app.buttons["sources.open"].tap()
            app.buttons["离线演示片库"].tap()
        }
        XCTAssertTrue(app.buttons["demo.play"].waitForExistence(timeout: 10))
        app.buttons["video.demo-0"].tap()
        let canvas = app.otherElements["player.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 15))
        app.buttons["暂停"].tap()
        let elapsed = app.staticTexts["player.elapsed"]
        let before = elapsed.label
        let seconds: (String) -> Int = { label in
            label.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
        }

        canvas.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["播放设置"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed)
        canvas.tap()
        XCTAssertTrue(app.buttons["播放设置"].waitForExistence(timeout: 3))
        XCTAssertEqual(elapsed.label, before, "A short tap must only toggle controls")

        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)).press(forDuration: 0.7)
        let forward = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: elapsed)
        XCTAssertEqual(XCTWaiter.wait(for: [forward], timeout: 5), .completed)
        let advanced = seconds(elapsed.label)
        XCTAssertGreaterThanOrEqual(advanced, seconds(before) + 4)

        let forwardTime = elapsed.label
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.45)).press(forDuration: 0.7)
        let backward = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", forwardTime), object: elapsed)
        XCTAssertEqual(XCTWaiter.wait(for: [backward], timeout: 5), .completed)
        XCTAssertLessThanOrEqual(seconds(elapsed.label), seconds(before) + 1)
    }

    @MainActor func testSwipeZoomLockAndReturn() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "8"]
        app.launch()
        if !app.buttons["demo.play"].exists {
            if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
            app.buttons["sources.open"].tap()
            app.buttons["离线演示片库"].tap()
        }
        XCTAssertTrue(app.buttons["demo.play"].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["顺序播放"].tap()
        app.buttons["demo.play"].tap()
        let canvas = app.otherElements["player.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let firstFrame = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [firstFrame], timeout: 15), .completed)
        let seekBar = app.descendants(matching: .any)["player.seekBar"]
        if !seekBar.exists { canvas.tap() }
        XCTAssertTrue(seekBar.waitForExistence(timeout: 5))
        XCTAssertTrue(seekBar.isHittable)
        if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
        // Keep the swipe start above the overlaid timeline and transport controls.
        let swipeStart = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        let swipeEnd = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        swipeStart.press(forDuration: 0.05, thenDragTo: swipeEnd)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "落日海岸"), object: canvas)], timeout: 5), .completed)
        if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
        canvas.swipeRight(velocity: .slow)
        if !app.buttons["播放设置"].exists { canvas.tap() }
        app.buttons["播放设置"].tap()
        let settings = app.collectionViews["player.settings.list"]
        for _ in 0..<4 { if app.buttons["2× ✓"].exists { break }; settings.swipeUp() }
        XCTAssertTrue(app.buttons["2× ✓"].waitForExistence(timeout: 5), "Right swipe selects double speed")
        app.buttons["完成"].tap()
        canvas.swipeLeft(velocity: .slow)
        if !app.buttons["播放设置"].exists { canvas.tap() }
        app.buttons["播放设置"].tap()
        for _ in 0..<4 { if app.buttons["1× ✓"].exists { break }; settings.swipeUp() }
        XCTAssertTrue(app.buttons["1× ✓"].waitForExistence(timeout: 5), "Left swipe restores normal speed")
        app.buttons["完成"].tap()
        if !app.buttons["返回片库"].exists { canvas.tap() }
        if app.buttons["暂停"].waitForExistence(timeout: 5) { app.buttons["暂停"].tap() }
        // Pinch the unobstructed video surface, not the overlaid transport buttons.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["播放设置"])], timeout: 3), .completed)
        canvas.pinch(withScale: 2, velocity: 1)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", "缩放 1.0 倍"), object: canvas)], timeout: 3), .completed)
        XCTAssertNotNil(canvas.value as? String)
        let zoomedVideo = canvas.label
        canvas.swipeUp(velocity: .slow)
        canvas.swipeLeft(velocity: .slow)
        XCTAssertEqual(canvas.label, zoomedVideo, "Dragging zoomed content must not change the current video")
        // Show controls if auto-hide occurred during the pinch.
        if !app.buttons["锁定触控"].exists { canvas.tap() }
        app.buttons["锁定触控"].tap()
        canvas.swipeUp(velocity: .slow)
        if !app.buttons["解锁触控"].exists { canvas.tap() }
        XCTAssertTrue(app.buttons["解锁触控"].waitForExistence(timeout: 3))
        app.buttons["解锁触控"].tap()
        XCTAssertTrue(app.staticTexts["2 / 3"].exists)
        app.buttons["返回片库"].tap()
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 3))
    }

    @MainActor func testVideoInfoShowsOriginalPathAndNativeBuffering() async throws {
        guard (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8768/debug/metrics")!)) != nil else {
            throw XCTSkip("Run Scripts/fixture_server.py to test source file paths")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "60"]
        app.launch()
        if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 10))
        app.buttons["sources.open"].tap()
        let existing = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND (label CONTAINS %@ OR label CONTAINS %@)", "source.", "127.0.0.1:8768", "Glide Recovery Fixture", "Glide Buffer Fixture")).firstMatch
        if existing.exists {
            for _ in 0..<8 { if existing.isHittable { break }; app.collectionViews.firstMatch.swipeUp() }
            XCTAssertTrue(existing.isHittable); existing.tap()
        } else {
            app.buttons["sources.add"].tap()
            let name = app.textFields["名称（可选）"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap(); name.typeText("Glide Buffer Fixture")
            app.textFields["服务器地址"].tap(); app.textFields["服务器地址"].typeText("http://127.0.0.1:8768/mock/jellyfin")
            app.textFields["用户名"].tap(); app.textFields["用户名"].typeText("demo")
            app.secureTextFields["密码"].tap(); app.secureTextFields["密码"].typeText("demo\n")
            app.buttons["sources.connect"].tap()
            XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 15)); app.buttons["完成"].tap()
        }
        let movies = app.buttons["folder.fixture-movies"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: movies)
        if await XCTWaiter.fulfillment(of: [ready], timeout: 5) != .completed, app.buttons["完成"].isHittable { app.buttons["完成"].tap() }
        XCTAssertTrue(movies.waitForExistence(timeout: 10)); movies.tap()
        let movie = app.buttons["catalog.demo0"]
        XCTAssertTrue(movie.waitForExistence(timeout: 10)); movie.tap()
        XCTAssertTrue(app.buttons["从头播放"].waitForExistence(timeout: 10)); app.buttons["从头播放"].tap()
        let canvas = app.otherElements["player.canvas"]
        let firstFrame = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)
        let frameResult = await XCTWaiter.fulfillment(of: [firstFrame], timeout: 20)
        XCTAssertEqual(frameResult, .completed)
        if app.buttons["暂停"].isHittable { app.buttons["暂停"].tap() }
        app.buttons["播放设置"].tap()
        let info = app.buttons["视频信息"]
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        let infoReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: info)
        let infoReadyResult = await XCTWaiter.fulfillment(of: [infoReady], timeout: 5)
        XCTAssertEqual(infoReadyResult, .completed)
        info.tap()
        let infoList = app.descendants(matching: .any)["player.info.list"].firstMatch
        XCTAssertTrue(infoList.waitForExistence(timeout: 10))
        let bufferedAhead = app.descendants(matching: .any)["player.info.bufferedAhead"].firstMatch
        for _ in 0..<6 { if bufferedAhead.exists { break }; infoList.swipeUp() }
        XCTAssertTrue(bufferedAhead.exists)
        let path = app.staticTexts["player.info.path"]
        for _ in 0..<6 { if path.exists { break }; infoList.swipeUp() }
        XCTAssertTrue(path.waitForExistence(timeout: 8))
        XCTAssertEqual(path.label, "/fixture/家庭视频/demo0.mp4", "Show the chosen source file, never the authenticated streaming URL")
        let copy = app.buttons["player.info.copyPath"]
        for _ in 0..<4 { if copy.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(copy.isHittable); copy.tap()
        XCTAssertEqual(copy.label, "已复制")
        app.buttons["完成"].tap()
        app.buttons["播放设置"].tap(); app.buttons["player.diagnostic"].tap()
        let json = app.staticTexts["diagnostic.json"]
        XCTAssertTrue(json.waitForExistence(timeout: 8))
        let data = try XCTUnwrap(json.label.data(using: .utf8))
        let diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(diagnostic["schema"] as? Int, 5)
        XCTAssertEqual(diagnostic["forwardBufferTargetSeconds"] as? Double, 30)
        XCTAssertNotNil(diagnostic["bufferedAheadSeconds"])
        XCTAssertFalse(json.label.contains("/fixture/"), "Exported playback diagnostics must omit file paths")
    }

    @MainActor func testCombinedTimelineSeekAndBuffer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "8"]
        app.launch()
        if !app.buttons["demo.play"].exists {
            if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
            app.buttons["sources.open"].tap()
            app.buttons["离线演示片库"].tap()
        }
        XCTAssertTrue(app.buttons["demo.play"].waitForExistence(timeout: 10))
        app.buttons["demo.play"].tap()
        let canvas = app.otherElements["player.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let seekBar = app.descendants(matching: .any)["player.seekBar"]
        if !seekBar.exists { canvas.tap() }
        XCTAssertTrue(seekBar.waitForExistence(timeout: 5))
        XCTAssertTrue(seekBar.isHittable)
        app.buttons["暂停"].tap()
        let pausedTime = app.staticTexts["player.elapsed"].label
        let elapsedSeconds = Int(pausedTime.split(separator: ":").last ?? "") ?? 0
        let target = elapsedSeconds > 6 ? 0.2 : 0.8
        let seekWidth = seekBar.frame.width
        let startX = (15 + (seekWidth - 30) * CGFloat(elapsedSeconds) / 12) / seekWidth
        let targetX = (15 + (seekWidth - 30) * CGFloat(target)) / seekWidth
        seekBar.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: seekBar.coordinate(withNormalizedOffset: CGVector(dx: targetX, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.3)
        let seekedTime = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", pausedTime), object: app.staticTexts["player.elapsed"])
        XCTAssertEqual(XCTWaiter.wait(for: [seekedTime], timeout: 5), .completed,
                       "The combined bar must still seek; bar=\(String(describing: seekBar.value)), label=\(seekBar.label), elapsed=\(app.staticTexts["player.elapsed"].label)")
    }

    @MainActor func testCompactPlayerControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
        if !app.buttons["demo.play"].exists {
            XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 8)); app.buttons["sources.open"].tap()
            XCTAssertTrue(app.buttons["离线演示片库"].waitForExistence(timeout: 5)); app.buttons["离线演示片库"].tap()
        }
        XCTAssertTrue(app.buttons["demo.play"].waitForExistence(timeout: 8)); app.buttons["demo.play"].tap()
        XCTAssertTrue(app.buttons["播放设置"].waitForExistence(timeout: 8))
        app.buttons["播放设置"].tap()
        XCTAssertTrue(app.buttons["player.settings.done"].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 4) // The popover must outlive the controls' three-second timer.
        XCTAssertTrue(app.buttons["player.settings.done"].isHittable)
        let portraitMenu = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portraitMenu.name = "Player settings portrait"; portraitMenu.lifetime = .keepAlways; add(portraitMenu)
        app.buttons["player.settings.done"].tap()
        if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 8))
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Compact player portrait"; portrait.lifetime = .keepAlways; add(portrait)
        app.buttons["player.rotate"].tap()
        XCUIDevice.shared.orientation = .landscapeRight
        defer { XCUIDevice.shared.orientation = .portrait }
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "切换竖屏"), object: app.buttons["player.rotate"])
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        Thread.sleep(forTimeInterval: 1) // Wait for the window rotation animation before measuring/capturing.
        XCTAssertLessThanOrEqual(app.buttons["播放"].frame.height, 48)
        XCTAssertGreaterThan(app.descendants(matching: .any)["player.seekBar"].frame.minY, app.frame.height * 0.60)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Compact player landscape"; landscape.lifetime = .keepAlways; add(landscape)
        app.buttons["播放设置"].tap()
        XCTAssertTrue(app.buttons["player.settings.done"].waitForExistence(timeout: 3))
        let landscapeMenu = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscapeMenu.name = "Player settings landscape"; landscapeMenu.lifetime = .keepAlways; add(landscapeMenu)
        app.buttons["player.settings.done"].tap()
        app.buttons["播放"].tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["返回片库"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 6), .completed)
        app.otherElements["player.canvas"].tap()
        XCTAssertTrue(app.buttons["返回片库"].waitForExistence(timeout: 3)); app.buttons["返回片库"].tap()
    }

    @MainActor func testAddSourceValidation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["sources.open"].tap()
        app.buttons["sources.add"].tap()
        let address = app.textFields["服务器地址"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap(); address.typeText("smb://nas/video")
        let username = app.textFields["用户名"]
        username.tap(); username.typeText("tester\n")
        app.buttons["sources.connect"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "请输入完整的 http://")).firstMatch.waitForExistence(timeout: 3))
    }
    @MainActor func testConnectedServerDirectoryPlayback() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set GLIDE_LIVE_TEST=1 to test an already configured Jellyfin server.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        app.buttons["sources.open"].tap()
        let server = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "https://")).firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 5), "Configure a Jellyfin HTTPS source before running live tests")
        server.tap()
        for _ in 0..<8 {
            if app.buttons["directory.back"].exists { app.buttons["directory.back"].tap() }
            else { break }
        }
        let library = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "folder.")).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        library.tap()
        for _ in 0..<6 {
            if app.buttons["刷本目录"].waitForExistence(timeout: 3) { break }
            let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "folder.")).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 10))
            folder.tap()
        }
        XCTAssertTrue(app.buttons["directory.refresh"].exists)
        app.buttons["directory.refresh"].tap()
        let play = app.buttons["刷本目录"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 30), "The selected playback engine should reach playing state")
        app.buttons["暂停"].tap()
        XCTAssertFalse(app.staticTexts["暂时无法播放"].exists)
        XCTAssertFalse(app.buttons["player.quality"].exists)
        app.buttons["播放"].tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 30))
        app.buttons["暂停"].tap()
        app.buttons["返回片库"].tap()
        XCTAssertTrue(app.buttons["directory.back"].waitForExistence(timeout: 5))
    }

    @MainActor func testWebDAVRangePlaybackAndLandscape() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_DAV_FIXTURE"] == "1" else {
            throw XCTSkip("Run Scripts/fixture_server.py and set GLIDE_DAV_FIXTURE=1")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-homeBrowseView", "videos"]
        app.launch()
        app.buttons["sources.open"].tap()
        app.buttons["sources.add"].tap()
        app.segmentedControls.buttons["NAS · WebDAV"].tap()
        let name = app.textFields["名称（可选）"]
        if !name.waitForExistence(timeout: 5), app.buttons["sources.add"].isHittable { app.buttons["sources.add"].tap() }
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Glide WebDAV Fixture")
        let address = app.textFields["服务器地址"]
        address.tap(); address.typeText("http://127.0.0.1:8768/dav/")
        let username = app.textFields["用户名"]
        username.tap(); username.typeText("demo")
        let password = app.secureTextFields["密码"]
        password.tap(); password.typeText("demo\n")
        app.buttons["sources.connect"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 15))
        app.buttons["完成"].tap()
        let play = app.buttons["刷本目录"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 15))
        app.buttons["暂停"].tap()
        app.buttons["player.rotate"].tap()
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        expectation(for: landscape, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        defer { XCUIDevice.shared.orientation = .portrait }
        let back = app.buttons["返回片库"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["播放"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "WebDAV landscape playback"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["player.rotate"].tap()
        let portrait = NSPredicate { _, _ in app.frame.height > app.frame.width }
        expectation(for: portrait, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        back.tap()
        XCUIDevice.shared.orientation = .portrait
        app.buttons["sources.open"].tap()
        let fixture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", "Glide WebDAV Fixture")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 5))
        fixture.swipeLeft()
        app.buttons["移除"].tap(); app.buttons["同时删除此来源的离线影片"].firstMatch.tap()
        app.buttons["完成"].tap()
    }

    @MainActor func testCatalogPolishCacheAndOffline() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_DAV_FIXTURE"] == "1" else {
            throw XCTSkip("Run Scripts/fixture_server.py and set GLIDE_DAV_FIXTURE=1")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 8))
        app.buttons["sources.open"].tap()
        if !app.buttons["sources.add"].waitForExistence(timeout: 3), app.buttons["sources.open"].exists { app.buttons["sources.open"].tap() }
        XCTAssertTrue(app.buttons["sources.add"].waitForExistence(timeout: 5))
        app.buttons["sources.add"].tap()
        let name = app.textFields["名称（可选）"]
        if !name.waitForExistence(timeout: 5), app.buttons["sources.add"].isHittable { app.buttons["sources.add"].tap() }
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let fixtureName = "Glide Polish Fixture " + String(UUID().uuidString.prefix(6))
        name.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { name.tap() }
        name.typeText(fixtureName)
        let address = app.textFields["服务器地址"]
        address.tap(); address.typeText("http://127.0.0.1:8768/mock/jellyfin")
        let username = app.textFields["用户名"]
        username.tap(); username.typeText("demo")
        let password = app.secureTextFields["密码"]
        password.tap(); password.typeText("demo\n")
        app.buttons["sources.connect"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 15))
        app.buttons["完成"].tap()
        app.buttons["folder.fixture-movies"].tap()
        XCTAssertTrue(app.buttons["catalog.demo0"].waitForExistence(timeout: 10))
        // Fixture serves one item per page: automatic pagination must settle, not cancel/restart.
        XCTAssertTrue(app.buttons["catalog.broken"].waitForExistence(timeout: 10))
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["正在读取片库…"])
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
        app.buttons["catalog.sort"].tap(); app.buttons["评分"].tap()
        app.buttons["catalog.sort"].tap(); app.buttons["改为降序"].tap()
        XCTAssertTrue(app.buttons["catalog.broken"].waitForExistence(timeout: 10))
        app.buttons["catalog.sort"].tap(); app.buttons["名称"].tap()
        app.buttons["catalog.sort"].tap(); app.buttons["改为升序"].tap()
        XCTAssertTrue(app.buttons["catalog.demo0"].waitForExistence(timeout: 10)); app.buttons["catalog.demo0"].tap()
        XCTAssertTrue(app.buttons["detail.audio"].waitForExistence(timeout: 10))
        app.buttons["detail.audio"].tap()
        let longAudio = "English DD_2.0 · Dolby Digital+ · Stereo · Original commentary track"
        XCTAssertTrue(app.buttons[longAudio].waitForExistence(timeout: 5)); app.buttons[longAudio].tap()
        app.buttons["detail.subtitle"].tap()
        let longSubtitle = "中上英下 SUP_YYeTs 字幕 Chinese 默认 强制的 PGS Subtitle Extended Track"
        XCTAssertTrue(app.buttons[longSubtitle].waitForExistence(timeout: 5)); app.buttons[longSubtitle].tap()
        let audio = app.buttons["detail.audio"], subtitle = app.buttons["detail.subtitle"]
        XCTAssertLessThanOrEqual(audio.frame.maxY, subtitle.frame.minY)
        XCTAssertFalse(app.buttons["detail.quality"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Long track labels fixed"; shot.lifetime = .keepAlways; add(shot)
        let before = fixtureMetric("/mock/jellyfin/Users/fixture-user/Items/demo0")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["catalog.demo0"].tap()
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 10))
        XCTAssertEqual(fixtureMetric("/mock/jellyfin/Users/fixture-user/Items/demo0"), before, "Re-entering detail uses cached metadata")
        let imageCount = fixtureMetric("/mock/jellyfin/Items/demo0/Images/Primary")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["catalog.demo0"].waitForExistence(timeout: 10)); app.buttons["catalog.demo0"].tap()
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 10))
        XCTAssertEqual(fixtureMetric("/mock/jellyfin/Users/fixture-user/Items/demo0"), before, "Metadata persists on disk across process restarts")
        XCTAssertEqual(fixtureMetric("/mock/jellyfin/Items/demo0/Images/Primary"), imageCount, "Poster persists on disk across process restarts")
        app.swipeUp()
        let download = app.buttons["detail.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 8)); download.tap()
        XCTAssertTrue(app.buttons["加入下载队列"].firstMatch.waitForExistence(timeout: 5)); app.buttons["加入下载队列"].firstMatch.tap()
        app.buttons["离线下载"].tap()
        let offline = app.buttons["offline.play.demo0"]
        XCTAssertTrue(offline.waitForExistence(timeout: 30))
        let streamBefore = fixtureMetric("/mock/jellyfin/Videos/demo0/stream")
        offline.tap()
        XCTAssertTrue(app.otherElements["player.canvas"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 10)); app.buttons["暂停"].tap()
        XCTAssertTrue(app.staticTexts["本地播放"].exists)
        XCTAssertEqual(fixtureMetric("/mock/jellyfin/Videos/demo0/stream"), streamBefore)
        app.buttons["返回片库"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["媒体库"].tap()
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 8)); app.buttons["sources.open"].tap()
        let fixture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", fixtureName)).firstMatch
        fixture.swipeLeft(); app.buttons["移除"].tap(); app.buttons["同时删除此来源的离线影片"].firstMatch.tap(); app.buttons["完成"].tap()
    }

    private func fixtureMetric(_ path: String) -> Int {
        let done = expectation(description: "Local fixture metrics")
        var value = -1
        URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:8768/debug/metrics")!) { data, _, _ in
            if let data, let metrics = try? JSONDecoder().decode([String: Int].self, from: data) { value = metrics[path, default: 0] }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        XCTAssertGreaterThanOrEqual(value, 0)
        return value
    }

    @MainActor func testAutomaticPlaybackRecovery() async throws {
        let masterFixture = ProcessInfo.processInfo.environment["GLIDE_HLS_MASTER_FIXTURE"] == "1"
        let localFixture = URL(string: "http://127.0.0.1:8768/debug/metrics")!
        guard (try? await URLSession.shared.data(from: localFixture)) != nil else {
            throw XCTSkip("Run Scripts/fixture_server.py to test automatic playback recovery")
        }
        continueAfterFailure = false
        let negotiationBaseline = fixtureMetric("/mock/jellyfin/Items/broken/PlaybackInfo")
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "60"]
        app.launch()
        if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 8))
        app.buttons["sources.open"].tap()
        var fixtureName = "Glide Recovery Fixture"
        let existing = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@", "source.", fixtureName, "127.0.0.1:8768")).firstMatch
        if existing.exists {
            // A failed run can leave its local fixture source behind. Reuse
            // that source rather than accumulating more accounts on retries.
            for _ in 0..<8 {
                if existing.isHittable { break }
                app.collectionViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(existing.isHittable)
            existing.tap()
        } else {
            for _ in 0..<8 {
                if app.buttons["sources.add"].isHittable { break }
                app.collectionViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(app.buttons["sources.add"].waitForExistence(timeout: 5))
            app.buttons["sources.add"].tap()
            let name = app.textFields["名称（可选）"]
            if !name.waitForExistence(timeout: 5), app.buttons["sources.add"].isHittable { app.buttons["sources.add"].tap() }
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            fixtureName += " " + String(UUID().uuidString.prefix(6))
            name.tap()
            if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { name.tap() }
            name.typeText(fixtureName)
            let address = app.textFields["服务器地址"]
            address.tap(); address.typeText("http://127.0.0.1:8768/mock/jellyfin")
            let username = app.textFields["用户名"]
            username.tap(); username.typeText("demo")
            let password = app.secureTextFields["密码"]
            password.tap(); password.typeText("demo\n")
            app.buttons["sources.connect"].tap()
            let addSourceClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["添加媒体源"])
            let waitResult1 = await XCTWaiter.fulfillment(of: [addSourceClosed], timeout: 15)
            XCTAssertEqual(waitResult1, .completed, "Fixture login should close the add-source form")
            XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 15))
            app.buttons["完成"].tap()
        }
        let movies = app.buttons["folder.fixture-movies"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: movies)
        if await XCTWaiter.fulfillment(of: [ready], timeout: 5) != .completed, app.buttons["完成"].isHittable { app.buttons["完成"].tap() }
        let readyAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: movies)
        let waitResult2 = await XCTWaiter.fulfillment(of: [readyAgain], timeout: 8)
        XCTAssertEqual(waitResult2, .completed)
        movies.tap()
        XCTAssertTrue(app.buttons["catalog.sort"].waitForExistence(timeout: 10))
        let recoveryCard = app.buttons["catalog.broken"]
        XCTAssertTrue(recoveryCard.waitForExistence(timeout: 10))
        let cardReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: recoveryCard)
        let cardWait = await XCTWaiter.fulfillment(of: [cardReady], timeout: 10)
        XCTAssertEqual(cardWait, .completed)
        recoveryCard.tap()
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 10))
        app.buttons["从头播放"].tap()
        let delivery = app.staticTexts["player.delivery"]
        let allowedDeliveries = masterFixture ? ["服务器流（方式待确认）", "视频转码"] : ["视频转码"]
        let converted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value IN %@", allowedDeliveries), object: delivery)
        let waitResult3 = await XCTWaiter.fulfillment(of: [converted], timeout: 45)
        if waitResult3 != .completed {
            if !app.buttons["播放设置"].isHittable { app.otherElements["player.canvas"].tap() }
            if app.buttons["播放设置"].isHittable {
                app.buttons["播放设置"].tap()
                if app.buttons["player.diagnostic"].waitForExistence(timeout: 3) {
                    app.buttons["player.diagnostic"].tap()
                    let json = app.staticTexts["diagnostic.json"]
                    if json.waitForExistence(timeout: 3) {
                        let diagnostic = XCTAttachment(string: json.label)
                        diagnostic.name = "Recovery failure diagnostic"; diagnostic.lifetime = .keepAlways; add(diagnostic)
                        print("Local recovery fixture diagnostic: " + json.label)
                    }
                }
            }
        }
        XCTAssertEqual(waitResult3, .completed)
        let recoveredFrame = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: app.otherElements["player.canvas"])
        let waitResult4 = await XCTWaiter.fulfillment(of: [recoveredFrame], timeout: 20)
        XCTAssertEqual(waitResult4, .completed, "HLS recovery must display a video frame")
        if !app.descendants(matching: .any)["player.seekBar"].exists { app.otherElements["player.canvas"].tap() }
        let buffered = app.sliders["player.seekBar"]
        XCTAssertTrue(buffered.waitForExistence(timeout: 5))
        let hasBufferedMedia = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "至"), object: buffered)
        let waitResult5 = await XCTWaiter.fulfillment(of: [hasBufferedMedia], timeout: 10)
        XCTAssertEqual(waitResult5, .completed, "HLS should report loaded segments")
        if !app.buttons["暂停"].isHittable { app.otherElements["player.canvas"].tap() }
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 10)); app.buttons["暂停"].tap()
        let finalDelivery = delivery.value as? String ?? ""
        XCTAssertTrue(allowedDeliveries.contains(finalDelivery))
        XCTAssertFalse(app.buttons["player.quality"].exists)
        let recovered = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        recovered.name = "Recovered video frame"; recovered.lifetime = .keepAlways; add(recovered)
        let firstNegotiations = fixtureMetric("/mock/jellyfin/Items/broken/PlaybackInfo")
        if masterFixture {
            XCTAssertEqual(firstNegotiations - negotiationBaseline, finalDelivery == "视频转码" ? 2 : 1,
                           "The HDR master may play as native SDR or recover once; it must never be unwrapped")
            app.buttons["播放设置"].tap()
            XCTAssertTrue(app.buttons["player.diagnostic"].waitForExistence(timeout: 5))
            app.buttons["player.diagnostic"].tap()
            let json = app.staticTexts["diagnostic.json"]
            XCTAssertTrue(json.waitForExistence(timeout: 5))
            XCTAssertFalse(json.label.contains("hls_single_variant"), "HDR source must retain native master validation")
            XCTAssertTrue(json.label.contains("\"playlistMode\" : \"master\""))
            XCTAssertTrue(json.label.contains("HDR10"))
            XCTAssertTrue(json.label.contains("hdr_sdr_output_requested"))
            XCTAssertTrue(json.label.contains("\"requestedOutputRange\" : \"SDR\""))
            let fields = try JSONSerialization.jsonObject(with: Data(json.label.utf8)) as? [String: Any]
            XCTAssertEqual(fields?["outputColorTransfer"] as? String, "ITU_R_709_2", "The native decoded-frame probe must provide actual SDR color evidence")
            XCTAssertEqual(fields?["outputColorEvidence"] as? String, "decodedFrame")
            app.buttons["完成"].tap()
        }
        app.buttons["返回片库"].tap()
        if !masterFixture && firstNegotiations - negotiationBaseline == 2 {
            // A stuck direct stream must be remembered after conversion succeeds.
            XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 8))
            app.buttons["detail.play"].tap()
            let waitResult6 = await XCTWaiter.fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "视频转码"), object: app.staticTexts["player.delivery"])], timeout: 25)
            XCTAssertEqual(waitResult6, .completed)
            let waitResult7 = await XCTWaiter.fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: app.otherElements["player.canvas"])], timeout: 25)
            XCTAssertEqual(waitResult7, .completed)
            XCTAssertEqual(fixtureMetric("/mock/jellyfin/Items/broken/PlaybackInfo"), firstNegotiations + 1)
            app.buttons["返回片库"].tap()
        }
        // Keep this dedicated local fixture account for repeatable playback
        // runs. Source deletion is covered by the offline integrity test.
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }


    @MainActor func testTagsAndSimilarMedia() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_DAV_FIXTURE"] == "1" else {
            throw XCTSkip("Run Scripts/fixture_server.py and set GLIDE_DAV_FIXTURE=1")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 8))
        app.buttons["sources.open"].tap()
        if !app.buttons["sources.add"].waitForExistence(timeout: 3), app.buttons["sources.open"].exists { app.buttons["sources.open"].tap() }
        XCTAssertTrue(app.buttons["sources.add"].waitForExistence(timeout: 5))
        app.buttons["sources.add"].tap()
        let name = app.textFields["名称（可选）"]
        if !name.waitForExistence(timeout: 5), app.buttons["sources.add"].isHittable { app.buttons["sources.add"].tap() }
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let fixtureName = "Glide Discovery Fixture " + String(UUID().uuidString.prefix(6))
        name.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { name.tap() }
        name.typeText(fixtureName)
        let address = app.textFields["服务器地址"]
        address.tap(); address.typeText("http://127.0.0.1:8768/mock/jellyfin")
        let username = app.textFields["用户名"]
        username.tap(); username.typeText("demo")
        let password = app.secureTextFields["密码"]
        password.tap(); password.typeText("demo\n")
        app.buttons["sources.connect"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 15))
        app.buttons["完成"].tap()
        let movies = app.buttons["folder.fixture-movies"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: movies)
        if XCTWaiter.wait(for: [ready], timeout: 5) != .completed, app.buttons["完成"].isHittable { app.buttons["完成"].tap() }
        let readyAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: movies)
        XCTAssertEqual(XCTWaiter.wait(for: [readyAgain], timeout: 8), .completed)
        movies.tap()
        XCTAssertTrue(app.buttons["catalog.demo0"].waitForExistence(timeout: 10)); app.buttons["catalog.demo0"].tap()
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 10))
        let tag = app.buttons["facet.Tags:精彩 & 推荐"]
        for _ in 0..<6 { if tag.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(tag.isHittable); tag.tap()
        XCTAssertTrue(app.buttons["facet.media.demo0"].waitForExistence(timeout: 10))
        let more = app.buttons["facet.more"]
        for _ in 0..<3 { if more.isHittable { break }; app.swipeUp() }
        more.tap()
        XCTAssertTrue(app.buttons["facet.media.series"].waitForExistence(timeout: 10)); app.buttons["facet.media.series"].tap()
        XCTAssertTrue(app.buttons["detail.season"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let similar = app.buttons["similar.series"]
        for _ in 0..<6 { if similar.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(similar.isHittable)
        XCTAssertFalse(app.buttons["similar.demo0"].exists, "Do not recommend the current movie")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Tags and similar recommendations"; shot.lifetime = .keepAlways; add(shot)
        similar.tap()
        XCTAssertTrue(app.buttons["detail.season"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["媒体库"].tap()
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 8)); app.buttons["sources.open"].tap()
        let fixture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", fixtureName)).firstMatch
        fixture.swipeLeft(); app.buttons["移除"].tap(); app.buttons["同时删除此来源的离线影片"].firstMatch.tap(); app.buttons["完成"].tap()
    }

    @MainActor func testPersonPortraitAndRelatedMedia() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_DAV_FIXTURE"] == "1" else {
            throw XCTSkip("Run Scripts/fixture_server.py and set GLIDE_DAV_FIXTURE=1")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 8))
        app.buttons["sources.open"].tap()
        app.buttons["sources.add"].tap()
        let name = app.textFields["名称（可选）"]
        if !name.waitForExistence(timeout: 5), app.buttons["sources.add"].isHittable { app.buttons["sources.add"].tap() }
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let fixtureName = "Glide Person Fixture " + String(UUID().uuidString.prefix(6))
        name.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { name.tap() }
        name.typeText(fixtureName)
        let address = app.textFields["服务器地址"]
        address.tap(); address.typeText("http://127.0.0.1:8768/mock/jellyfin")
        let username = app.textFields["用户名"]
        username.tap(); username.typeText("demo")
        let password = app.secureTextFields["密码"]
        password.tap(); password.typeText("demo\n")
        app.buttons["sources.connect"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 15))
        app.buttons["完成"].tap()
        app.buttons["folder.fixture-movies"].tap()
        XCTAssertTrue(app.buttons["catalog.demo0"].waitForExistence(timeout: 10)); app.buttons["catalog.demo0"].tap()
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 10))
        app.swipeUp()
        let actor = app.buttons["person.person-a"]
        XCTAssertTrue(actor.waitForExistence(timeout: 8)); actor.tap()
        let firstMedia = app.buttons["person.media.demo0"]
        XCTAssertTrue(firstMedia.waitForExistence(timeout: 10))
        let personShot = XCTAttachment(screenshot: app.screenshot()); personShot.name = "Person related media"; personShot.lifetime = .keepAlways; add(personShot)
        let more = app.buttons["person.more"]
        if !more.isHittable { app.swipeUp() }
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        XCTAssertTrue(app.buttons["person.media.series"].waitForExistence(timeout: 8))
        app.buttons["person.media.series"].tap()
        XCTAssertTrue(app.buttons["detail.season"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let director = app.buttons["person.person-b"]
        if !director.isHittable { app.swipeUp() }
        XCTAssertTrue(director.waitForExistence(timeout: 5)); director.tap()
        XCTAssertTrue(app.staticTexts["暂无相关媒体"].waitForExistence(timeout: 8), "Same name, different person ID must not return the actor's films")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let castShot = XCTAttachment(screenshot: app.screenshot()); castShot.name = "Cast portraits"; castShot.lifetime = .keepAlways; add(castShot)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["媒体库"].tap()
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 8)); app.buttons["sources.open"].tap()
        let fixture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", fixtureName)).firstMatch
        fixture.swipeLeft(); app.buttons["移除"].tap(); app.buttons["同时删除此来源的离线影片"].firstMatch.tap(); app.buttons["完成"].tap()
    }

    @MainActor func testMovieAndTelevisionCatalog() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_DAV_FIXTURE"] == "1" else {
            throw XCTSkip("Run Scripts/fixture_server.py and set GLIDE_DAV_FIXTURE=1")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "8"]
        app.launch()
        if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 8))
        app.buttons["sources.open"].tap()
        app.buttons["sources.add"].tap()
        let name = app.textFields["名称（可选）"]
        if !name.waitForExistence(timeout: 5), app.buttons["sources.add"].isHittable { app.buttons["sources.add"].tap() }
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let fixtureName = "Glide Catalog Fixture " + String(UUID().uuidString.prefix(6))
        name.tap(); name.typeText(fixtureName)
        let address = app.textFields["服务器地址"]
        address.tap(); address.typeText("http://127.0.0.1:8768/mock/jellyfin")
        let username = app.textFields["用户名"]
        username.tap(); username.typeText("demo")
        let password = app.secureTextFields["密码"]
        password.tap(); password.typeText("demo\n")
        app.buttons["sources.connect"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 15))
        app.buttons["完成"].tap()
        let movies = app.buttons["folder.fixture-movies"]
        let moviesReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: movies)
        if XCTWaiter.wait(for: [moviesReady], timeout: 5) != .completed, app.buttons["完成"].isHittable { app.buttons["完成"].tap() }
        XCTAssertTrue(movies.waitForExistence(timeout: 10))
        movies.tap()
        XCTAssertTrue(app.buttons["catalog.demo0"].waitForExistence(timeout: 10))
        app.buttons["catalog.demo0"].tap()
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["简介"].exists)
        app.buttons["detail.audio"].tap()
        XCTAssertTrue(app.buttons["English DD_2.0 · Dolby Digital+ · Stereo · Original commentary track"].waitForExistence(timeout: 5))
        app.buttons["English DD_2.0 · Dolby Digital+ · Stereo · Original commentary track"].tap()
        app.buttons["detail.subtitle"].tap()
        XCTAssertTrue(app.buttons["中上英下 SUP_YYeTs 字幕 Chinese 默认 强制的 PGS Subtitle Extended Track"].waitForExistence(timeout: 5))
        app.buttons["中上英下 SUP_YYeTs 字幕 Chinese 默认 强制的 PGS Subtitle Extended Track"].tap()
        let movieShot = XCTAttachment(screenshot: app.screenshot()); movieShot.name = "Movie details"; movieShot.lifetime = .keepAlways; add(movieShot)
        app.buttons["detail.play"].tap()
        XCTAssertTrue(app.otherElements["player.canvas"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 15))
        let movieFrame = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: app.otherElements["player.canvas"])
        XCTAssertEqual(XCTWaiter.wait(for: [movieFrame], timeout: 20), .completed, "Movie must display a frame, not merely start the audio clock")
        app.buttons["暂停"].tap()
        XCTAssertFalse(app.buttons["player.mode"].exists)
        app.otherElements["player.canvas"].swipeLeft()
        XCTAssertTrue(app.otherElements["player.canvas"].label.contains("Fixture Movie"))
        app.buttons["返回片库"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["媒体库"].tap()
        XCTAssertTrue(app.buttons["folder.fixture-shows"].waitForExistence(timeout: 10))
        app.buttons["folder.fixture-shows"].tap()
        XCTAssertTrue(app.buttons["catalog.series"].waitForExistence(timeout: 10))
        app.buttons["catalog.series"].tap()
        let episode = app.buttons["episode.demo1"]
        if !episode.waitForExistence(timeout: 8) { app.swipeUp() }
        XCTAssertTrue(episode.waitForExistence(timeout: 8))
        XCTAssertLessThan(episode.frame.minY, app.buttons["episode.demo2"].frame.minY)
        let showShot = XCTAttachment(screenshot: app.screenshot()); showShot.name = "Season and episode ordering"; showShot.lifetime = .keepAlways; add(showShot)
        app.buttons["detail.season"].tap(); app.buttons["Season 2"].tap()
        XCTAssertTrue(app.staticTexts["本季暂无可用剧集。"].waitForExistence(timeout: 8))
        app.buttons["detail.season"].tap(); app.buttons["Season 1"].tap()
        XCTAssertTrue(episode.waitForExistence(timeout: 8)); episode.tap()
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 8))
        app.buttons["detail.play"].tap()
        XCTAssertTrue(app.otherElements["player.canvas"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 15))
        let episodeFrame = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: app.otherElements["player.canvas"])
        XCTAssertEqual(XCTWaiter.wait(for: [episodeFrame], timeout: 20), .completed, "Episode must display a frame before playback is considered usable")
        app.buttons["暂停"].tap()
        app.buttons["下一集"].tap()
        XCTAssertTrue(app.otherElements["player.canvas"].label.contains("Episode Ten"))
        app.buttons["返回片库"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["媒体库"].tap()
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 8))
        app.buttons["sources.open"].tap()
        let fixture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", fixtureName)).firstMatch
        fixture.swipeLeft(); app.buttons["移除"].tap(); app.buttons["同时删除此来源的离线影片"].firstMatch.tap(); app.buttons["完成"].tap()
    }

    @MainActor func testEpisodeSwipeAndSelection() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_EPISODE_FIXTURE"] == "1" else {
            throw XCTSkip("Run the local fixture with GLIDE_EPISODE_FIXTURE=1")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "60"]
        app.launch()
        func open(_ button: XCUIElement, until target: XCUIElement) {
            for _ in 0..<3 {
                if target.exists && target.isHittable { return }
                if button.isHittable { button.press(forDuration: 0.15) }
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: target)
                if XCTWaiter.wait(for: [ready], timeout: 4) == .completed { return }
            }
            XCTAssertTrue(target.exists && target.isHittable)
        }
        if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists {
            open(app.buttons["媒体库"], until: app.buttons["sources.open"])
        }
        open(app.buttons["sources.open"], until: app.buttons["sources.add"])
        let name = app.textFields["名称（可选）"]
        open(app.buttons["sources.add"], until: name)
        let fixtureName = "Glide Episode Fixture " + String(UUID().uuidString.prefix(6))
        name.tap(); name.typeText(fixtureName)
        app.textFields["服务器地址"].tap(); app.textFields["服务器地址"].typeText("http://127.0.0.1:8768/mock/jellyfin")
        app.textFields["用户名"].tap(); app.textFields["用户名"].typeText("demo")
        app.secureTextFields["密码"].tap(); app.secureTextFields["密码"].typeText("demo\n")
        app.buttons["sources.connect"].press(forDuration: 0.15)
        let connected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", fixtureName)).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 15))
        open(app.buttons["完成"], until: app.buttons["folder.fixture-shows"])
        open(app.buttons["folder.fixture-shows"], until: app.buttons["catalog.series"])
        open(app.buttons["catalog.series"], until: app.buttons["detail.season"])
        let first = app.buttons["episode.demo1"]
        for _ in 0..<4 { if first.isHittable { break }; app.swipeUp() }
        open(first, until: app.buttons["detail.play"])
        let canvas = app.otherElements["player.canvas"]
        open(app.buttons["detail.play"], until: canvas)
        func pauseEpisode(_ title: String) {
            let frame = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", title, "已显示画面"), object: canvas)
            XCTAssertEqual(XCTWaiter.wait(for: [frame], timeout: 20), .completed)
            if !app.buttons["暂停"].exists { canvas.tap() }
            if app.buttons["暂停"].waitForExistence(timeout: 3) { app.buttons["暂停"].press(forDuration: 0.15) }
        }
        func swipeEpisode(forward: Bool) {
            let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: forward ? 0.58 : 0.30))
            let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: forward ? 0.30 : 0.58))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        pauseEpisode("Episode Two")
        XCTAssertFalse(app.buttons["上一集"].isEnabled)
        swipeEpisode(forward: false)
        XCTAssertTrue(canvas.label.contains("Episode Two"), "Swiping before the first episode must stay on that episode")
        swipeEpisode(forward: true); pauseEpisode("Episode Ten")
        canvas.tap()
        XCTAssertFalse(app.buttons["player.episodes"].exists)
        canvas.pinch(withScale: 2, velocity: 2)
        let zoom = Double((canvas.value as? String)?.split(separator: " ").dropFirst().first ?? "1") ?? 1
        XCTAssertGreaterThan(zoom, 1.1)
        swipeEpisode(forward: false)
        XCTAssertTrue(canvas.label.contains("Episode Ten"), "Zoomed gestures pan the picture instead of switching episodes")
        canvas.pinch(withScale: 0.25, velocity: -2)
        swipeEpisode(forward: false); pauseEpisode("Episode Two")
        open(app.buttons["player.episodes"], until: app.buttons["player.episode.demo1"])
        XCTAssertTrue(app.buttons["player.episode.demo1"].label.contains("正在播放"))
        XCTAssertTrue(app.buttons["player.episode.demo2"].exists)
        XCTAssertFalse(app.buttons["player.episode.demo0"].exists)
        open(app.buttons["player.episodeSeason"], until: app.buttons["第 2 季"])
        open(app.buttons["第 2 季"], until: app.buttons["player.episode.demo0"])
        open(app.buttons["player.episode.demo0"], until: app.buttons["player.episodes"])
        pauseEpisode("Season Two Premiere")
        XCTAssertFalse(app.buttons["下一集"].isEnabled)
        swipeEpisode(forward: true)
        XCTAssertTrue(canvas.label.contains("Season Two Premiere"), "The last episode must not wrap around")
        swipeEpisode(forward: false); pauseEpisode("Episode Ten")
        // Picking the current episode dismisses the sheet without starting it again.
        let elapsed = app.staticTexts["player.elapsed"].label
        open(app.buttons["player.episodes"], until: app.buttons["player.episode.demo2"])
        open(app.buttons["player.episode.demo2"], until: app.buttons["player.episodes"])
        XCTAssertEqual(app.staticTexts["player.elapsed"].label, elapsed)
        XCTAssertTrue(app.buttons["播放"].exists)
        let beforeLock = canvas.label
        app.buttons["锁定触控"].press(forDuration: 0.15)
        XCTAssertTrue(app.buttons["解锁触控"].waitForExistence(timeout: 4), "Lock action must visibly enter the locked state")
        swipeEpisode(forward: true)
        let lockShot = XCTAttachment(screenshot: app.screenshot()); lockShot.name = "Episode locked"; lockShot.lifetime = .keepAlways; add(lockShot)
        XCTAssertEqual(canvas.label, beforeLock)
        XCTAssertTrue(canvas.label.contains("Episode Ten"), "Locking disables episode swipes")
        app.buttons["解锁触控"].press(forDuration: 0.15)
        open(app.buttons["返回片库"], until: app.buttons["detail.play"])
        app.tabBars.buttons["继续与收藏"].tap()
        let showRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "personal.video.", fixtureName))
        XCTAssertTrue(showRows.firstMatch.waitForExistence(timeout: 8)); XCTAssertEqual(showRows.count, 1, "Episode history is one series entry")
        XCTAssertTrue(showRows.firstMatch.label.contains("Fixture Show"))
        app.tabBars.buttons["片库"].tap()
        app.navigationBars.buttons.element(boundBy: 0).press(forDuration: 0.15)
        app.navigationBars.buttons.element(boundBy: 0).press(forDuration: 0.15)
        open(app.buttons["媒体库"], until: app.buttons["sources.open"])
        open(app.buttons["sources.open"], until: app.buttons["sources.add"])
        connected.swipeLeft(); app.buttons["移除"].tap(); app.buttons["同时删除此来源的离线影片"].firstMatch.tap(); app.buttons["完成"].tap()
    }

    @MainActor func testScopeSortAndPinnedDirectory() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_DAV_FIXTURE"] == "1" else {
            throw XCTSkip("Run Scripts/fixture_server.py and set GLIDE_DAV_FIXTURE=1")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-homeBrowseView", "videos"]
        app.launch()
        if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
        app.buttons["sources.open"].tap()
        app.buttons["sources.add"].tap()
        let name = app.textFields["名称（可选）"]
        if !name.waitForExistence(timeout: 5), app.buttons["sources.add"].isHittable { app.buttons["sources.add"].tap() }
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let fixtureName = "Glide Queue Fixture " + String(UUID().uuidString.prefix(6))
        name.tap(); name.typeText(fixtureName)
        let address = app.textFields["服务器地址"]
        address.tap(); address.typeText("http://127.0.0.1:8768/mock/jellyfin")
        let username = app.textFields["用户名"]
        username.tap(); username.typeText("demo")
        let password = app.secureTextFields["密码"]
        password.tap(); password.typeText("demo\n")
        app.buttons["sources.connect"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 15))
        app.buttons["完成"].tap()
        let folder = app.buttons["folder.fixture-library"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        XCTAssertTrue(NSPredicate(format: "hittable == true").evaluate(with: folder) || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: folder)], timeout: 8) == .completed)
        folder.tap()
        XCTAssertTrue(app.staticTexts["包含子目录 · 共 3 个视频"].waitForExistence(timeout: 5))
        app.buttons["directory.pin"].tap()
        XCTAssertTrue(app.buttons["directory.pin"].label.contains("取消固定"))
        app.buttons["library.scope"].tap()
        app.buttons["仅当前层"].tap()
        XCTAssertTrue(app.staticTexts["仅当前层 · 共 0 个视频"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["folder.fixture-parent"].exists, "Video view must not render directory tiles")
        let search = app.textFields["library.search"]
        search.tap(); search.typeText("Fixture C\n")
        XCTAssertTrue(app.staticTexts["仅当前层 · 0 个匹配结果"].waitForExistence(timeout: 8))
        app.buttons["library.scope"].tap()
        app.buttons["包含子目录"].tap()
        XCTAssertTrue(app.staticTexts["包含子目录 · 1 个匹配结果"].waitForExistence(timeout: 8), "Changing scope keeps and reruns the search")
        app.buttons["清除搜索"].tap()
        app.buttons["library.sort"].tap()
        app.buttons["名称降序"].tap()
        XCTAssertTrue(app.staticTexts["包含子目录 · 共 3 个视频"].waitForExistence(timeout: 8))
        app.segmentedControls.buttons["顺序播放"].tap()
        app.buttons["directory.play"].tap()
        let canvas = app.otherElements["player.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertTrue(canvas.label.contains("Fixture C"), "Descending queue starts with C")
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 15))
        app.buttons["暂停"].tap()
        app.buttons["返回片库"].tap()
        app.buttons["directory.back"].tap()
        XCTAssertTrue(app.buttons["folder.fixture-library"].waitForExistence(timeout: 5))
        app.buttons["pins.open"].tap()
        let pin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pin.")).firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        XCTAssertTrue(app.buttons["library.sort"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["library.sort"].label.contains("名称升序"), "Opening a saved view restores its own original sort rule")
        app.buttons["library.scope"].tap(); app.buttons["仅当前层"].tap()
        XCTAssertTrue(app.staticTexts["仅当前层 · 共 0 个视频"].waitForExistence(timeout: 8))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["仅当前层 · 共 0 个视频"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["library.sort"].label.contains("名称升序"), "Opening a saved view restores its own original sort rule")
        app.buttons["pins.open"].tap()
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "Pinned directory survives relaunch")
        pin.swipeRight()
        if !app.textFields["bookmark.name"].exists { app.buttons["编辑"].tap() }
        let savedName = app.textFields["bookmark.name"]
        XCTAssertTrue(savedName.waitForExistence(timeout: 5)); savedName.tap()
        savedName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (savedName.value as? String ?? "").count) + "家庭常看")
        app.buttons["bookmark.sort"].tap(); app.buttons["名称降序"].firstMatch.tap()
        app.buttons["bookmark.mode"].tap(); app.buttons["随机播放"].firstMatch.tap()
        app.buttons["bookmark.save"].tap()
        XCTAssertTrue(pin.waitForExistence(timeout: 5)); XCTAssertTrue(pin.label.contains("家庭常看"))
        pin.swipeLeft(); app.buttons["取消固定"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["directory.pin"].label.contains("固定此目录"))
        app.buttons["sources.open"].tap()
        let fixture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", fixtureName)).firstMatch
        fixture.swipeLeft(); app.buttons["移除"].tap(); app.buttons["同时删除此来源的离线影片"].firstMatch.tap(); app.buttons["完成"].tap()
    }

    @MainActor func testScopedSearchAndPersonalLibrary() throws {
        let fixtureURL = URL(string: "http://127.0.0.1:8768/debug/metrics")!
        guard (try? Data(contentsOf: fixtureURL)) != nil else {
            throw XCTSkip("Run Scripts/fixture_server.py to test scoped search and history")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-homeBrowseView", "videos"]
        app.launch()
        app.buttons["sources.open"].tap()
        app.buttons["sources.add"].tap()
        let name = app.textFields["名称（可选）"]
        if !name.waitForExistence(timeout: 5), app.buttons["sources.add"].isHittable { app.buttons["sources.add"].tap() }
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let fixtureName = "Glide Queue Fixture " + String(UUID().uuidString.prefix(6))
        name.tap(); name.typeText(fixtureName)
        let address = app.textFields["服务器地址"]
        address.tap(); address.typeText("http://127.0.0.1:8768/mock/jellyfin")
        let username = app.textFields["用户名"]
        username.tap(); username.typeText("demo")
        let password = app.secureTextFields["密码"]
        password.tap(); password.typeText("demo\n")
        app.buttons["sources.connect"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 15))
        app.buttons["完成"].tap()
        let folder = app.buttons["folder.fixture-library"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()
        XCTAssertTrue(app.staticTexts["包含子目录 · 共 3 个视频"].waitForExistence(timeout: 5))
        let search = app.textFields["library.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            search.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Search field should have keyboard focus before typing")
        search.typeText("Fixture C\n")
        XCTAssertTrue(app.staticTexts["包含子目录 · 1 个匹配结果"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["video.demo0"].exists)
        let card = app.buttons["video.demo2"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        for _ in 0..<3 { if card.isHittable { break }; app.swipeUp() }
        card.tap()
        let canvas = app.otherElements["player.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertTrue(canvas.label.contains("Fixture C"))
        XCTAssertTrue(app.staticTexts["1 / 1"].exists, "Search playback must use the filtered queue")
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 15))
        app.buttons["播放设置"].tap()
        XCTAssertTrue(app.buttons["视频信息"].waitForExistence(timeout: 5))
        app.buttons["视频信息"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "AVPlayer")).firstMatch.waitForExistence(timeout: 5), "Remote Jellyfin feed should use the native player")
        app.buttons["完成"].tap()
        app.buttons["暂停"].tap()
        let beforeSeek = app.staticTexts["player.elapsed"].label
        app.sliders["player.seekBar"].adjust(toNormalizedSliderPosition: 0.35)
        let seekCompleted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", beforeSeek), object: app.staticTexts["player.elapsed"])
        XCTAssertEqual(XCTWaiter.wait(for: [seekCompleted], timeout: 8), .completed, "Native Jellyfin playback must react to slider seeking")
        app.buttons["播放设置"].tap(); app.buttons["收藏视频"].tap()
        app.buttons["返回片库"].tap()
        app.tabBars.buttons["继续与收藏"].tap()
        let history = app.buttons["personal.video.demo2"]
        XCTAssertFalse(history.exists, "Browsing playback must not create a history entry")
        app.segmentedControls.buttons["我的收藏"].tap()
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        app.tabBars.buttons["片库"].tap()
        app.terminate(); app.launch()
        app.tabBars.buttons["继续与收藏"].tap()
        app.segmentedControls.buttons["我的收藏"].tap()
        XCTAssertTrue(history.waitForExistence(timeout: 5), "Favorite survives app relaunch")
        history.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertTrue(canvas.label.contains("Fixture C"))
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 15))
        app.buttons["暂停"].tap()
        app.buttons["返回片库"].tap()
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.swipeLeft(); app.buttons["取消收藏"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: history)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        app.tabBars.buttons["片库"].tap()
        app.terminate(); app.launch()
        app.tabBars.buttons["继续与收藏"].tap()
        XCTAssertFalse(history.exists)
        app.segmentedControls.buttons["我的收藏"].tap(); XCTAssertFalse(history.exists)
        app.tabBars.buttons["片库"].tap()
        app.buttons["sources.open"].tap()
        let fixture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", fixtureName)).firstMatch
        fixture.swipeLeft(); app.buttons["移除"].tap(); app.buttons["同时删除此来源的离线影片"].firstMatch.tap(); app.buttons["完成"].tap()
    }

    @MainActor func testFlattenedLibraryVideos() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_DAV_FIXTURE"] == "1" else {
            throw XCTSkip("Run Scripts/fixture_server.py and set GLIDE_DAV_FIXTURE=1")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "30"]
        app.launch()
        func open(_ button: XCUIElement, until element: XCUIElement) {
            for _ in 0..<3 {
                if element.exists && element.isHittable { return }
                if button.isHittable { button.press(forDuration: 0.15) }
                let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
                if XCTWaiter.wait(for: [visible], timeout: 4) == .completed { return }
            }
            XCTAssertTrue(element.exists && element.isHittable)
        }
        open(app.buttons["sources.open"], until: app.buttons["sources.add"])
        let name = app.textFields["名称（可选）"]
        open(app.buttons["sources.add"], until: name)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let fixtureName = "Glide Queue Fixture " + String(UUID().uuidString.prefix(6))
        name.tap(); name.typeText(fixtureName)
        let address = app.textFields["服务器地址"]
        address.tap(); address.typeText("http://127.0.0.1:8768/mock/jellyfin")
        let username = app.textFields["用户名"]
        username.tap(); username.typeText("demo")
        let password = app.secureTextFields["密码"]
        password.tap(); password.typeText("demo\n")
        app.buttons["sources.connect"].press(forDuration: 0.15)
        let connected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", fixtureName)).firstMatch
        XCTAssertTrue(connected.waitForExistence(timeout: 15))
        let folder = app.buttons["folder.fixture-library"]
        open(app.buttons["完成"], until: folder)
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        let browse = app.segmentedControls["library.contentView"]
        open(folder, until: browse)
        open(browse.buttons["视频"], until: app.buttons["directory.play"])
        XCTAssertTrue(app.staticTexts["包含子目录 · 共 3 个视频"].waitForExistence(timeout: 5))
        XCTAssertTrue(browse.buttons["视频"].isSelected)
        XCTAssertFalse(app.buttons["folder.fixture-parent"].exists)
        XCTAssertFalse(app.buttons["folders.sort"].exists)
        for _ in 0..<4 {
            if app.buttons["video.demo2"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["video.demo0"].exists)
        XCTAssertTrue(app.buttons["video.demo2"].waitForExistence(timeout: 5), "Preview must load the second recursive page")
        let canvas = app.otherElements["player.canvas"]
        open(app.buttons["video.demo2"], until: canvas)
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertTrue(canvas.label.contains("Fixture C"), "Tapping a descendant thumbnail starts that video")
        if !app.buttons["返回片库"].exists { canvas.tap() }
        open(app.buttons["返回片库"], until: app.buttons["directory.back"])
        // Mode changes must work after scrolling a recursive video list.
        for _ in 0..<4 { if browse.isHittable { break }; app.swipeDown() }
        open(browse.buttons["目录"], until: app.buttons["folder.fixture-parent"])
        XCTAssertTrue(browse.buttons["目录"].isSelected)
        XCTAssertTrue(app.buttons["folders.sort"].exists)
        XCTAssertFalse(app.textFields["library.search"].exists)
        XCTAssertFalse(app.buttons["directory.play"].exists)
        XCTAssertFalse(app.buttons["video.demo0"].exists)
        open(app.buttons["folder.fixture-parent"], until: app.buttons["folder.fixture-leaf"])
        XCTAssertTrue(app.buttons["folder.fixture-leaf"].waitForExistence(timeout: 5))
        XCTAssertTrue(browse.buttons["目录"].isSelected, "Entering a subdirectory keeps the selected view")
        XCTAssertFalse(app.buttons["directory.play"].exists)
        app.buttons["directory.refresh"].press(forDuration: 0.15)
        XCTAssertTrue(app.buttons["folder.fixture-leaf"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["-controlsDelay", "30"]
        app.launch()
        XCTAssertTrue(app.buttons["folder.fixture-leaf"].waitForExistence(timeout: 10))
        XCTAssertTrue(browse.buttons["目录"].isSelected, "The view selection survives relaunch")
        open(browse.buttons["视频"], until: app.buttons["directory.play"])
        XCTAssertTrue(app.textFields["library.search"].exists)
        XCTAssertTrue(app.buttons["library.scope"].exists)
        XCTAssertTrue(app.buttons["library.sort"].exists)
        XCTAssertFalse(app.buttons["folder.fixture-leaf"].exists)
        open(browse.buttons["目录"], until: app.buttons["folder.fixture-leaf"])
        open(app.buttons["directory.back"], until: app.buttons["folder.fixture-parent"])
        XCTAssertTrue(app.buttons["folder.fixture-parent"].waitForExistence(timeout: 5))
        open(app.buttons["directory.back"], until: folder)
        XCTAssertTrue(app.buttons["folder.fixture-library"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["video.demo0"].exists, "Returning to library selection clears scoped thumbnails")
        XCTAssertFalse(browse.exists, "Library selection itself has no video/directory switch")
        open(app.buttons["sources.open"], until: app.buttons["sources.add"])
        let fixture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", fixtureName)).firstMatch
        fixture.swipeLeft(); app.buttons["移除"].tap(); app.buttons["同时删除此来源的离线影片"].firstMatch.tap(); app.buttons["完成"].tap()
    }

    @MainActor func testRecursiveDirectoryPlaybackModes() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_DAV_FIXTURE"] == "1" else {
            throw XCTSkip("Run Scripts/fixture_server.py and set GLIDE_DAV_FIXTURE=1")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-homeBrowseView", "videos"]
        app.launch()
        app.buttons["sources.open"].tap()
        app.buttons["sources.add"].tap()
        let name = app.textFields["名称（可选）"]
        if !name.waitForExistence(timeout: 5), app.buttons["sources.add"].isHittable { app.buttons["sources.add"].tap() }
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let fixtureName = "Glide Queue Fixture " + String(UUID().uuidString.prefix(6))
        name.tap(); name.typeText(fixtureName)
        let address = app.textFields["服务器地址"]
        address.tap(); address.typeText("http://127.0.0.1:8768/mock/jellyfin")
        let username = app.textFields["用户名"]
        username.tap(); username.typeText("demo")
        let password = app.secureTextFields["密码"]
        password.tap(); password.typeText("demo\n")
        app.buttons["sources.connect"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 15))
        app.buttons["完成"].tap()
        let folder = app.buttons["folder.fixture-library"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()
        XCTAssertTrue(app.staticTexts["包含子目录 · 共 3 个视频"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["顺序播放"].tap()
        app.buttons["刷本目录"].tap()
        let canvas = app.otherElements["player.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1 / 3"].waitForExistence(timeout: 5), "Both pages of descendant videos must be collected")
        XCTAssertTrue(canvas.label.contains("Fixture A"))
        let advanced = NSPredicate(format: "label CONTAINS %@", "Fixture B")
        expectation(for: advanced, evaluatedWith: canvas)
        waitForExpectations(timeout: 25)
        if !app.buttons["返回片库"].exists { canvas.tap() }
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 15))
        app.buttons["暂停"].tap()
        let title = canvas.label
        let mode = app.buttons["player.mode"]
        mode.tap()
        XCTAssertEqual(canvas.label, title, "Switching mode must not restart or change the current video")
        XCTAssertTrue(mode.label.contains("随机播放"))
        app.buttons["下一个视频"].tap()
        XCTAssertNotEqual(canvas.label, title)
        if !app.buttons["上一个视频"].exists { canvas.tap() }
        app.buttons["上一个视频"].tap()
        XCTAssertEqual(canvas.label, title)
        if !app.buttons["返回片库"].exists { canvas.tap() }
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 10))
        app.buttons["暂停"].tap()
        XCTAssertFalse(app.buttons["player.quality"].exists)
        XCTAssertFalse(app.staticTexts["暂时无法播放"].exists)
        app.buttons["返回片库"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["随机播放"].isSelected)
        app.segmentedControls.buttons["顺序播放"].tap()
        app.buttons["sources.open"].tap()
        let fixture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", fixtureName)).firstMatch
        fixture.swipeLeft(); app.buttons["移除"].tap(); app.buttons["同时删除此来源的离线影片"].firstMatch.tap(); app.buttons["完成"].tap()
    }

    @MainActor func testStageSettingsAndDiagnostics() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["设置"].waitForExistence(timeout: 10))
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["声音与字幕"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["下载与存储"].exists)
        let diagnostics = app.buttons["最近一次播放诊断"]
        for _ in 0..<4 { if diagnostics.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(diagnostics.isHittable)
        diagnostics.tap()
        XCTAssertTrue(app.buttons["diagnostic.share"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["播放诊断"].exists)
    }

    @MainActor func testCleanupLocalFixtures() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_CLEANUP_FIXTURES"] == "1" else {
            throw XCTSkip("Opt-in cleanup of local integration-test sources only")
        }
        let app = XCUIApplication()
        app.launch()
        if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 8))
        app.buttons["sources.open"].tap()
        let query = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@", "source.", "127.0.0.1:8768", "Fixture"))
        for _ in 0..<20 {
            guard query.firstMatch.waitForExistence(timeout: 2) else { break }
            let identifier = query.firstMatch.identifier
            let fixture = app.buttons[identifier]
            guard fixture.exists else { continue }
            fixture.swipeLeft(); app.buttons["移除"].tap(); app.buttons["同时删除此来源的离线影片"].firstMatch.tap()
            let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: fixture)
            XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        }
        XCTAssertEqual(query.count, 0)
        let realServer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", "https://")).firstMatch
        if realServer.exists { realServer.tap() }
        else if app.buttons["完成"].exists { app.buttons["完成"].tap() }
    }

}
