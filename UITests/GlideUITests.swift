import XCTest
import UIKit
import Vision

extension GlideUITests {
    @MainActor private func discoveryApp(reset: Bool = true) throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["GLIDE_DISCOVERY_FIXTURE"] == "1" else { throw XCTSkip("Authored discovery UI acceptance only") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-discovery-fixture", "-controlsDelay", "120", "-selectedServer", "00000000-0000-0000-0000-000000000000"]
        if reset { app.launchArguments.append("--glide-discovery-reset") }
        app.launch()
        XCTAssertTrue(app.buttons["discovery.time.open"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor func testDiscoveryChannelCreateAutomaticAdvanceEditAndRestart() throws {
        let app = try discoveryApp()
        app.buttons["discovery.channel.create"].tap()
        let name = app.textFields["discovery.channel.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count) + "下饭频道")
        app.buttons["discovery.channel.save"].tap()
        let channel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "discovery.channel.", "下饭频道")).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 8)); channel.tap()
        let play = app.buttons["discovery.channel.play"]
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND label CONTAINS %@", "3"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 15), .completed)
        let secondRow = app.descendants(matching: .any)["discovery.queue.1"].firstMatch
        XCTAssertTrue(secondRow.waitForExistence(timeout: 5))
        let secondTitle = secondRow.label
        XCTAssertFalse(secondTitle.isEmpty)
        let preview = XCTAttachment(screenshot: app.screenshot()); preview.name = "Private Channel Preview"; preview.lifetime = .keepAlways; add(preview)
        play.tap()
        let canvas = app.otherElements["player.canvas"]
        let frame = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [frame], timeout: 20), .completed)
        XCTAssertFalse(app.buttons["player.mode"].exists, "Channel order must remain protected from file-level shuffle")
        let automatic = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", secondTitle, "已显示画面"), object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [automatic], timeout: 25), .completed, "Actual EOF must automatically open the next channel item")
        XCTAssertTrue(app.buttons["上一个视频"].isEnabled)
        app.buttons["暂停"].tap()
        let playerShot = XCTAttachment(screenshot: app.screenshot()); playerShot.name = "Private Channel Playing"; playerShot.lifetime = .keepAlways; add(playerShot)
        app.buttons["返回频道"].tap()
        let reduced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND label CONTAINS %@", "1"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [reduced], timeout: 10), .completed, "Only actual first frames should enter recent-play exclusion")
        chooseMenuItem("编辑频道", from: "discovery.channel.more", in: app)
        let recent = app.switches["discovery.channel.recent"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(recent.value as? String, "0")
        XCTAssertTrue(app.buttons["discovery.channel.save"].isEnabled)
        app.buttons["discovery.channel.save"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND label CONTAINS %@", "3"), object: play)], timeout: 10), .completed)
        app.terminate()
        let reopened = try discoveryApp(reset: false)
        XCTAssertTrue(reopened.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "discovery.channel.", "下饭频道")).firstMatch.waitForExistence(timeout: 8))
    }
    @MainActor func testDiscoveryTimePickPreferencesScopeAndActualPlayback() throws {
        let app = try discoveryApp()
        let home = XCTAttachment(screenshot: app.screenshot()); home.name = "Discovery Home"; home.lifetime = .keepAlways; add(home)
        app.buttons["discovery.time.open"].tap()
        let picks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.pick."))
        XCTAssertTrue(picks.firstMatch.waitForExistence(timeout: 15)); XCTAssertEqual(picks.count, 3)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "可在 45 分钟内看完")).firstMatch.exists)
        chooseMenuItem("电影", from: "discovery.time.preference", in: app)
        XCTAssertTrue(app.staticTexts["当前没有合适的内容"].waitForExistence(timeout: 5))
        chooseMenuItem("都可以", from: "discovery.time.preference", in: app)
        XCTAssertTrue(picks.firstMatch.waitForExistence(timeout: 5))
        let segments = app.segmentedControls["discovery.time.minutes"]
        segments.buttons["20 分钟"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "可在 20 分钟内看完")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["discovery.time.scopes"].tap()
        XCTAssertTrue(app.buttons["discovery.scope.current"].waitForExistence(timeout: 5))
        app.buttons["discovery.scope.done"].tap()
        XCTAssertTrue(picks.firstMatch.waitForExistence(timeout: 5))
        app.buttons["discovery.time.refresh"].tap()
        XCTAssertTrue(app.staticTexts["符合条件的候选数量有限，已重新展示。"].waitForExistence(timeout: 5))
        let timeShot = XCTAttachment(screenshot: app.screenshot()); timeShot.name = "Time Recommendations"; timeShot.lifetime = .keepAlways; add(timeShot)
        picks.firstMatch.tap()
        let canvas = app.otherElements["player.canvas"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)], timeout: 20), .completed)
        app.buttons["暂停"].tap(); app.buttons["返回选片"].tap()
        XCTAssertTrue(picks.firstMatch.waitForExistence(timeout: 10))
    }
    @MainActor func testDiscoveryProductionPlayerQueueAndIsolatedStoreProbe() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_DISCOVERY_FIXTURE"] == "1" else { throw XCTSkip("Authored discovery production acceptance only") }
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--glide-discovery-probe"]; app.launch()
        let status = app.staticTexts["discovery.probe.status"]
        let passed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "私人频道与时间选片验证通过"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [passed], timeout: 100), .completed)
        XCTAssertEqual(app.staticTexts["discovery.probe.count"].label, "通过 12 项")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Discovery Production Probe"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testDiscoveryScopedServerSelectionPagingAndPlayback() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_DISCOVERY_SERVER_FIXTURE"] == "1" else { throw XCTSkip("Loopback-only authored server on 8768") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-discovery-fixture", "--glide-discovery-reset", "--glide-jellyfin-fixture", "-controlsDelay", "120"]
        app.launch()
        XCTAssertTrue(app.buttons["discovery.time.open"].waitForExistence(timeout: 15)); app.buttons["discovery.time.open"].tap()
        app.buttons["discovery.time.scopes"].tap()
        let fixture = app.buttons["Glide Recovery Fixture"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 15))
        let removes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "移除“"))
        for _ in 0..<16 { if removes.count == 0 { break }; removes.firstMatch.tap() }
        fixture.tap()
        let movies = app.buttons["选择“Fixture Movies”"]
        XCTAssertTrue(movies.waitForExistence(timeout: 15)); movies.tap()
        app.buttons["discovery.scope.done"].tap()
        let picks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "discovery.pick."))
        XCTAssertTrue(picks.firstMatch.waitForExistence(timeout: 20)); XCTAssertEqual(picks.count, 2, "Both forced API pages of the selected movie library must be included")
        XCTAssertTrue(app.staticTexts["Fixture Movies"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Scoped Server Recommendations"; shot.lifetime = .keepAlways; add(shot)
        picks.firstMatch.tap()
        let canvas = app.otherElements["player.canvas"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)], timeout: 25), .completed)
        app.buttons["暂停"].tap(); app.buttons["返回选片"].tap()
        XCTAssertTrue(picks.firstMatch.waitForExistence(timeout: 15))
    }
}

final class GlideUITests: XCTestCase {
    @MainActor func testNativeAppearanceAndLibraryNavigation() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_NATIVE_UI_FIXTURE"] == "1" else { throw XCTSkip("Isolated simulator appearance review only") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-link-fixture"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 15))
        openLinks(in: app)
        app.buttons["完成"].tap()
        revealLibraryAction("pins.open", in: app); app.buttons["pins.open"].tap()
        XCTAssertTrue(app.navigationBars["固定目录"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.tabBars.buttons["设置"].tap()
        let appearance = app.descendants(matching: .any)["settings.appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        for mode in ["深色", "浅色", "跟随系统"] {
            chooseMenuItem(mode, from: "settings.appearance", in: app)
            if app.navigationBars.buttons["设置"].exists { app.navigationBars.buttons["设置"].tap() }
            XCTAssertTrue(appearance.waitForExistence(timeout: 5))
            XCTAssertTrue(appearance.label.contains(mode) || (appearance.value as? String ?? "").contains(mode))
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Native Appearance " + mode; shot.lifetime = .keepAlways; add(shot)
        }
        app.tabBars.buttons["离线"].tap()
        XCTAssertTrue(app.staticTexts["downloads.storage"].waitForExistence(timeout: 5))
        app.tabBars.buttons["片库"].tap()
        XCTAssertTrue(app.buttons["library.more"].waitForExistence(timeout: 5))
    }
    @MainActor func testPhysicalUIWalkthrough() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_DEVICE_UI_AUDIT"] == "1" else { throw XCTSkip("Explicit physical-device UI audit only") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.songpeng.glide")
        app.launchArguments = ["--glide-ui-audit", "-controlsDelay", "120"]
        app.launch()
        let phase = ProcessInfo.processInfo.environment["GLIDE_DEVICE_UI_AUDIT_PHASE"] ?? "Baseline"
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = phase + "-" + name; shot.lifetime = .keepAlways; add(shot)
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 25))
        capture("01-Library")
        let settings = app.tabBars.buttons["设置"]
        XCTAssertTrue(settings.exists); settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.screen"].firstMatch.waitForExistence(timeout: 8)); capture("02-Settings")
        app.swipeUp(); capture("03-Settings-Footer")
        app.tabBars.buttons["离线"].tap(); capture("04-Downloads")
        let personalTab = app.tabBars.buttons.element(boundBy: 1)
        personalTab.tap(); capture("05-Continue")
        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'personal.video.'")).firstMatch
        if recent.waitForExistence(timeout: 8) {
            recent.tap()
            let canvas = app.otherElements["player.canvas"]
            XCTAssertTrue(canvas.waitForExistence(timeout: 15))
            _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已显示画面'"), object: canvas)], timeout: 40)
            capture("06-Player-Portrait")
            if app.buttons["暂停"].exists { pausePlayerAndWait(app) }
            if app.buttons["player.quick.audio"].exists && app.buttons["player.quick.audio"].isEnabled {
                app.buttons["player.quick.audio"].tap(); capture("07-Audio-Menu")
                app.tap()
            }
            if app.buttons["播放设置"].exists {
                app.buttons["播放设置"].tap(); capture("08-Player-Settings")
                if app.buttons["完成"].exists { app.buttons["完成"].tap() }
            }
            if app.buttons["player.rotate"].exists { app.buttons["player.rotate"].tap(); capture("09-Player-Landscape") }
            if app.buttons["返回片库"].exists { app.buttons["返回片库"].tap() }
            XCUIDevice.shared.orientation = .portrait
        }
        app.tabBars.buttons["片库"].tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'catalog.' AND identifier != 'catalog.sort' AND identifier != 'catalog.more' AND identifier != 'catalog.back'")).firstMatch
        if card.waitForExistence(timeout: 12) {
            card.tap(); capture("10-Detail-Top")
            app.swipeUp(); capture("11-Detail-Metadata")
            if app.navigationBars.buttons.firstMatch.exists { app.navigationBars.buttons.firstMatch.tap() }
        }
        if app.buttons["catalog.back"].exists { app.buttons["catalog.back"].tap() }
        else if app.buttons["返回媒体库"].exists { app.buttons["返回媒体库"].tap() }
        capture("12-Library-Root")
        if app.buttons["sources.open"].exists {
            app.buttons["sources.open"].tap(); capture("13-Sources")
            if app.buttons["完成"].exists { app.buttons["完成"].tap() }
        }
        capture("14-End")
    }
    @MainActor private func openTrackMenu(_ menu: XCUIElement, item: XCUIElement) {
        for _ in 0..<3 {
            if item.exists { return }
            menu.tap()
            if item.waitForExistence(timeout: 3) { return }
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Track menu must open after its preceding dismissal")
    }
    @MainActor private func pausePlayerAndWait(_ app: XCUIApplication) {
        for _ in 0..<3 {
            if app.buttons["播放"].exists { break }
            let pause = app.buttons["暂停"]
            XCTAssertTrue(pause.waitForExistence(timeout: 8)); pause.tap()
            if app.buttons["播放"].waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 5))
    }
    @MainActor func testJellyfinPGSAndAudioSwitchDuringPlayback() async throws {
        guard ProcessInfo.processInfo.environment["GLIDE_SUBTITLE_SWITCH_FIXTURE"] == "1" else { throw XCTSkip("Run original PGS and two-audio fixture on 8793") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-jellyfin-fixture", "-glideSubtitleSwitchFixture", "YES", "-controlsDelay", "120", "-preferredAudioLanguage", "", "-preferredSubtitleLanguage", "zh", "-forcedSubtitlesOnly", "NO"]
        app.launch(); await openProfessionalMovieCatalog(app)
        for _ in 0..<3 {
            if app.buttons["detail.play"].exists { break }
            app.buttons["catalog.demo0"].tap()
            if app.buttons["detail.play"].waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 10)); app.buttons["detail.play"].tap()
        let canvas = app.otherElements["player.canvas"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已显示画面'"), object: canvas)], timeout: 30), .completed)
        pausePlayerAndWait(app)
        let captions = app.descendants(matching: .any)["player.quick.subtitle"].firstMatch, audio = app.descendants(matching: .any)["player.quick.audio"].firstMatch
        XCTAssertTrue((audio.value as? String ?? "").contains("2 条"))
        openTrackMenu(captions, item: app.buttons["player.subtitle.server.7"]); app.buttons["player.subtitle.server.7"].tap()
        let bitmap = app.descendants(matching: .any)["player.subtitle.bitmap"].firstMatch
        XCTAssertTrue(bitmap.waitForExistence(timeout: 20), "Real SUP data must produce a visible image layer")
        XCTAssertTrue(app.buttons["播放"].exists)
        openTrackMenu(audio, item: app.buttons["player.audio.server.1"])
        XCTAssertTrue(app.buttons["player.audio.server.1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["player.audio.server.2"].exists)
        app.buttons["player.audio.server.2"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已显示画面'"), object: canvas)], timeout: 30), .completed)
        XCTAssertTrue(bitmap.waitForExistence(timeout: 20)); XCTAssertTrue(app.buttons["播放"].exists)
        openTrackMenu(audio, item: app.buttons["player.audio.server.2"]); XCTAssertTrue(app.buttons["player.audio.server.2"].label.contains("✓"))
        app.buttons["player.audio.server.2"].tap()
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "PGS rendered with alternate audio"; image.lifetime = .keepAlways; add(image)
        openTrackMenu(captions, item: app.buttons["player.subtitle.off"]); app.buttons["player.subtitle.off"].tap()
        XCTAssertFalse(bitmap.exists)
        openTrackMenu(captions, item: app.buttons["player.subtitle.server.5"]); app.buttons["player.subtitle.server.5"].tap()
        let text = app.staticTexts["player.subtitle.overlay"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'English fixture subtitles'"), object: text)], timeout: 15), .completed)
        app.buttons["播放"].tap(); XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 10))
        openTrackMenu(audio, item: app.buttons["player.audio.server.1"]); app.buttons["player.audio.server.1"].tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 30))
        XCTAssertEqual(text.label, "English fixture subtitles")
        app.buttons["返回片库"].tap()
    }
    @MainActor func testJellyfinServerSubtitleMenuSwitchOffAndReenable() async throws {
        guard ProcessInfo.processInfo.environment["GLIDE_SUBTITLE_SWITCH_FIXTURE"] == "1" else { throw XCTSkip("Run authored subtitle-switch fixture on 8793") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-jellyfin-fixture", "-glideSubtitleSwitchFixture", "YES", "-controlsDelay", "120", "-glideQAStartPaused", "YES", "-preferredAudioLanguage", "", "-preferredSubtitleLanguage", "zh", "-forcedSubtitlesOnly", "NO"]
        app.launch(); await openProfessionalMovieCatalog(app)
        for _ in 0..<3 {
            if app.buttons["detail.play"].exists { break }
            app.buttons["catalog.demo0"].tap()
            if app.buttons["detail.play"].waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 10)); app.buttons["detail.play"].tap()
        let canvas = app.otherElements["player.canvas"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已显示画面'"), object: canvas)], timeout: 30), .completed)
        pausePlayerAndWait(app)
        let quick = app.descendants(matching: .any)["player.quick.subtitle"].firstMatch
        XCTAssertTrue(quick.waitForExistence(timeout: 8))
        XCTAssertTrue((quick.value as? String ?? "").contains("4 条可选"))
        openTrackMenu(quick, item: app.buttons["player.subtitle.server.4"])
        for index in [4, 5, 6, 7] { XCTAssertTrue(app.buttons["player.subtitle.server.\(index)"].waitForExistence(timeout: 5)) }
        app.buttons["player.subtitle.server.5"].tap()
        let caption = app.staticTexts["player.subtitle.overlay"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'English fixture subtitles'"), object: caption)], timeout: 15), .completed)
        XCTAssertTrue(app.buttons["播放"].exists, "Selecting subtitles preserves pause")
        openTrackMenu(quick, item: app.buttons["player.subtitle.off"]); app.buttons["player.subtitle.off"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: caption)], timeout: 8), .completed)
        openTrackMenu(quick, item: app.buttons["player.subtitle.server.6"]); app.buttons["player.subtitle.server.6"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '第二路中文字幕'"), object: caption)], timeout: 15), .completed)
        openTrackMenu(quick, item: app.buttons["player.subtitle.controls"]); app.buttons["player.subtitle.controls"].tap()
        XCTAssertTrue(app.buttons["subtitles.server.open"].waitForExistence(timeout: 8)); app.buttons["subtitles.server.open"].tap()
        XCTAssertTrue(app.buttons["subtitles.server.7"].waitForExistence(timeout: 8))
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Server subtitle variants and formats"; image.lifetime = .keepAlways; add(image)
        app.buttons["subtitles.server.5"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '已选择'"), object: app.buttons["subtitles.server.5"])], timeout: 10), .completed)
        app.navigationBars.buttons["字幕控制"].tap(); app.buttons["subtitles.done"].tap()
        XCTAssertEqual(caption.label, "English fixture subtitles")
        app.buttons["返回片库"].tap()
    }
    @MainActor func testSubtitleStudyProductionProbe() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--glide-subtitle-study-probe", "-cellularPlayback", "NO"]
        app.launch()
        let status = app.staticTexts["study.probe.status"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '字幕导航验证通过' OR label == '字幕导航验证未完成'"), object: status)], timeout: 210), .completed)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "1.9 production subtitle navigation and loops"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(status.label, "字幕导航验证通过")
    }
    @MainActor func testSubtitleStudyNavigationStylesAndLoopUI() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-dual-subtitle-fixture", "--glide-dual-subtitle-reset", "-localPlaybackEngine", "avPlayer", "-preferredSubtitleLanguage", "zh", "-forcedSubtitlesOnly", "NO", "-glideQAStartPaused", "YES", "-controlsDelay", "120"]
        app.launch()
        let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video.' AND identifier ENDSWITH ':local:paired.mp4'")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        for _ in 0..<3 {
            if app.otherElements["player.canvas"].exists { break }
            video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 0.2)
            if app.otherElements["player.canvas"].waitForExistence(timeout: 4) { break }
        }
        XCTAssertTrue(app.staticTexts["player.subtitle.overlay"].waitForExistence(timeout: 15))
        func controls() {
            app.buttons["player.quick.subtitle"].tap()
            let open = app.buttons["player.subtitle.controls"]
            XCTAssertTrue(open.waitForExistence(timeout: 5)); Thread.sleep(forTimeInterval: 0.6); open.tap()
            XCTAssertTrue(app.collectionViews["subtitles.controls.list"].waitForExistence(timeout: 8))
        }
        func attach(_ name: String) { let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot) }
        controls(); app.buttons["subtitles.transcript.open"].tap()
        let second = app.buttons["subtitles.transcript.cue.4.0"]
        XCTAssertTrue(second.waitForExistence(timeout: 8)); second.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '当前句'"), object: second)], timeout: 10), .completed)
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("暂停")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["subtitles.transcript.cue.0.0"])], timeout: 5), .completed)
        XCTAssertTrue(second.exists); attach("1.9 transcript search and current line")
        app.navigationBars.buttons["字幕控制"].tap()
        app.buttons["subtitles.appearance.open"].tap()
        let size = app.descendants(matching: .any)["subtitles.appearance.primary.size"].firstMatch
        XCTAssertTrue(size.waitForExistence(timeout: 8))
        let oldSize = size.label
        size.buttons.element(boundBy: 1).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", oldSize), object: size)], timeout: 5), .completed)
        let newSize = size.label
        XCTAssertTrue(app.descendants(matching: .any)["subtitles.appearance.preview"].exists)
        attach("1.9 live subtitle appearance preview")
        app.navigationBars.buttons["字幕控制"].tap(); app.buttons["subtitles.appearance.open"].tap()
        XCTAssertEqual(size.label, newSize)
        app.swipeUp(); app.buttons["subtitles.appearance.reset"].tap()
        app.navigationBars.buttons["字幕控制"].tap()
        app.buttons["subtitles.loop.open"].tap()
        let markA = app.buttons["loop.markA"]
        XCTAssertTrue(markA.waitForExistence(timeout: 8)); markA.tap()
        app.buttons["快进 5 秒"].tap(); Thread.sleep(forTimeInterval: 1)
        app.buttons["loop.markB"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["loop.status"].waitForExistence(timeout: 8)); attach("1.9 A-B repeat controls")
        app.buttons["loop.clear"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["loop.status"].exists)
        app.navigationBars.buttons["字幕控制"].tap(); app.buttons["subtitles.done"].tap()
        app.buttons["返回片库"].tap()
    }
    @MainActor func testDualSubtitleProductionProbe() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-dual-subtitle-probe", "-cellularPlayback", "NO"]
        app.launch()
        let status = app.staticTexts["dual.probe.status"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '双字幕验证通过' OR label == '双字幕验证未完成'"), object: status)], timeout: 180), .completed)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "1.8 dual subtitle production probe"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(status.label, "双字幕验证通过")
        XCTAssertTrue(app.staticTexts["player.subtitle.overlay"].exists)
        XCTAssertTrue(app.staticTexts["player.subtitle.secondary.overlay"].exists)
    }
    @MainActor func testDualSubtitleControlsOffsetsAndRestart() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-dual-subtitle-fixture", "--glide-dual-subtitle-reset", "-localPlaybackEngine", "avPlayer", "-preferredSubtitleLanguage", "", "-forcedSubtitlesOnly", "NO", "-glideQAStartPaused", "YES", "-controlsDelay", "120"]
        func openVideo() {
            app.launch()
            let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video.' AND identifier ENDSWITH ':local:paired.mp4'")).firstMatch
            XCTAssertTrue(video.waitForExistence(timeout: 20))
            let canvas = app.otherElements["player.canvas"]
            for _ in 0..<3 {
                if canvas.exists { break }
                video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 0.2)
                if canvas.waitForExistence(timeout: 4) { break }
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已显示画面'"), object: canvas)], timeout: 20), .completed)
        }
        func openControls() {
            for _ in 0..<3 {
                if app.collectionViews["subtitles.controls.list"].exists { return }
                let menu = app.descendants(matching: .any)["player.quick.subtitle"]
                menu.tap()
                let button = app.buttons["player.subtitle.controls"]
                if button.waitForExistence(timeout: 3) {
                    // UIKit reverses this bottom-anchored menu as its content changes.
                    // Existence precedes the end of that positioning animation.
                    Thread.sleep(forTimeInterval: 0.6)
                    button.tap()
                }
                if app.collectionViews["subtitles.controls.list"].waitForExistence(timeout: 5) { return }
            }
            XCTAssertTrue(app.collectionViews["subtitles.controls.list"].exists)
        }
        func reveal(_ element: XCUIElement) {
            let list = app.collectionViews["subtitles.controls.list"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: list)], timeout: 5), .completed)
            for _ in 0..<9 {
                let top = max(list.frame.minY, app.buttons["subtitles.done"].frame.maxY) + 8
                let bottom = min(list.frame.maxY - 12, app.frame.maxY - 40)
                let frame = element.exists ? element.frame : .zero
                if element.isHittable, frame.minY >= top, frame.maxY <= bottom { return }
                let upwards = frame.isEmpty || frame.minY >= top
                let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: upwards ? 0.75 : 0.3))
                let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: upwards ? 0.35 : 0.7))
                from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0)
            }
            XCTAssertTrue(element.isHittable)
        }
        openVideo(); openControls()
        let mainMenu = app.buttons["subtitles.primary.candidates"]
        reveal(mainMenu); mainMenu.tap()
        app.buttons["subtitles.primary.sidecar.paired.zh-Hans.srt"].tap()
        let secondMenu = app.buttons["subtitles.secondary.candidates"]
        reveal(secondMenu)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: secondMenu)], timeout: 5), .completed)
        secondMenu.tap(); app.buttons["subtitles.secondary.sidecar.paired.en.vtt"].tap()
        let primaryDelay = app.descendants(matching: .any)["subtitles.primary.delay"].firstMatch
        XCTAssertTrue(primaryDelay.waitForExistence(timeout: 5)); reveal(primaryDelay); app.buttons["subtitles.primary.delay-Increment"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '0.1'"), object: primaryDelay)], timeout: 5), .completed)
        let secondaryDelay = app.descendants(matching: .any)["subtitles.secondary.delay"].firstMatch
        reveal(secondaryDelay); app.buttons["subtitles.secondary.delay-Decrement"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '-0.1'"), object: secondaryDelay)], timeout: 5), .completed)
        let controls = XCTAttachment(screenshot: app.screenshot()); controls.name = "1.8 independent subtitle offsets"; controls.lifetime = .keepAlways; add(controls)
        app.buttons["subtitles.done"].tap()
        let seek = app.descendants(matching: .any)["player.seekBar"].firstMatch
        seek.movePlaybackThumb(to: 0.18, hold: 1)
        let primary = app.staticTexts["player.subtitle.overlay"], secondary = app.staticTexts["player.subtitle.secondary.overlay"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10)); XCTAssertTrue(secondary.exists)
        XCTAssertEqual(primary.label, "你好，世界。"); XCTAssertEqual(secondary.label, "Hello, world.")
        XCTAssertLessThanOrEqual(primary.frame.maxY, secondary.frame.minY)
        XCTAssertLessThan(secondary.frame.maxY, seek.frame.minY - 4, "Subtitles must clear the timeline when controls are visible")
        XCTAssertTrue(app.buttons["播放"].exists)
        let screenshot = app.screenshot(), shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "1.8 rendered bilingual subtitles"; shot.lifetime = .keepAlways; add(shot)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(screenshot.image.cgImage), options: [:]).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.contains("你好") && text.lowercased().contains("hello"), "Both subtitle rows must render readable pixels")
        app.buttons["返回片库"].tap(); app.terminate(); app.launchArguments.removeAll { $0 == "--glide-dual-subtitle-reset" }; openVideo()
        app.descendants(matching: .any)["player.seekBar"].firstMatch.movePlaybackThumb(to: 0.18, hold: 1)
        XCTAssertTrue(primary.waitForExistence(timeout: 10)); XCTAssertTrue(secondary.exists)
        openControls(); reveal(secondaryDelay); XCTAssertTrue(secondaryDelay.label.contains("-0.1"))
        let off = app.buttons["subtitles.secondary.off"]; reveal(off); off.tap(); app.buttons["subtitles.done"].tap()
        XCTAssertTrue(primary.exists); XCTAssertFalse(secondary.exists)
        openControls()
        let importSecond = app.buttons["subtitles.secondary.import"]; reveal(importSecond); importSecond.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.tap()
        XCTAssertTrue(app.collectionViews["subtitles.controls.list"].waitForExistence(timeout: 10))
        app.buttons["subtitles.done"].tap(); app.buttons["返回片库"].tap()
    }

    @MainActor func testEmbyProductionProbe() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_EMBY_FIXTURE"] == "1" else { throw XCTSkip("Run isolated official Emby fixture on 8772") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-emby-probe", "-cellularPlayback", "NO"]
        app.launch()
        let status = app.staticTexts["emby.probe.status"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Emby 验证通过' OR label == 'Emby 验证未完成'"), object: status)], timeout: 180), .completed)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "1.7 official Emby production probe"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(status.label, "Emby 验证通过")
    }
    @MainActor func testEmbyAddSourceCatalogAndPlaybackUI() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_EMBY_FIXTURE"] == "1" else { throw XCTSkip("Run isolated official Emby fixture on 8772") }
        continueAfterFailure = false
        let app = XCUIApplication(), fixtureName = "1.7 UI Emby " + UUID().uuidString.prefix(6)
        app.launchArguments = ["--glide-link-fixture", "-controlsDelay", "120", "-cellularPlayback", "NO"]
        app.launch()
        func open(_ button: XCUIElement, until target: XCUIElement) {
            for _ in 0..<3 {
                XCTAssertTrue(button.waitForExistence(timeout: 8))
                button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
                if target.waitForExistence(timeout: 4) { return }
            }
            XCTAssertTrue(target.exists)
        }
        open(app.buttons["sources.open"], until: app.buttons["sources.add"])
        let name = app.textFields["名称（可选）"]
        open(app.buttons["sources.add"], until: name)
        app.segmentedControls.buttons["Emby"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Emby"].isSelected)
        let form = XCTAttachment(screenshot: app.screenshot()); form.name = "1.7 Emby source form"; form.lifetime = .keepAlways; add(form)
        Thread.sleep(forTimeInterval: 0.8)
        func fill(_ field: XCUIElement, _ value: String) {
            for _ in 0..<3 {
                if field.frame.maxY >= app.buttons["sources.connect"].frame.minY - 12 {
                    app.collectionViews.containing(.textField, identifier: "服务器地址").firstMatch.swipeUp()
                }
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).press(forDuration: 0.2)
                if field.value(forKey: "hasKeyboardFocus") as? Bool == true { break }
                Thread.sleep(forTimeInterval: 0.4)
            }
            XCTAssertEqual(field.value(forKey: "hasKeyboardFocus") as? Bool, true)
            field.typeText(value)
        }
        fill(name, String(fixtureName))
        fill(app.textFields["服务器地址"], "http://127.0.0.1:8772/emby")
        fill(app.textFields["用户名"], "glide-fixture\n")
        fill(app.secureTextFields["密码"], "glide170-fixture\n")
        let connected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'source.' AND label CONTAINS %@", String(fixtureName))).firstMatch
        open(app.buttons["sources.connect"], until: connected)
        let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'folder.' AND label CONTAINS 'Glide Movies'")).firstMatch
        open(app.buttons["完成"], until: folder)
        let movie = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'catalog.' AND label CONTAINS 'Glide 原创电影'")).firstMatch
        open(folder, until: movie)
        open(movie, until: app.buttons["detail.play"])
        XCTAssertTrue(app.buttons["detail.audio"].waitForExistence(timeout: 5))
        let detail = XCTAttachment(screenshot: app.screenshot()); detail.name = "1.7 Emby movie metadata"; detail.lifetime = .keepAlways; add(detail)
        open(app.buttons["detail.play"], until: app.buttons["返回片库"])
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已显示画面'"), object: app.otherElements["player.canvas"])], timeout: 30), .completed)
        if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
        XCTAssertFalse(app.staticTexts["暂时无法播放"].exists)
        let play = XCTAttachment(screenshot: app.screenshot()); play.name = "1.7 Emby native playback"; play.lifetime = .keepAlways; add(play)
        app.buttons["返回片库"].tap()
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 10))
    }
    @MainActor private func openLinks(in app: XCUIApplication) {
        revealLibraryAction("links.open", in: app)
        XCTAssertTrue(app.buttons["links.open"].waitForExistence(timeout: 10))
        for _ in 0..<3 {
            app.buttons["links.open"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
            if app.buttons["links.add"].waitForExistence(timeout: 3) { return }
        }
        XCTFail("Link library did not open")
    }
    @MainActor private func revealLibraryAction(_ identifier: String, in app: XCUIApplication) {
        for _ in 0..<3 {
            if app.buttons[identifier].exists { return }
            let more = app.descendants(matching: .any)["library.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 8))
            more.tap()
            if app.buttons[identifier].waitForExistence(timeout: 3) { return }
        }
        XCTFail("Library action must be available after the preceding sheet dismissal: " + identifier)
    }
    @MainActor private func chooseMenuItem(_ title: String, from identifier: String, in app: XCUIApplication) {
        let trigger = app.descendants(matching: .any)[identifier].firstMatch
        let option = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
        openTrackMenu(trigger, item: option)
        option.tap()
    }
    @MainActor func testLinkSkipProductionProbe() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_LINK_FIXTURE"] == "1" else { throw XCTSkip("Run authored link fixture on 8770") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-link-skip-probe", "-cellularPlayback", "NO"]
        app.launch()
        let status = app.staticTexts["link.probe.status"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '链接与跳过验证通过' OR label == '链接与跳过验证未完成'"), object: status)], timeout: 180), .completed)
        XCTAssertEqual(status.label, "链接与跳过验证通过")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "1.6 production probe"; attachment.lifetime = .keepAlways; add(attachment)
        app.terminate()
        app.launchArguments = ["--glide-link-fixture", "-cellularPlayback", "NO"]
        app.launch()
        openLinks(in: app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'links.video.' AND label CONTAINS '1.6 QA HLS'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.press(forDuration: 1)
        let edit = app.buttons["编辑链接"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            if edit.isHittable { edit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2) }
            if app.textFields["links.name"].waitForExistence(timeout: 3) { break }
            if row.isHittable { row.press(forDuration: 1) }
        }
        XCTAssertTrue(app.textFields["links.name"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["links.name"].value as? String, "1.6 QA HLS")
        let editor = XCTAttachment(screenshot: app.screenshot()); editor.name = "1.6 context menu editor"; editor.lifetime = .keepAlways; add(editor)
        app.buttons["取消"].tap()
    }
    @MainActor func testLinkPlaybackSkipMemoryAndCRUD() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_LINK_FIXTURE"] == "1" else { throw XCTSkip("Run authored link fixture on 8770") }
        continueAfterFailure = false
        let app = XCUIApplication(), name = "1.6 UI " + UUID().uuidString.prefix(6)
        app.launchArguments = ["--glide-link-fixture", "-controlsDelay", "120", "-cellularPlayback", "NO"]
        app.launch()
        openLinks(in: app)
        app.buttons["links.add"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
        let address = app.descendants(matching: .any)["links.address"], title = app.textFields["links.name"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.7) // Let the native iPad sheet finish moving before focusing its form.
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2); title.typeText(name)
        address.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2); address.typeText("file:///private/movie.mp4")
        app.buttons["links.save"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
        XCTAssertTrue(app.staticTexts["links.error"].waitForExistence(timeout: 5))
        address.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
        address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "http://127.0.0.1:8770/sample.mp4?token=fixture-ui")
        app.buttons["links.save"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'links.video.' AND label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); let rowID = row.identifier
        func openVideo() {
            let item = app.buttons[rowID]
            XCTAssertTrue(item.waitForExistence(timeout: 10)); item.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已显示画面'"), object: app.otherElements["player.canvas"])], timeout: 25), .completed)
            if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
        }
        func openRules() {
            let button = app.buttons["player.skip.settings"]
            for _ in 0..<3 {
                app.buttons["播放设置"].tap()
                if app.collectionViews["player.settings.list"].waitForExistence(timeout: 3) { break }
            }
            let list = app.collectionViews["player.settings.list"]
            for _ in 0..<7 {
                if button.isHittable { break }
                list.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.85)).press(forDuration: 0.01, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.3)), withVelocity: .fast, thenHoldForDuration: 0)
            }
            XCTAssertTrue(button.isHittable)
            for _ in 0..<3 {
                button.press(forDuration: 0.1)
                if app.textFields["skip.intro"].waitForExistence(timeout: 3) { break }
            }
            XCTAssertTrue(app.textFields["skip.intro"].exists)
        }
        openVideo(); openRules()
        let intro = app.textFields["skip.intro"]
        intro.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).press(forDuration: 0.2)
        intro.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + "13")
        XCTAssertEqual(intro.value as? String, "13")
        XCTAssertTrue(app.buttons["skip.save"].isEnabled)
        for _ in 0..<3 {
            app.buttons["skip.save"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
            if app.alerts["无法保存规则"].waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(app.alerts["无法保存规则"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS '合计需小于视频时长'")).firstMatch.exists)
        for _ in 0..<3 {
            app.alerts.buttons["知道了"].press(forDuration: 0.2)
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.alerts["无法保存规则"])], timeout: 2) == .completed { break }
        }
        XCTAssertFalse(app.alerts["无法保存规则"].exists)
        for _ in 0..<3 {
            intro.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).press(forDuration: 0.2)
            intro.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + "4")
            if intro.value as? String == "4" { break }
        }
        XCTAssertEqual(intro.value as? String, "4")
        app.buttons["skip.save"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
        XCTAssertTrue(app.collectionViews["player.settings.list"].waitForExistence(timeout: 5))
        app.buttons["player.settings.done"].tap()
        let seek = app.descendants(matching: .any)["player.seekBar"].firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 5)); seek.movePlaybackThumb(to: 0.05, hold: 3)
        let action = app.buttons["player.skip.action"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: action)], timeout: 10), .completed)
        action.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label >= '00:03' AND label <= '00:05'"), object: app.staticTexts["player.elapsed"])], timeout: 15), .completed)
        XCTAssertTrue(app.buttons["播放"].exists, "Manual skip preserves pause")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "1.6 manual skip preserves pause"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["返回片库"].tap(); app.terminate(); app.launch()
        openLinks(in: app); openVideo(); openRules()
        XCTAssertEqual(app.textFields["skip.intro"].value as? String, "4.0")
        let restored = XCTAttachment(screenshot: app.screenshot()); restored.name = "1.6 skip rule restored"; restored.lifetime = .keepAlways; add(restored)
        let clear = app.buttons["skip.clear"]
        let rules = app.collectionViews.containing(.textField, identifier: "skip.intro").firstMatch
        for _ in 0..<5 {
            if clear.isHittable { break }
            rules.swipeUp()
        }
        XCTAssertTrue(clear.isHittable); clear.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
        XCTAssertTrue(app.buttons["player.settings.done"].waitForExistence(timeout: 5))
        app.buttons["player.settings.done"].tap(); app.buttons["返回片库"].tap()
        app.buttons[rowID].swipeLeft()
        XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 5))
        app.buttons["编辑"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
        XCTAssertTrue(title.waitForExistence(timeout: 5)); Thread.sleep(forTimeInterval: 0.7)
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2); title.typeText(" 已编辑")
        app.buttons["links.save"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已编辑'"), object: app.buttons[rowID])], timeout: 5), .completed)
        let links = XCTAttachment(screenshot: app.screenshot()); links.name = "1.6 saved links"; links.lifetime = .keepAlways; add(links)
        app.buttons[rowID].swipeLeft()
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 5))
        app.buttons["删除"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons[rowID])], timeout: 5), .completed)
    }
    @MainActor func testManagedSubtitleOffRestartAndReenable() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-subtitle-probe", "-cellularPlayback", "NO"]
        app.launch()
        let status = app.staticTexts["subtitle.probe.status"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '字幕验证通过' OR label == '字幕验证未通过'"), object: status)], timeout: 150), .completed)
        XCTAssertEqual(status.label, "字幕验证通过")
        app.terminate()
        app.launchArguments = ["--glide-subtitle-fixture", "-glideQAStartPaused", "YES", "-controlsDelay", "120", "-localPlaybackEngine", "avPlayer"]
        func open() {
            app.launch()
            let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video.' AND identifier ENDSWITH 'import.mp4'")).firstMatch
            XCTAssertTrue(video.waitForExistence(timeout: 20))
            for _ in 0..<3 {
                video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 0.2)
                if app.descendants(matching: .any)["player.quick.subtitle"].waitForExistence(timeout: 4) { break }
            }
            XCTAssertTrue(app.descendants(matching: .any)["player.quick.subtitle"].waitForExistence(timeout: 15))
        }
        func chooseSubtitleMenu(_ item: XCUIElement) {
            for _ in 0..<3 {
                app.descendants(matching: .any)["player.quick.subtitle"].tap()
                if item.waitForExistence(timeout: 3) {
                    Thread.sleep(forTimeInterval: 0.6)
                    item.tap(); return
                }
            }
            XCTAssertTrue(item.exists)
        }
        let overlay = app.staticTexts["player.subtitle.overlay"]
        open(); XCTAssertTrue(overlay.waitForExistence(timeout: 10)); XCTAssertEqual(overlay.label, "手动导入保留副本")
        chooseSubtitleMenu(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '关闭字幕'")).firstMatch)
        app.buttons["返回片库"].tap(); app.terminate(); open()
        XCTAssertFalse(overlay.exists)
        chooseSubtitleMenu(app.buttons["player.subtitle.imported"])
        XCTAssertTrue(overlay.waitForExistence(timeout: 10)); XCTAssertEqual(overlay.label, "手动导入保留副本")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Managed subtitle reenabled after restart"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["返回片库"].tap()
    }
    @MainActor func testSidecarSelectionDelayOffAndRestart() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-subtitle-fixture", "--glide-subtitle-reset", "-localPlaybackEngine", "avPlayer", "-preferredSubtitleLanguage", "", "-forcedSubtitlesOnly", "NO", "-glideQAStartPaused", "YES", "-controlsDelay", "120"]
        app.launch()
        func open() {
            let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video.' AND identifier ENDSWITH 'multi.mp4'")).firstMatch
            XCTAssertTrue(video.waitForExistence(timeout: 20)); video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
            XCTAssertTrue(app.descendants(matching: .any)["player.quick.subtitle"].waitForExistence(timeout: 15))
            let canvas = app.otherElements["player.canvas"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已显示画面'"), object: canvas)], timeout: 15), .completed)
            app.descendants(matching: .any)["player.seekBar"].firstMatch.movePlaybackThumb(to: 0.2, hold: 1)
        }
        func settingsDelay() -> XCUIElement {
            let delay = app.descendants(matching: .any)["player.subtitle.delay"].firstMatch, list = app.collectionViews["player.settings.list"]
            for _ in 0..<3 {
                app.buttons["播放设置"].tap()
                if list.waitForExistence(timeout: 3) { break }
            }
            XCTAssertTrue(list.exists)
            for _ in 0..<8 {
                if delay.isHittable { break }
                list.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.85)).press(forDuration: 0.01, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.3)), withVelocity: .fast, thenHoldForDuration: 0)
            }
            XCTAssertTrue(delay.isHittable)
            return delay
        }
        open()
        XCTAssertFalse(app.staticTexts["player.subtitle.overlay"].exists, "Ambiguous sidecars must await selection")
        app.descendants(matching: .any)["player.quick.subtitle"].tap()
        app.buttons["player.subtitle.sidecar.multi.zh-Hans.srt"].tap()
        let overlay = app.staticTexts["player.subtitle.overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 10)); XCTAssertEqual(overlay.label, "选择简体中文字幕")
        let delay = settingsDelay()
        delay.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(delay.label.contains("0.5"))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Sidecar delay memory"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["完成"].tap(); app.buttons["返回片库"].tap()
        app.terminate(); app.launchArguments.removeAll { $0 == "--glide-subtitle-reset" }; app.launch(); open()
        XCTAssertTrue(overlay.waitForExistence(timeout: 10)); XCTAssertEqual(overlay.label, "选择简体中文字幕")
        XCTAssertTrue(settingsDelay().label.contains("0.5")); app.buttons["完成"].tap()
        app.descendants(matching: .any)["player.quick.subtitle"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '关闭字幕'")).firstMatch.tap()
        app.buttons["返回片库"].tap(); app.terminate(); app.launch(); open()
        XCTAssertFalse(overlay.exists)
        XCTAssertEqual(app.descendants(matching: .any)["player.quick.subtitle"].value as? String, "关闭")
        app.descendants(matching: .any)["player.quick.subtitle"].tap(); app.buttons["player.subtitle.forget"].tap()
        app.buttons["返回片库"].tap()
    }

    @MainActor func testSidecarRenderedClockOnNativeVLCAndSMB() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_SMB_FIXTURE"] == "1" else { throw XCTSkip("Run authored read-only SMB fixture") }
        continueAfterFailure = false
        let app = XCUIApplication()
        for (fixture, engine, name) in [("--glide-subtitle-fixture", "avPlayer", "Native"), ("--glide-subtitle-fixture", "vlc", "VLC"), ("--glide-subtitle-smb-fixture", "vlc", "SMB")] {
            app.launchArguments = [fixture, "--glide-subtitle-reset", "--glide-smb-seek-probe", "-localPlaybackEngine", engine, "-preferredSubtitleLanguage", "", "-forcedSubtitlesOnly", "NO", "-glideQAStartPaused", "YES", "-controlsDelay", "120", "-glideSMBFixtureAddress", "127.0.0.1:1445"]
            app.launch()
            let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video.' AND identifier ENDSWITH 'auto.mp4'")).firstMatch
            XCTAssertTrue(video.waitForExistence(timeout: 20)); video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
            let overlay = app.staticTexts["player.subtitle.overlay"]
            XCTAssertTrue(overlay.waitForExistence(timeout: 20)); XCTAssertEqual(overlay.label, "自动匹配中文字幕")
            let canvas = app.otherElements["player.canvas"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已显示画面'"), object: canvas)], timeout: 20), .completed)
            let seek = app.descendants(matching: .any)["player.seekBar"].firstMatch
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '/ 00:12'"), object: seek)], timeout: 10), .completed)
            seek.movePlaybackThumb(to: 0.6, hold: 3)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '暂停拖动字幕时钟'"), object: overlay)], timeout: 15), .completed)
            XCTAssertTrue(app.buttons["播放"].exists, "Seeking keeps the player paused")
            let shot = app.screenshot(), attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Sidecar rendered clock " + name; attachment.lifetime = .keepAlways; add(attachment)
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(shot.image.cgImage), options: [:]).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(text.contains("暂停拖动字幕时钟"), "Actual subtitle pixels must be readable: " + text)
            app.buttons["返回片库"].tap(); app.terminate()
        }
    }
    @MainActor func testSMBChineseSubtitles() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_SMB_FIXTURE"] == "1" else { throw XCTSkip("Run authored SMB fixtures") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-smb-fixture", "-controlsDelay", "60", "-glideQAStartPaused", "YES", "-preferredSubtitleLanguage", "", "-forcedSubtitlesOnly", "NO"]
        if let host = ProcessInfo.processInfo.environment["GLIDE_SMB_FIXTURE_ADDRESS"] { app.launchArguments += ["-glideSMBFixtureAddress", host] }
        app.launch()
        for (name, expected) in [("12-cjk-ass.mkv", "中文字幕正常显示"), ("13-cjk-ass.mkv", "繁體字幕正常顯示"), ("14-cjk-srt.mkv", "中文字幕正常显示")] {
            let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video.' AND identifier ENDSWITH %@", name)).firstMatch
            XCTAssertTrue(video.waitForExistence(timeout: 20))
            for _ in 0..<5 { if video.isHittable { break }; app.swipeUp() }
            let canvas = app.otherElements["player.canvas"]
            for _ in 0..<3 {
                video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
                if canvas.waitForExistence(timeout: 4) { break }
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已显示画面'"), object: canvas)], timeout: 25), .completed)
            if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
            let subtitle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.subtitle.subtitle-'")).firstMatch
            for _ in 0..<3 {
                app.descendants(matching: .any)["player.quick.subtitle"].tap()
                if subtitle.waitForExistence(timeout: 3) { break }
            }
            XCTAssertTrue(subtitle.exists)
            subtitle.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != '关闭'"), object: app.descendants(matching: .any)["player.quick.subtitle"])], timeout: 5), .completed)
            // Selecting a VLC track while paused needs a decoded frame before inspecting its pixels.
            let seek = app.descendants(matching: .any)["player.seekBar"].firstMatch
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '/ 00:20'"), object: seek)], timeout: 10), .completed)
            seek.movePlaybackThumb(to: 0.25, hold: 3)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label >= '00:04' AND label <= '00:06'"), object: app.staticTexts["player.elapsed"])], timeout: 15), .completed)
            XCTAssertTrue(app.buttons["播放"].exists, "Subtitle selection and seek preserve pause")
            let shot = app.screenshot()
            let attachment = XCTAttachment(screenshot: shot); attachment.name = "SMB CJK " + name; attachment.lifetime = .keepAlways; add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.regionOfInterest = CGRect(x: 0.2, y: 0.28, width: 0.6, height: 0.16)
            try VNImageRequestHandler(cgImage: XCTUnwrap(shot.image.cgImage), options: [:]).perform([request])
            // Keep OCR alternatives for similar glyphs such as 幕/墓; missing glyph boxes still cannot match the full cue.
            let text = (request.results ?? []).flatMap { $0.topCandidates(5).map(\.string) }.joined(separator: " ")
            XCTAssertTrue(text.contains(expected), "Actual rendered Chinese subtitle must be readable: " + text)
            app.buttons["返回片库"].tap()
        }
    }
    @MainActor func testSMBSourceBrowseAndPlayback() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_SMB_FIXTURE"] == "1" else { throw XCTSkip("Run the isolated SMB fixtures") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-controlsDelay", "60", "-homeBrowseView", "directories"]
        app.launch()
        app.buttons["sources.open"].tap(); app.buttons["sources.add"].tap()
        app.segmentedControls.buttons["SMB"].tap()
        let name = app.textFields["名称（可选）"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Glide SMB UI Fixture")
        let address = app.textFields["服务器地址"]
        address.tap(); address.typeText(ProcessInfo.processInfo.environment["GLIDE_SMB_FIXTURE_ADDRESS"] ?? "127.0.0.1:1445")
        app.textFields["sources.smbShare"].tap(); app.textFields["sources.smbShare"].typeText("media")
        app.textFields["用户名"].tap(); app.textFields["用户名"].typeText("glide")
        app.secureTextFields["密码"].tap(); app.secureTextFields["密码"].typeText("glide150-fixture\n")
        let test = app.buttons["sources.testSMB"]
        if !test.isHittable { app.swipeUp() }
        test.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '连接成功'")).firstMatch.waitForExistence(timeout: 20))
        app.buttons["sources.connect"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 20)); app.buttons["完成"].tap()
        let media = app.segmentedControls["library.contentView"].buttons["媒体"]
        XCTAssertTrue(media.waitForExistence(timeout: 10)); XCTAssertTrue(media.isSelected)
        let browse = XCTAttachment(screenshot: app.screenshot()); browse.name = "SMB portrait media"; browse.lifetime = .keepAlways; add(browse)
        for name in ["1080p.mp4", "11-hd-dual-ass.mkv", "4k-hevc.mp4"] {
            let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video.' AND identifier ENDSWITH %@", name)).firstMatch
            for _ in 0..<6 { if video.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(video.isHittable)
            video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
            let canvas = app.otherElements["player.canvas"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已显示画面'"), object: canvas)], timeout: 25), .completed)
            app.buttons["暂停"].tap()
            app.descendants(matching: .any)["player.seekBar"].firstMatch.movePlaybackThumb(to: 0.7)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label >= '00:40' AND label <= '00:44'"), object: app.staticTexts["player.elapsed"])], timeout: 20), .completed)
            XCTAssertTrue(app.buttons["播放"].exists, "Seek preserves pause")
            let player = XCTAttachment(screenshot: app.screenshot()); player.name = "SMB production player " + name; player.lifetime = .keepAlways; add(player)
            app.buttons["返回片库"].tap()
        }
        app.segmentedControls["library.contentView"].buttons["目录"].tap()
        let directory = app.buttons.matching(NSPredicate(format: "label CONTAINS '家庭 视频'")).firstMatch
        XCTAssertTrue(directory.waitForExistence(timeout: 10)); directory.tap()
        XCTAssertTrue(app.segmentedControls["library.contentView"].buttons["媒体"].isSelected)
        app.buttons["sources.open"].tap()
        let fixture = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'source.' AND label CONTAINS 'Glide SMB UI Fixture'")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 5)); fixture.swipeLeft()
        app.buttons["移除"].tap(); app.buttons["同时删除此来源的离线影片"].firstMatch.tap()
        app.buttons["完成"].tap()
    }
    /// Requires synthetic samples from Scripts/generate_playback_fixtures.py in the QA sandbox.
    @MainActor func testNativeFormatMatrix() throws {
        try validateNativeFormats(["01-h264-aac.mp4", "02-hevc-aac.mp4", "03-h264-aac.mkv", "04-mpeg4-mp3.avi"])
    }
    @MainActor func testNativeFormatEdgeCases() throws {
        try validateNativeFormats(["05-renamed-mkv.mp4", "06-truncated.mp4", "07-audio-only.mp4", "08-multi-track.mp4"])
    }
    @MainActor private func validateNativeFormats(_ samples: [String]) throws {
        guard ProcessInfo.processInfo.environment["GLIDE_FORMAT_FIXTURES"] == "1" else {
            throw XCTSkip("Install synthetic FormatFixtures in the dedicated QA simulator")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--glide-format-fixtures", "-localPlaybackEngine", "avPlayer", "-glideQAStartPaused", "YES", "-controlsDelay", "30", "-preferredAudioLanguage", "", "-preferredSubtitleLanguage", "", "-forcedSubtitlesOnly", "NO"]
        var results: [[String: Any]] = []
        for sample in samples {
            app.launch()
            let source = app.buttons["sources.open"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'FormatFixtures'"), object: source)], timeout: 20), .completed)
            let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "video.", ":local:" + sample)).firstMatch
            for _ in 0..<5 { if video.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(video.waitForExistence(timeout: 10)); video.tap()
            let canvas = app.otherElements["player.canvas"], failure = app.staticTexts["player.error"]
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                canvas.exists && canvas.label.contains("已显示画面") || failure.exists
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 35), .completed, "Playback must settle: " + sample)
            let displayed = canvas.label.contains("已显示画面")
            if sample == "01-h264-aac.mp4" || sample == "08-multi-track.mp4" { XCTAssertTrue(displayed, sample) }
            if sample == "06-truncated.mp4" || sample == "07-audio-only.mp4" { XCTAssertFalse(displayed, sample) }
            if sample == "07-audio-only.mp4" {
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '没有视频轨道'"), object: failure)], timeout: 10), .completed)
            }
            let failureText = failure.exists ? failure.label : ""
            if displayed {
                if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
                app.buttons["播放设置"].tap()
                let settings = app.collectionViews["player.settings.list"]
                for _ in 0..<5 {
                    if app.buttons["player.diagnostic"].isHittable { break }
                    settings.swipeUp()
                }
                app.buttons["player.diagnostic"].tap()
            } else { app.buttons["播放诊断"].firstMatch.tap() }
            let json = app.staticTexts["diagnostic.json"]
            XCTAssertTrue(json.waitForExistence(timeout: 8))
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.label.utf8)) as? [String: Any])
            let report = try XCTUnwrap(object["localMedia"] as? [String: Any], "Format inspection completes for " + sample)
            XCTAssertFalse(json.label.contains("file://"))
            XCTAssertFalse(json.label.contains("FormatFixtures"))
            if sample == "05-renamed-mkv.mp4" { XCTAssertEqual(report["container"] as? String, "matroska") }
            if displayed { XCTAssertNotNil(object["firstFrameSeconds"]) }
            results.append(["sample": sample, "displayedFrame": displayed, "error": failureText, "inspection": report, "diagnostic": object])
            let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = sample; screenshot.lifetime = .keepAlways; add(screenshot)
            app.terminate()
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Native format matrix"; attachment.lifetime = .keepAlways; add(attachment)
        print("GLIDE_FORMAT_MATRIX=" + String(decoding: data, as: UTF8.self))
    }

    @MainActor func testNativeTrackSelection() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_FORMAT_FIXTURES"] == "1" else { throw XCTSkip("Install FormatFixtures") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--glide-format-fixtures", "-localPlaybackEngine", "avPlayer", "-glideQAStartPaused", "YES", "-controlsDelay", "30", "-preferredAudioLanguage", "", "-preferredSubtitleLanguage", "", "-forcedSubtitlesOnly", "NO"]
        app.launch()
        let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "video.", ":local:08-multi-track.mp4")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        for _ in 0..<5 { if video.isHittable { break }; app.swipeUp() }
        let canvas = app.otherElements["player.canvas"]
        for _ in 0..<3 {
            video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).press(forDuration: 0.2)
            if canvas.waitForExistence(timeout: 3) { break }
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '已显示画面'"), object: canvas)], timeout: 15), .completed)
        if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }; app.buttons["播放设置"].tap()
        let list = app.collectionViews["player.settings.list"]
        let audio = app.buttons["player.audio.audio-1"], subtitle = app.buttons["player.subtitle.subtitle-0"]
        let audioMenu = app.buttons["player.audio.menu"], subtitleMenu = app.buttons["player.subtitle.menu"]
        func reveal(_ element: XCUIElement) {
            for _ in 0..<8 {
                if element.isHittable, list.frame.insetBy(dx: 0, dy: 16).contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
                list.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.85)).press(forDuration: 0.01, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.3)), withVelocity: .fast, thenHoldForDuration: 0)
            }
            XCTAssertTrue(element.isHittable)
        }
        for _ in 0..<8 { if audioMenu.isHittable { break }; if list.exists { list.swipeUp() } else { app.swipeUp() } }
        XCTAssertTrue(audioMenu.isHittable); reveal(audioMenu); audioMenu.press(forDuration: 0.2)
        XCTAssertTrue(audio.waitForExistence(timeout: 5)); audio.tap()
        reveal(audioMenu); audioMenu.press(forDuration: 0.2)
        XCTAssertTrue(audio.waitForExistence(timeout: 5)); XCTAssertTrue(audio.label.contains("✓"), "Selected native audio is reflected through the generic track ID")
        audio.tap() // Close the native pop-up through its selected item; its backdrop obscures the sheet header on iPad.
        reveal(subtitleMenu); subtitleMenu.press(forDuration: 0.2)
        XCTAssertTrue(subtitle.waitForExistence(timeout: 5)); subtitle.tap()
        reveal(subtitleMenu); subtitleMenu.press(forDuration: 0.2)
        XCTAssertTrue(subtitle.waitForExistence(timeout: 5)); XCTAssertTrue(subtitle.label.contains("✓"))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '关闭字幕'")).firstMatch.tap()
        reveal(subtitleMenu); subtitleMenu.press(forDuration: 0.2)
        XCTAssertTrue(subtitle.waitForExistence(timeout: 5)); XCTAssertFalse(subtitle.label.contains("✓"))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '关闭字幕'")).firstMatch.tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Native track selection"; screenshot.lifetime = .keepAlways; add(screenshot)
        for _ in 0..<8 { if app.buttons["视频信息"].isHittable { break }; if list.exists { list.swipeDown() } else { app.swipeDown() } }
        app.buttons["视频信息"].tap()
        XCTAssertTrue(app.collectionViews["player.info.list"].waitForExistence(timeout: 8))
        let container = app.descendants(matching: .any)["player.info.container"].firstMatch
        for _ in 0..<4 { if container.isHittable { break }; app.collectionViews["player.info.list"].swipeUp() }
        XCTAssertTrue(container.isHittable)
        let info = XCTAttachment(screenshot: app.screenshot()); info.name = "Native format information"; info.lifetime = .keepAlways; add(info)
    }

    @MainActor func testLocalImportMountedDirectoryAndRestart() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--glide-local-fixture", "-controlsDelay", "30", "-localPlaybackEngine", "avPlayer"]
        app.launch()
        func wait(_ element: XCUIElement, _ predicate: String, timeout: Double = 10) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)], timeout: timeout), .completed)
        }
        func video(_ suffix: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "video.", ":local:" + suffix)).firstMatch
        }
        let sources = app.buttons["sources.open"]
        wait(sources, "label CONTAINS '本地验证目录'", timeout: 20)
        let childVideo = video("子目录/第二片段.mp4")
        XCTAssertTrue(childVideo.waitForExistence(timeout: 10), "Recursive local browsing includes descendants")
        let photo = XCTAttachment(screenshot: app.screenshot()); photo.name = "1.2 本地目录"; photo.lifetime = .keepAlways; add(photo)
        let directories = app.segmentedControls["library.contentView"].buttons["目录"]
        for _ in 0..<3 {
            if directories.isSelected { break }
            directories.press(forDuration: 0.15)
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: directories)], timeout: 2) == .completed { break }
        }
        wait(directories, "selected == true")
        let folder = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "folder.", "子目录")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        let back = app.buttons["directory.back"]
        for _ in 0..<3 {
            folder.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
            if back.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(back.exists, "Enter the child before checking restoration")
        app.segmentedControls["library.contentView"].buttons["媒体"].tap()
        XCTAssertTrue(childVideo.waitForExistence(timeout: 10))
        childVideo.press(forDuration: 1)
        app.buttons["收藏视频"].tap()
        app.terminate(); app.launchArguments.removeAll { $0 == "--glide-local-fixture" }; app.launch()
        XCTAssertTrue(app.buttons["directory.back"].waitForExistence(timeout: 10), "Restart restores the authorized descendant")
        XCTAssertTrue(childVideo.waitForExistence(timeout: 10))
        if UIDevice.current.userInterfaceIdiom == .pad { app.staticTexts["收藏与继续观看"].firstMatch.tap() }
        else { app.tabBars.buttons["我的"].tap() }
        app.segmentedControls["personal.mode"].buttons["我的收藏"].tap()
        let favorite = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "personal.video.", ":local:子目录/第二片段.mp4")).firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 10)); favorite.tap()
        let canvas = app.otherElements["player.canvas"]
        wait(canvas, "label CONTAINS '已显示画面'", timeout: 15)
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5)); app.buttons["暂停"].tap()
        let seek = app.descendants(matching: .any)["player.seekBar"].firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 5))
        seek.movePlaybackThumb(to: 0.8, hold: 3)
        XCTAssertFalse(app.otherElements["player.timelinePreview"].exists, "Releasing the timeline dismisses the preview")
        wait(app.staticTexts["player.elapsed"], "label >= '00:08'")
        app.buttons["返回片库"].tap()
        if UIDevice.current.userInterfaceIdiom == .pad { app.staticTexts["媒体库"].firstMatch.tap() }
        else { app.tabBars.buttons["片库"].tap() }
        sources.tap()
        XCTAssertTrue(app.buttons["sources.importVideos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sources.mountDirectory"].exists)
        let imported = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", "导入的视频")).firstMatch
        for _ in 0..<12 {
            if imported.exists && imported.isHittable { break }
            let list = app.collectionViews["sources.list"]
            // Keep the stroke in the list gutter, away from source-row context menus.
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.8)).press(forDuration: 0.01,
                thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.3)), withVelocity: .fast, thenHoldForDuration: 0)
        }
        XCTAssertTrue(imported.waitForExistence(timeout: 5))
        imported.tap()
        let duplicate = video("demo0 (2).mp4")
        XCTAssertTrue(duplicate.waitForExistence(timeout: 10), "Duplicate imports keep distinct copies")
        // LazyVGrid only exposes instantiated cards; use the library's complete count.
        XCTAssertTrue(app.staticTexts["0 个目录 · 3 个视频"].exists, "Failed mixed selection publishes no partial files")
        duplicate.press(forDuration: 1); app.buttons["删除导入的视频"].tap(); app.buttons["删除 Glide 内的副本"].tap()
        wait(duplicate, "exists == false")
        XCTAssertTrue(app.staticTexts["0 个目录 · 2 个视频"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(video("demo0.mp4").waitForExistence(timeout: 10)); XCTAssertFalse(duplicate.exists)
    }

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
        let speedMenu = app.buttons["player.speed.menu"]
        for _ in 0..<4 { if speedMenu.isHittable { break }; settings.swipeUp() }
        XCTAssertTrue(speedMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(speedMenu.label.contains("2×"), "Right swipe selects double speed")
        app.buttons["player.settings.done"].tap()
        canvas.swipeLeft(velocity: .slow)
        if !app.buttons["播放设置"].exists { canvas.tap() }
        app.buttons["播放设置"].tap()
        for _ in 0..<4 { if speedMenu.isHittable { break }; settings.swipeUp() }
        XCTAssertTrue(speedMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(speedMenu.label.contains("1×"), "Left swipe restores normal speed")
        app.buttons["player.settings.done"].tap()
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
        let transportMenu = ProcessInfo.processInfo.environment["GLIDE_TRANSPORT_MENU_FIXTURE"] == "1"
        if transportMenu {
            app.launchArguments += ["--glide-jellyfin-fixture", "-preferredAudioLanguage", "", "-preferredSubtitleLanguage", "", "-forcedSubtitlesOnly", "NO"]
        }
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
        XCTAssertTrue(app.buttons["player.transport.original"].waitForExistence(timeout: 5))
        if transportMenu {
            let trial = app.buttons["player.transport.original"]
            XCTAssertTrue(trial.isEnabled, "DirectStream=false must not hide or disable a user-requested trial")
            trial.tap()
            XCTAssertTrue(app.buttons["播放设置"].waitForExistence(timeout: 10)); app.buttons["播放设置"].tap()
            let retry = app.buttons["player.transport.original"]
            let retryReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND label CONTAINS %@", "重试原画兼容"), object: retry)
            let retryResult = await XCTWaiter.fulfillment(of: [retryReady], timeout: 15)
            XCTAssertEqual(retryResult, .completed)
            let failed = XCTAttachment(screenshot: app.screenshot()); failed.name = "Manual retry remains after negotiation failure"; failed.lifetime = .keepAlways; add(failed)
            retry.tap()
            XCTAssertTrue(app.buttons["播放设置"].waitForExistence(timeout: 10)); app.buttons["播放设置"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["player.transport.active"].firstMatch.waitForExistence(timeout: 20), "Confirmed video-copy stream must show active status")
        }
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
        XCTAssertEqual(diagnostic["schema"] as? Int, 9)
        XCTAssertEqual(diagnostic["forwardBufferTargetSeconds"] as? Double, 30)
        XCTAssertNotNil(diagnostic["bufferedAheadSeconds"])
        XCTAssertFalse(json.label.contains("/fixture/"), "Exported playback diagnostics must omit file paths")
        if transportMenu {
            XCTAssertEqual(diagnostic["originalTransportAttempts"] as? Int, 2)
            XCTAssertEqual(diagnostic["originalTransportOutcome"] as? String, "active")
            XCTAssertEqual(diagnostic["directStreamFlag"] as? Bool, false)
            let attachment = XCTAttachment(string: json.label)
            attachment.name = "Manual retry survives failure and accepts confirmed copy with false flag"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    @MainActor func testCombinedTimelineSeekAndBuffer() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "30", "-localPlaybackEngine", "avPlayer"]
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
        let lower = target < 0.5 ? "00:01" : "00:08"
        let upper = target < 0.5 ? "00:04" : "00:11"
        let seekedTime = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label >= %@ AND label <= %@", lower, upper), object: app.staticTexts["player.elapsed"])
        XCTAssertEqual(XCTWaiter.wait(for: [seekedTime], timeout: 5), .completed,
                       "The combined bar must still seek; bar=\(String(describing: seekBar.value)), label=\(seekBar.label), elapsed=\(app.staticTexts["player.elapsed"].label)")
    }

    @MainActor func testCompactPlayerControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-controlsDelay", "3", "-seekInterval", "10", "-playbackMode", "sequential"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
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
        // Start a fresh authored sample; the paused first clip can be near its end.
        app.buttons["下一个视频"].tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5))
        let freshFrame = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: app.otherElements["player.canvas"])
        XCTAssertEqual(XCTWaiter.wait(for: [freshFrame], timeout: 5), .completed)
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
            if app.buttons["directory.play"].waitForExistence(timeout: 3) { break }
            let folder = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "folder.")).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 10))
            folder.tap()
        }
        XCTAssertTrue(app.buttons["directory.refresh"].exists)
        app.buttons["directory.refresh"].tap()
        let play = app.buttons["directory.play"]
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
        app.segmentedControls.buttons["WebDAV"].tap()
        let name = app.textFields["名称（可选）"]
        if !name.waitForExistence(timeout: 5), app.buttons["sources.add"].isHittable { app.buttons["sources.add"].tap() }
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Glide WebDAV Fixture")
        let address = app.textFields["服务器地址"]
        address.tap(); address.typeText(ProcessInfo.processInfo.environment["GLIDE_DAV_FIXTURE_ADDRESS"] ?? "http://127.0.0.1:8768/dav/")
        let username = app.textFields["用户名"]
        username.tap(); username.typeText("demo")
        let password = app.secureTextFields["密码"]
        password.tap(); password.typeText("demo\n")
        app.buttons["sources.connect"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 15))
        app.buttons["完成"].tap()
        let play = app.buttons["directory.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 15))
        app.buttons["暂停"].tap()
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        else { app.buttons["player.rotate"].tap() }
        let landscape = NSPredicate { _, _ in app.frame.width > app.frame.height }
        expectation(for: landscape, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        defer { XCUIDevice.shared.orientation = .portrait }
        let back = app.buttons["返回片库"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["播放"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "WebDAV landscape playback"; shot.lifetime = .keepAlways; add(shot)
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .portrait }
        else { app.buttons["player.rotate"].tap() }
        let portrait = NSPredicate { _, _ in app.frame.height > app.frame.width }
        expectation(for: portrait, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        back.tap()
        XCUIDevice.shared.orientation = .portrait
        app.buttons["sources.open"].tap()
        let fixture = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", "Glide WebDAV Fixture")).firstMatch
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

    @MainActor func testRecoveredBufferingRetainsTheWorkingVideoStream() async throws {
        guard let (metricsData, _) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8768/debug/metrics")!),
              let metrics = try? JSONDecoder().decode([String: Int].self, from: metricsData), metrics["buffering_fixture"] == 1 else {
            throw XCTSkip("Run Scripts/fixture_server.py with GLIDE_BUFFERING_FIXTURE=1")
        }
        continueAfterFailure = false
        let negotiations = fixtureMetric("/mock/jellyfin/Items/buffered/PlaybackInfo")
        let delays = fixtureMetric("buffer_delay_finished")
        let app = XCUIApplication()
        if ProcessInfo.processInfo.environment["GLIDE_JELLYFIN_FIXTURE"] == "1" { app.launchArguments += ["--glide-jellyfin-fixture"] }
        app.launchArguments += ["-controlsDelay", "120", "-preferredAudioLanguage", "", "-preferredSubtitleLanguage", ""]
        app.launch()
        if !app.buttons["sources.open"].exists, app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
        XCTAssertTrue(app.buttons["sources.open"].waitForExistence(timeout: 10)); app.buttons["sources.open"].tap()
        let existing = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND (label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@)", "source.", "127.0.0.1:8768", "Glide Stall Fixture", "Glide Recovery Fixture", "Glide Buffer Fixture")).firstMatch
        if existing.exists {
            for _ in 0..<8 { if existing.isHittable { break }; app.collectionViews.firstMatch.swipeUp() }
            XCTAssertTrue(existing.isHittable); existing.tap()
        } else {
            app.buttons["sources.add"].tap()
            let name = app.textFields["名称（可选）"]
            XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
            if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { name.tap() }
            name.typeText("Glide Stall Fixture")
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
        let movie = app.buttons["catalog.buffered"]
        // The same local account is reused while the fixture changes modes.
        if !movie.exists { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(movie.waitForExistence(timeout: 10)); movie.tap()
        XCTAssertTrue(app.buttons["从头播放"].waitForExistence(timeout: 10)); app.buttons["从头播放"].tap()
        let canvas = app.otherElements["player.canvas"]
        let firstFrame = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)
        let frameResult = await XCTWaiter.fulfillment(of: [firstFrame], timeout: 20)
        if frameResult != .completed, app.buttons["播放设置"].isHittable {
            app.buttons["播放设置"].tap(); app.buttons["player.diagnostic"].tap()
            let json = app.staticTexts["diagnostic.json"]
            if json.waitForExistence(timeout: 8) {
                let failure = XCTAttachment(string: json.label)
                failure.name = "Buffering fixture startup diagnostic"; failure.lifetime = .keepAlways; add(failure)
                print("Local buffering fixture diagnostic: " + json.label)
            }
        }
        XCTAssertEqual(frameResult, .completed)
        let elapsed = app.staticTexts["player.elapsed"]
        let initialParts = elapsed.label.split(separator: ":").compactMap { Int($0) }
        XCTAssertEqual(initialParts.count, 2)
        XCTAssertLessThan(initialParts[0] * 60 + initialParts[1], 8, "From beginning must not reuse a previous resume position")
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let parts = elapsed.label.split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 && parts[0] * 60 + parts[1] >= 30
        }, object: elapsed)
        let resumeResult = await XCTWaiter.fulfillment(of: [resumed], timeout: 65)
        XCTAssertEqual(resumeResult, .completed, "The original stream must resume after the delayed segment")
        XCTAssertGreaterThan(fixtureMetric("buffer_delay_finished"), delays)
        app.buttons["暂停"].tap()
        XCTAssertEqual(app.staticTexts["player.delivery"].value as? String, "原画重封装")
        XCTAssertEqual(fixtureMetric("/mock/jellyfin/Items/buffered/PlaybackInfo") - negotiations, 1,
                       "A recovered buffer must not restart negotiation or force video conversion")
        app.buttons["播放设置"].tap(); app.buttons["player.diagnostic"].tap()
        let json = app.staticTexts["diagnostic.json"]
        XCTAssertTrue(json.waitForExistence(timeout: 10))
        let data = try XCTUnwrap(json.label.data(using: .utf8))
        let diagnostic = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let attachment = XCTAttachment(string: json.label)
        attachment.name = "Recovered buffering retains original stream"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(diagnostic["recoveryCount"] as? Int, 0)
        XCTAssertEqual(diagnostic["requestedQuality"] as? String, "automatic")
        XCTAssertGreaterThanOrEqual(diagnostic["bufferingSeconds"] as? Double ?? 0, 8)
        XCTAssertTrue((diagnostic["events"] as? [String] ?? []).contains("buffering_recovered"))
        app.buttons["完成"].tap(); app.buttons["返回片库"].tap()
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
        if ProcessInfo.processInfo.environment["GLIDE_JELLYFIN_FIXTURE"] == "1" { app.launchArguments += ["--glide-jellyfin-fixture"] }
        app.launchArguments += ["-controlsDelay", "60", "-localPlaybackEngine", "vlc"]
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
        // Switching the local server from the buffering fixture can leave its
        // previous catalog in the metadata cache. Refresh through the real UI.
        if !recoveryCard.exists, app.buttons["catalog.buffered"].exists {
            app.scrollViews.firstMatch.swipeDown()
        }
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
        let buffered = app.descendants(matching: .any)["player.seekBar"].firstMatch
        XCTAssertTrue(buffered.waitForExistence(timeout: 5))
        let hasBufferedMedia = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "至"), object: buffered)
        let waitResult5 = await XCTWaiter.fulfillment(of: [hasBufferedMedia], timeout: 10)
        XCTAssertEqual(waitResult5, .completed, "HLS should report loaded segments")
        if !app.buttons["暂停"].isHittable { app.otherElements["player.canvas"].tap() }
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 10)); app.buttons["暂停"].tap()
        let finalDelivery = delivery.value as? String ?? ""
        app.buttons["播放设置"].tap()
        XCTAssertTrue(app.buttons["player.settings.done"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["player.pip"].exists, "Online Jellyfin keeps the native engine despite the local VLC preference")
        app.buttons["player.settings.done"].tap()
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
        app.tabBars.buttons["我的"].tap()
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
        // Directory behavior uses the fixed loopback account; authentication UI is tested separately.
        app.launchArguments += ["--glide-jellyfin-fixture", "-homeBrowseView", "videos", "-controlsDelay", "60"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let fixtureName = "Glide Recovery Fixture"
        let folder = app.buttons["folder.fixture-library"]
        for _ in 0..<4 {
            if folder.waitForExistence(timeout: 3), folder.isHittable { break }
            let back = app.buttons["媒体库"]
            if back.exists && back.isHittable { back.tap() }
            else if app.scrollViews.firstMatch.exists { app.scrollViews.firstMatch.swipeUp() }
        }
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        XCTAssertTrue(NSPredicate(format: "hittable == true").evaluate(with: folder) || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: folder)], timeout: 8) == .completed)
        folder.tap()
        XCTAssertTrue(app.buttons["library.scope"].waitForExistence(timeout: 8))
        chooseMenuItem("包含子目录", from: "library.scope", in: app)
        chooseMenuItem("名称升序", from: "library.sort", in: app)
        if app.buttons["directory.pin"].label.contains("取消固定") { app.buttons["directory.pin"].tap() }
        XCTAssertTrue(app.staticTexts["包含子目录 · 共 3 个视频"].waitForExistence(timeout: 5))
        app.buttons["directory.pin"].tap()
        XCTAssertTrue(app.buttons["directory.pin"].label.contains("取消固定"))
        chooseMenuItem("仅当前层", from: "library.scope", in: app)
        XCTAssertTrue(app.staticTexts["仅当前层 · 共 0 个视频"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["folder.fixture-parent"].exists, "Video view must not render directory tiles")
        let search = app.textFields["library.search"]
        search.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { search.tap() }
        search.typeText("Fixture C\n")
        XCTAssertTrue(app.staticTexts["仅当前层 · 0 个匹配结果"].waitForExistence(timeout: 8))
        chooseMenuItem("包含子目录", from: "library.scope", in: app)
        XCTAssertTrue(app.staticTexts["包含子目录 · 1 个匹配结果"].waitForExistence(timeout: 8), "Changing scope keeps and reruns the search")
        app.buttons["清除搜索"].tap()
        chooseMenuItem("名称降序", from: "library.sort", in: app)
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
        revealLibraryAction("pins.open", in: app); app.buttons["pins.open"].tap()
        let pin = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "pin.", fixtureName)).firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        XCTAssertTrue(app.buttons["library.sort"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["library.sort"].label.contains("名称升序"), "Opening a saved view restores its own original sort rule")
        chooseMenuItem("仅当前层", from: "library.scope", in: app)
        XCTAssertTrue(app.staticTexts["仅当前层 · 共 0 个视频"].waitForExistence(timeout: 8))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["仅当前层 · 共 0 个视频"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["library.sort"].label.contains("名称升序"), "Opening a saved view restores its own original sort rule")
        revealLibraryAction("pins.open", in: app); app.buttons["pins.open"].tap()
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "Pinned directory survives relaunch")
        pin.swipeRight()
        if !app.textFields["bookmark.name"].exists { app.buttons["编辑"].tap() }
        let savedName = app.textFields["bookmark.name"]
        XCTAssertTrue(savedName.waitForExistence(timeout: 5)); savedName.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { savedName.tap() }
        savedName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (savedName.value as? String ?? "").count) + "家庭常看")
        app.buttons["bookmark.sort"].tap(); app.buttons["名称降序"].firstMatch.tap()
        app.buttons["bookmark.mode"].tap(); app.buttons["随机播放"].firstMatch.tap()
        app.buttons["bookmark.save"].tap()
        XCTAssertTrue(pin.waitForExistence(timeout: 5)); XCTAssertTrue(pin.label.contains("家庭常看"))
        pin.swipeLeft(); app.buttons["取消固定"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["directory.pin"].label.contains("固定此目录"))
        if UIDevice.current.userInterfaceIdiom == .pad { app.staticTexts["媒体来源"].firstMatch.tap() }
        else { app.buttons["sources.open"].tap() }
        let fixture = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "source.", fixtureName)).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 8))
        fixture.swipeLeft(); app.buttons["移除"].tap(); app.buttons["同时删除此来源的离线影片"].firstMatch.tap()
        if UIDevice.current.userInterfaceIdiom == .pad { app.staticTexts["媒体库"].firstMatch.tap() }
        else { app.buttons["完成"].tap() }
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
        app.descendants(matching: .any)["player.seekBar"].firstMatch.movePlaybackThumb(to: 0.35)
        let seekCompleted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", beforeSeek), object: app.staticTexts["player.elapsed"])
        XCTAssertEqual(XCTWaiter.wait(for: [seekCompleted], timeout: 8), .completed, "Native Jellyfin playback must react to slider seeking")
        app.buttons["播放设置"].tap(); app.buttons["收藏视频"].tap()
        app.buttons["返回片库"].tap()
        app.tabBars.buttons["我的"].tap()
        let history = app.buttons["personal.video.demo2"]
        XCTAssertFalse(history.exists, "Browsing playback must not create a history entry")
        app.segmentedControls.buttons["我的收藏"].tap()
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        app.tabBars.buttons["片库"].tap()
        app.terminate(); app.launch()
        app.tabBars.buttons["我的"].tap()
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
        app.tabBars.buttons["我的"].tap()
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
        // An old saved directory preference must not override the new default.
        app.launchArguments = ["--glide-jellyfin-fixture", "-homeBrowseView", "directories", "-controlsDelay", "30"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        func snapshot(_ name: String) {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "Professional Family " + name; image.lifetime = .keepAlways; add(image)
        }
        let folder = app.buttons["folder.fixture-library"]
        for _ in 0..<5 {
            if folder.exists && folder.isHittable { break }
            if app.buttons["directory.back"].exists { app.buttons["directory.back"].tap() }
            else if app.buttons["媒体库"].exists { app.buttons["媒体库"].tap() }
            else { app.scrollViews.firstMatch.swipeUp() }
        }
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(folder.frame.height, folder.frame.width * 1.5, "Library entry previews also use a portrait canvas")
        snapshot("00 libraries")
        folder.tap()
        let browse = app.segmentedControls["library.contentView"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        XCTAssertTrue(browse.buttons["媒体"].isSelected, "Entering a home library defaults to media")
        XCTAssertFalse(app.buttons["folder.fixture-parent"].exists)
        app.buttons["library.scope"].tap(); app.buttons["包含子目录"].tap()
        app.buttons["library.sort"].tap(); app.buttons["名称升序"].tap()
        XCTAssertTrue(app.staticTexts["包含子目录 · 共 3 个视频"].waitForExistence(timeout: 10))
        let card = app.buttons["video.demo0"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(card.frame.height, card.frame.width * 1.5, "Home video previews use a portrait canvas")
        if app.frame.width >= 375 && app.frame.width < 600 {
            XCTAssertLessThan(card.frame.width, app.frame.width / 3, "Standard iPhones show three portrait previews per row")
        }
        snapshot("01 media")
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertTrue(browse.buttons["目录"].isHittable, "The top switch stays reachable while scrolling")
        browse.buttons["目录"].tap()
        let parent = app.buttons["folder.fixture-parent"]
        XCTAssertTrue(parent.waitForExistence(timeout: 5)); parent.tap()
        XCTAssertTrue(app.buttons["video.demo0"].waitForExistence(timeout: 10))
        XCTAssertTrue(browse.buttons["媒体"].isSelected, "Entering a child defaults to media, even from directory mode")
        XCTAssertFalse(app.buttons["folder.fixture-leaf"].exists)
        browse.buttons["目录"].tap()
        let leaf = app.buttons["folder.fixture-leaf"]
        XCTAssertTrue(leaf.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(leaf.frame.height, leaf.frame.width * 1.5, "Folder previews use a portrait canvas")
        snapshot("02 directories")
        app.buttons["directory.refresh"].tap()
        XCTAssertTrue(leaf.waitForExistence(timeout: 10))
        XCTAssertTrue(browse.buttons["目录"].isSelected, "Refresh keeps the current manual selection")
        leaf.tap()
        XCTAssertTrue(app.buttons["video.demo0"].waitForExistence(timeout: 10))
        XCTAssertTrue(browse.buttons["媒体"].isSelected, "A deeper folder also defaults to media")
        browse.buttons["目录"].tap()
        XCTAssertTrue(app.staticTexts["没有子目录"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["-homeBrowseView", "directories", "-controlsDelay", "30"]
        app.launch()
        XCTAssertTrue(app.buttons["video.demo0"].waitForExistence(timeout: 10))
        XCTAssertTrue(browse.buttons["媒体"].isSelected, "Relaunch restores the location with media as the default")
        app.buttons["directory.back"].tap()
        XCTAssertTrue(app.buttons["video.demo0"].waitForExistence(timeout: 10))
        XCTAssertTrue(browse.buttons["媒体"].isSelected)
        app.buttons["directory.back"].tap()
        XCTAssertTrue(app.buttons["video.demo0"].waitForExistence(timeout: 10))
        XCTAssertTrue(browse.buttons["媒体"].isSelected)
        app.buttons["directory.back"].tap()
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        XCTAssertFalse(browse.exists, "Server library selection still lists libraries")
        XCTAssertFalse(app.buttons["video.demo0"].exists)
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
        app.buttons["directory.play"].tap()
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

    /// Synthetic loopback media only; records the redesigned hierarchy and one-tap controls.
    @MainActor func testProfessionalMediaLayout() async throws {
        guard (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8768/debug/metrics")!)) != nil else {
            throw XCTSkip("Run the standard Scripts/fixture_server.py for the professional layout review")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--glide-jellyfin-fixture", "-controlsDelay", "60", "-glideQAStartPaused", "YES", "-preferredAudioLanguage", "", "-preferredSubtitleLanguage", "", "-forcedSubtitlesOnly", "NO"]
        app.launch()
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Professional " + name; attachment.lifetime = .keepAlways; add(attachment)
        }
        func open(_ button: XCUIElement, until target: XCUIElement) {
            for _ in 0..<3 {
                if target.exists && target.isHittable { return }
                if button.isHittable { button.tap() }
                if target.waitForExistence(timeout: 4), target.isHittable { return }
            }
            XCTAssertTrue(target.exists && target.isHittable)
        }
        func destination(phone: String, tablet: String) {
            let tab = app.tabBars.buttons[phone]
            if tab.exists { tab.tap(); return }
            let sidebarTitle = app.staticTexts[tablet].firstMatch
            if !sidebarTitle.isHittable {
                let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS[c] %@", "边栏", "sidebar")).firstMatch
                if toggle.exists { toggle.tap() }
            }
            XCTAssertTrue(sidebarTitle.waitForExistence(timeout: 5)); sidebarTitle.tap()
        }
        await openProfessionalMovieCatalog(app)
        XCTAssertTrue(app.buttons["catalog.sort"].exists)
        capture("01 Catalog")
        open(app.buttons["catalog.demo0"], until: app.buttons["detail.play"])
        let audio = app.buttons["detail.audio"], subtitle = app.buttons["detail.subtitle"]
        XCTAssertTrue(audio.waitForExistence(timeout: 10)); XCTAssertTrue(subtitle.exists)
        XCTAssertGreaterThanOrEqual(audio.frame.height, 44); XCTAssertGreaterThanOrEqual(subtitle.frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["detail.play"].frame.height, 44)
        XCTAssertTrue(app.buttons["detail.play"].isHittable, "Primary playback stays reachable without scrolling")
        XCTAssertTrue(app.staticTexts["媒体信息"].exists, "Available server metadata is grouped instead of mixed into track titles")
        capture("02 Detail")
        let favorite = app.buttons["detail.favorite"]
        if !favorite.label.contains("已收藏") { favorite.tap() }
        audio.tap()
        let longAudio = "English DD_2.0 · Dolby Digital+ · Stereo · Original commentary track"
        XCTAssertTrue(app.buttons[longAudio].waitForExistence(timeout: 5))
        capture("03 Audio Tracks")
        app.buttons["服务器默认"].tap()
        subtitle.tap()
        XCTAssertTrue(app.buttons["关闭字幕"].waitForExistence(timeout: 5))
        capture("04 Subtitle Tracks")
        app.buttons["服务器默认"].tap()
        app.buttons["从头播放"].tap()
        let canvas = app.otherElements["player.canvas"]
        let displayed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)
        let result = await XCTWaiter.fulfillment(of: [displayed], timeout: 20)
        XCTAssertEqual(result, .completed)
        if app.buttons["暂停"].isHittable { app.buttons["暂停"].tap() }
        if !app.descendants(matching: .any)["player.quick.speed"].isHittable { canvas.tap() }
        let quickSpeed = app.descendants(matching: .any)["player.quick.speed"]
        XCTAssertTrue(quickSpeed.waitForExistence(timeout: 5)); XCTAssertTrue(quickSpeed.isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["player.quick.audio"].exists); XCTAssertTrue(app.descendants(matching: .any)["player.quick.subtitle"].exists)
        capture("05 Player")
        quickSpeed.tap()
        XCTAssertTrue(app.buttons["1.25×"].waitForExistence(timeout: 5)); capture("06 Quick Speed")
        app.buttons["1.25×"].tap()
        let quickAudio = app.descendants(matching: .any)["player.quick.audio"]
        if quickAudio.isEnabled {
            quickAudio.tap()
            let audioOption = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "player.audio.")).firstMatch
            XCTAssertTrue(audioOption.waitForExistence(timeout: 5)); capture("07 Quick Audio")
            audioOption.tap()
        } else {
            XCTAssertEqual(quickAudio.value as? String, "无可切换音轨")
            capture("07 Audio Availability")
        }
        app.descendants(matching: .any)["player.quick.subtitle"].tap()
        let subtitlesOff = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "关闭字幕")).firstMatch
        XCTAssertTrue(subtitlesOff.waitForExistence(timeout: 5))
        capture("08 Quick Subtitles")
        subtitlesOff.tap()
        app.buttons["播放设置"].tap()
        XCTAssertTrue(app.buttons["player.settings.done"].waitForExistence(timeout: 5)); capture("09 Playback Settings")
        app.buttons["player.settings.done"].tap()
        app.buttons["返回片库"].tap()
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 5))
        destination(phone: "我的", tablet: "收藏与继续观看")
        let mode = app.segmentedControls["personal.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5)); mode.buttons["我的收藏"].tap()
        XCTAssertTrue(app.buttons["personal.video.demo0"].waitForExistence(timeout: 5)); capture("10 Personal")
        destination(phone: "离线", tablet: "离线下载")
        XCTAssertTrue(app.staticTexts["downloads.storage"].waitForExistence(timeout: 5)); capture("11 Downloads")
        destination(phone: "设置", tablet: "设置")
        XCTAssertTrue(app.staticTexts["声音与字幕"].waitForExistence(timeout: 5)); capture("12 Settings")
    }

    @MainActor func testProfessionalMediaAccessibilityLayout() async throws {
        guard (try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8768/debug/metrics")!)) != nil else {
            throw XCTSkip("Run the standard Scripts/fixture_server.py for the accessibility layout review")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--glide-jellyfin-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-controlsDelay", "60"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Professional AX " + name; attachment.lifetime = .keepAlways; add(attachment)
        }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<10 {
                if element.exists && element.isHittable { return }
                app.scrollViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(element.exists && element.isHittable)
        }
        await openProfessionalMovieCatalog(app)
        let movie = app.buttons["catalog.demo0"]
        XCTAssertTrue(movie.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(movie.frame.width, app.windows.firstMatch.frame.width * 0.5, "Accessibility sizes use a single horizontal media row")
        capture("01 Catalog")
        movie.tap()
        let play = app.buttons["detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10)); XCTAssertTrue(play.isHittable)
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        capture("02 Detail")
        let audio = app.buttons["detail.audio"]
        reveal(audio); XCTAssertGreaterThanOrEqual(audio.frame.height, 44)
        audio.tap()
        XCTAssertTrue(app.buttons["服务器默认"].waitForExistence(timeout: 5)); capture("03 Audio Tracks")
        app.buttons["服务器默认"].tap()
        let subtitle = app.buttons["detail.subtitle"]
        reveal(subtitle); XCTAssertGreaterThanOrEqual(subtitle.frame.height, 44)
        XCTAssertTrue(play.isHittable, "Playback remains available after scrolling metadata")
        capture("04 Language Controls")
    }

    @MainActor func testProfessionalCatalogScroll() async throws {
        guard ProcessInfo.processInfo.environment["GLIDE_DESIGN_FIXTURE"] == "1" else {
            throw XCTSkip("Run the dense local catalog with GLIDE_DESIGN_FIXTURE=1")
        }
        func metrics() async throws -> [String: Int] {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8768/debug/metrics")!)
            return try JSONDecoder().decode([String: Int].self, from: data)
        }
        guard let initialMetrics = try? await metrics(), initialMetrics["design_fixture"] == 1 else {
            throw XCTSkip("The loopback server must also use GLIDE_DESIGN_FIXTURE=1")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["--glide-jellyfin-fixture", "-controlsDelay", "60"]
        app.launch()
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Professional Scroll " + name; attachment.lifetime = .keepAlways; add(attachment)
        }
        func frameValues(_ frame: CGRect) -> [String: Double] {
            ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)]
        }
        await openProfessionalMovieCatalog(app)
        let first = app.buttons["catalog.demo0"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["38 部电影"].exists, "The stress catalog contains the two original titles and 36 authored samples")
        let firstIdentifier = first.identifier
        let firstFrame = first.frame
        let beforePoster = try await metrics()
        capture("01 First Card")
        var afterPoster = beforePoster
        for _ in 0..<40 {
            afterPoster = try await metrics()
            if afterPoster["design_first_poster_delivered", default: 0] > 0 { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertGreaterThan(afterPoster["design_first_poster_delivered", default: 0], 0, "The authored poster response must finish")
        // Allow the completed image response to be applied by the next render pass.
        try await Task.sleep(for: .milliseconds(250))
        let loadedFrame = first.frame
        XCTAssertEqual(loadedFrame.width, firstFrame.width, accuracy: 1)
        XCTAssertEqual(loadedFrame.height, firstFrame.height, accuracy: 1)
        XCTAssertEqual(loadedFrame.minY, firstFrame.minY, accuracy: 2, "Artwork replacement must preserve the card layout")
        capture("02 Poster Loaded")
        let scroll = app.scrollViews.firstMatch
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier == %@ OR identifier == %@", "catalog.design-", "catalog.demo0", "catalog.broken"))
        var seen = Set<String>()
        func recordVisibleCards() {
            let viewport = scroll.frame
            for card in cards.allElementsBoundByIndex {
                if card.frame.intersects(viewport), card.isHittable { seen.insert(card.identifier) }
            }
        }
        recordVisibleCards()
        for _ in 0..<10 { scroll.swipeUp(); recordVisibleCards() }
        XCTAssertGreaterThanOrEqual(seen.count, 24, "Scrolling exposes multiple pages rather than recycling two fixture cards")
        capture("03 Lower Catalog")
        for _ in 0..<12 {
            if first.exists && first.isHittable { break }
            scroll.swipeDown()
        }
        XCTAssertTrue(first.exists && first.isHittable)
        XCTAssertEqual(first.frame.width, firstFrame.width, accuracy: 1)
        XCTAssertEqual(first.frame.height, firstFrame.height, accuracy: 1)
        capture("04 Returned To Beginning")
        // Select a middle-page title by stable identity, independent of its translated name.
        scroll.swipeUp(); scroll.swipeUp()
        let viewport = scroll.frame
        let middle = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalog.design-")).allElementsBoundByIndex.first {
            $0.isHittable && $0.frame.minY >= viewport.minY + 4 && $0.frame.maxY <= viewport.maxY - 4
        }
        let selected = try XCTUnwrap(middle, "A complete card from the authored dense catalog must be reachable")
        let selectedID = selected.identifier
        let anchorFrame = selected.frame
        let mediaID = String(selectedID.dropFirst("catalog.".count))
        let detailPath = "/mock/jellyfin/Users/fixture-user/Items/" + mediaID
        let posterPath = "/mock/jellyfin/Items/" + mediaID + "/Images/Primary"
        func backToCatalog() {
            let namedBack = app.navigationBars.buttons["Fixture Movies"]
            if namedBack.exists && namedBack.isHittable { namedBack.tap() }
            else { app.navigationBars.element(boundBy: app.navigationBars.count - 1).buttons.element(boundBy: 0).tap() }
        }
        selected.tap()
        let play = app.buttons["detail.play"]
        let firstDetailReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: play)
        let firstDetailResult = await XCTWaiter.fulfillment(of: [firstDetailReady], timeout: 10)
        XCTAssertEqual(firstDetailResult, .completed)
        let firstVisit = try await metrics()
        backToCatalog()
        let anchor = app.buttons[selectedID]
        XCTAssertTrue(anchor.waitForExistence(timeout: 5)); XCTAssertTrue(anchor.isHittable)
        let restoredFrame = anchor.frame
        XCTAssertLessThan(abs(restoredFrame.minY - anchorFrame.minY), max(44, anchorFrame.height + 18), "Returning from detail preserves the browsed row")
        capture("05 Detail Return Anchor")
        anchor.tap()
        let repeatedDetailReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: play)
        let repeatedDetailResult = await XCTWaiter.fulfillment(of: [repeatedDetailReady], timeout: 10)
        XCTAssertEqual(repeatedDetailResult, .completed)
        let repeatedVisit = try await metrics()
        XCTAssertEqual(repeatedVisit[detailPath, default: 0], firstVisit[detailPath, default: 0], "Repeated entry uses cached detail metadata")
        XCTAssertEqual(repeatedVisit[posterPath, default: 0], firstVisit[posterPath, default: 0], "Repeated entry reuses the decoded or disk-cached poster")
        backToCatalog()
        XCTAssertTrue(anchor.waitForExistence(timeout: 5)); XCTAssertTrue(anchor.isHittable)
        let result: [String: Any] = [
            "catalogTotal": 38, "distinctVisibleCards": seen.count,
            "posterPendingPhaseObserved": beforePoster["design_first_poster_delivered", default: 0] == 0,
            "firstCard": firstIdentifier, "firstFrame": frameValues(firstFrame), "loadedFrame": frameValues(loadedFrame),
            "anchor": selectedID, "anchorBefore": frameValues(anchorFrame), "anchorAfter": frameValues(restoredFrame),
            "detailRequestsAfterFirstVisit": firstVisit[detailPath, default: 0], "detailRequestsAfterRepeatedVisit": repeatedVisit[detailPath, default: 0],
            "posterRequestsAfterFirstVisit": firstVisit[posterPath, default: 0], "posterRequestsAfterRepeatedVisit": repeatedVisit[posterPath, default: 0]
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Professional catalog scroll measurements"; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Source selection restores its saved directory; accept either the library root or catalog.
    @MainActor private func openProfessionalMovieCatalog(_ app: XCUIApplication) async {
        let movie = app.buttons["catalog.demo0"]
        let folder = app.buttons["folder.fixture-movies"]
        let sort = app.buttons["catalog.sort"]
        let root = app.buttons["sources.open"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            movie.exists || folder.exists || sort.exists || root.exists
        }, object: app)
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 20)
        XCTAssertEqual(result, .completed)
        if movie.exists && movie.isHittable { return }
        if sort.exists {
            for _ in 0..<8 {
                if movie.exists && movie.isHittable { return }
                app.scrollViews.firstMatch.swipeDown()
            }
            let libraryRoot = app.buttons["媒体库"]
            if libraryRoot.exists && libraryRoot.isHittable { libraryRoot.tap() }
        }
        // Root directories are lazy; the movie library can be below the fold at AX sizes.
        for _ in 0..<10 {
            if folder.waitForExistence(timeout: 1), folder.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(folder.exists && folder.isHittable); folder.tap()
        XCTAssertTrue(movie.waitForExistence(timeout: 10))
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

extension GlideUITests {
    @MainActor private func mapApp(reset: Bool = true, player: Bool = true) throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["GLIDE_MAP_FIXTURE"] == "1" else { throw XCTSkip("Authored video navigation only") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--glide-map-fixture", "-controlsDelay", "120", "-localPlaybackEngine", "avPlayer", "-selectedServer", "00000000-0000-0000-0000-000000000000"]
        if reset { app.launchArguments.append("--glide-map-reset") }
        if player { app.launchArguments += ["--glide-ui-audit", "--glide-ui-audit-player"] }
        app.launch(); return app
    }
    @MainActor private func waitForMapPlayer(_ app: XCUIApplication) {
        let canvas = app.otherElements["player.canvas"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)], timeout: 25), .completed)
    }
    @MainActor func testContentMapRefinementCacheAndActualSeek() throws {
        let app = try mapApp()
        waitForMapPlayer(app)
        if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
        app.buttons["player.navigation"].tap()
        let frame = app.buttons["map.frame.0"]
        XCTAssertTrue(frame.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: frame)], timeout: 15), .completed)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Video Content Map"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["map.zoom.0"].tap()
        XCTAssertTrue(app.buttons["map.zoom.back"].waitForExistence(timeout: 5)); app.buttons["map.zoom.back"].tap()
        XCTAssertTrue(app.buttons["map.frame.0"].waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: frame)], timeout: 10), .completed)
        app.buttons["map.frame.0"].tap()
        XCTAssertTrue(app.buttons["player.navigation"].waitForExistence(timeout: 10))
        waitForMapPlayer(app)
        XCTAssertFalse(app.staticTexts["player.error"].exists)
        app.buttons["暂停"].tap(); app.buttons["player.navigation"].tap()
        app.buttons["内容地图选项"].tap(); app.buttons["清理内容地图缓存"].tap()
        XCTAssertTrue(app.buttons["map.frame.0"].waitForExistence(timeout: 10))
        app.segmentedControls["map.mode"].buttons["章节"].tap()
        XCTAssertTrue(app.staticTexts["暂无章节"].waitForExistence(timeout: 5))
        app.buttons["map.done"].tap()
    }
    @MainActor func testMomentCreateRestartRenameOpenAndDelete() throws {
        let app = try mapApp()
        waitForMapPlayer(app)
        if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
        app.buttons["player.navigation"].tap()
        let create = app.buttons["map.saveMoment"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: create)], timeout: 15), .completed)
        create.tap()
        let name = app.textFields["moment.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count) + "生日时刻")
        app.buttons["moment.save"].tap()
        XCTAssertTrue(app.buttons["map.done"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--glide-map-fixture", "-controlsDelay", "120", "-localPlaybackEngine", "avPlayer"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 10)); app.tabBars.buttons["我的"].tap()
        app.buttons["personal.moments"].tap()
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "moments.item.")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 8)); XCTAssertTrue(item.label.contains("生日时刻"))
        item.swipeLeft(); app.buttons["重命名"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count) + "旅行时刻")
        app.buttons["moment.save"].tap()
        XCTAssertTrue(item.waitForExistence(timeout: 5)); XCTAssertTrue(item.label.contains("旅行时刻"))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Saved Video Moments"; shot.lifetime = .keepAlways; add(shot)
        item.tap(); waitForMapPlayer(app)
        XCTAssertFalse(app.staticTexts["player.error"].exists)
        app.buttons["返回时刻收藏"].tap()
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.swipeLeft(); app.buttons["删除"].tap()
        XCTAssertTrue(app.staticTexts["还没有时刻收藏"].waitForExistence(timeout: 5))
    }
    @MainActor func testNavigationProductionProbe() throws {
        let app = try mapApp(player: false)
        app.terminate(); app.launchArguments = ["--glide-map-probe", "-localPlaybackEngine", "avPlayer"]
        app.launch()
        let status = app.staticTexts["map.probe.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "内容地图与时刻验证通过"), object: status)], timeout: 55), .completed)
        XCTAssertEqual(app.staticTexts["map.probe.count"].label, "通过 14 项")
    }
    @MainActor func testJellyfinTrickplayAndChapterNavigation() async throws {
        let app = try mapApp(player: false)
        app.terminate(); app.launchArguments = ["--glide-map-fixture", "--glide-jellyfin-fixture", "-controlsDelay", "120"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["片库"].waitForExistence(timeout: 15)); app.tabBars.buttons["片库"].tap()
        let movies = app.buttons["folder.fixture-movies"]
        let catalogBack = app.buttons["catalog.back"]
        let directoryBack = app.buttons["directory.back"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in movies.exists || catalogBack.exists || directoryBack.exists }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        if catalogBack.exists { catalogBack.tap() }
        else if directoryBack.exists { app.buttons["媒体库"].tap() }
        XCTAssertTrue(movies.waitForExistence(timeout: 15)); movies.tap()
        XCTAssertTrue(app.buttons["catalog.demo0"].waitForExistence(timeout: 10))
        app.buttons["catalog.demo0"].tap()
        XCTAssertTrue(app.buttons["detail.play"].waitForExistence(timeout: 10)); app.buttons["detail.play"].tap()
        waitForMapPlayer(app)
        if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
        app.buttons["player.navigation"].tap()
        let frame = app.buttons["map.frame.0"]
        XCTAssertTrue(frame.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: frame)], timeout: 15), .completed)
        XCTAssertTrue(app.staticTexts["map.status"].label.contains("服务器缩略图"))
        app.segmentedControls["map.mode"].buttons["章节"].tap()
        let chapter = app.buttons["map.chapter.chapter-1"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Jellyfin Chapters"; shot.lifetime = .keepAlways; add(shot)
        chapter.tap(); waitForMapPlayer(app)
        XCTAssertFalse(app.staticTexts["player.error"].exists)
        if app.buttons["暂停"].exists { app.buttons["暂停"].tap() }
        let navigation = app.buttons["player.navigation"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: navigation)], timeout: 20), .completed)
        navigation.tap()
        let saveMoment = app.buttons["map.saveMoment"]
        XCTAssertTrue(saveMoment.waitForExistence(timeout: 10))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: saveMoment)], timeout: 15), .completed)
        saveMoment.tap()
        let name = app.textFields["moment.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String ?? "").count) + "服务器时刻")
        app.buttons["moment.save"].tap()
        app.terminate(); app.launchArguments = ["--glide-map-fixture", "-controlsDelay", "120"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 10)); app.tabBars.buttons["我的"].tap()
        app.buttons["personal.moments"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "moments.item.", "服务器时刻")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.tap(); waitForMapPlayer(app)
        XCTAssertFalse(app.staticTexts["player.error"].exists)
    }
}


extension GlideUITests {
    @MainActor func testConvertedASSBilingualTextNativeAndCompatibility() throws {
        guard ProcessInfo.processInfo.environment["GLIDE_ASS_FIXTURE"] == "1" else { throw XCTSkip("Authored ASS-in-SRT reproduction only") }
        continueAfterFailure = false
        let app = XCUIApplication()
        for engine in ["avPlayer", "vlc"] {
            app.launchArguments = ["--glide-ui-audit", "--glide-subtitle-fixture", "--glide-subtitle-reset", "--glide-ass-fixture", "-glideQAStartPaused", "YES", "-controlsDelay", "120", "-localPlaybackEngine", engine, "-preferredSubtitleLanguage", "", "-forcedSubtitlesOnly", "NO"]
            app.launch()
            let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video.' AND identifier ENDSWITH 'ass-fallback.mp4'")).firstMatch
            XCTAssertTrue(video.waitForExistence(timeout: 20))
            video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
            let canvas = app.otherElements["player.canvas"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)], timeout: 20), .completed)
            let overlay = app.staticTexts["player.subtitle.overlay"]
            XCTAssertTrue(overlay.waitForExistence(timeout: 10))
            XCTAssertEqual(overlay.label, "原创中文测试\nOriginal bilingual caption.")
            XCTAssertFalse(overlay.label.contains("\\") || overlay.label.contains("{"))
            app.descendants(matching: .any)["player.seekBar"].firstMatch.movePlaybackThumb(to: 0.5, hold: 1)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "第二句字幕\nSecond caption."), object: overlay)], timeout: 15), .completed)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "ASS converted text " + engine; shot.lifetime = .keepAlways; add(shot)
            app.descendants(matching: .any)["player.quick.subtitle"].tap()
            let off = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "关闭字幕")).firstMatch
            XCTAssertTrue(off.waitForExistence(timeout: 5)); off.tap()
            XCTAssertFalse(overlay.exists)
            app.descendants(matching: .any)["player.quick.subtitle"].tap()
            app.buttons["player.subtitle.sidecar.ass-fallback.srt"].tap()
            XCTAssertTrue(overlay.waitForExistence(timeout: 10)); XCTAssertEqual(overlay.label, "第二句字幕\nSecond caption.")
            app.buttons["返回片库"].tap(); app.terminate()
        }
    }
    @MainActor func testOriginalASSStylesNativeAndCompatibility() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        for engine in ["avPlayer", "vlc"] {
            app.launchArguments = ["--glide-ui-audit", "--glide-subtitle-fixture", "--glide-subtitle-reset", "--glide-ass-style-fixture", "-glideQAStartPaused", "YES", "-controlsDelay", "120", "-localPlaybackEngine", engine, "-preferredSubtitleLanguage", "", "-forcedSubtitlesOnly", "NO"]
            app.launch()
            let video = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'video.' AND identifier ENDSWITH 'ass-style.mp4'")).firstMatch
            XCTAssertTrue(video.waitForExistence(timeout: 30))
            video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
            let canvas = app.otherElements["player.canvas"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已显示画面"), object: canvas)], timeout: 25), .completed)
            app.descendants(matching: .any)["player.seekBar"].firstMatch.movePlaybackThumb(to: 0.1, hold: 1)
            func expectRendered() {
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "ASS已渲染"), object: canvas)], timeout: 15), .completed)
            }
            expectRendered()
            XCTAssertFalse(app.descendants(matching: .any)["player.subtitle.overlay"].exists)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Original ASS colours and fonts " + engine; shot.lifetime = .keepAlways; add(shot)
            app.descendants(matching: .any)["player.seekBar"].firstMatch.movePlaybackThumb(to: 0.2, hold: 1)
            expectRendered() // Static colour/drawing layers can be unchanged across a seek.

            app.descendants(matching: .any)["player.seekBar"].firstMatch.movePlaybackThumb(to: 0.5, hold: 1)
            expectRendered()
            let moved = XCTAttachment(screenshot: app.screenshot()); moved.name = "Original ASS motion " + engine; moved.lifetime = .keepAlways; add(moved)
            func selectSubtitle(_ identifier: String) {
                let shortcut = app.descendants(matching: .any)["player.quick.subtitle"].firstMatch
                let option = app.descendants(matching: .any)[identifier].firstMatch
                XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
                // SwiftUI Menu can be reported as either Button or PopUpButton.
                // Tap its visible centre and wait for the actual menu item.
                shortcut.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                if !option.waitForExistence(timeout: 3) {
                    shortcut.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }
                XCTAssertTrue(option.waitForExistence(timeout: 5))
                // Let XCTest scroll an overflowing native menu item into view.
                option.tap()
                XCTAssertTrue(option.waitForNonExistence(timeout: 5))
            }
            selectSubtitle("player.subtitle.off")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (value CONTAINS %@)", "ASS已渲染"), object: canvas)], timeout: 8), .completed)
            selectSubtitle("player.subtitle.sidecar.ass-style.ass")
            expectRendered()
            app.buttons["返回片库"].tap(); app.terminate()
        }
    }
}
