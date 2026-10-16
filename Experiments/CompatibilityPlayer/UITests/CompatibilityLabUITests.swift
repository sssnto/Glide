import XCTest
import Vision

final class CompatibilityLabUITests: XCTestCase {
    @MainActor func testCommonContainers() throws { try validate("matrix", count: 4) }
    @MainActor func testInvalidAndMisnamedContainers() throws { try validate("edges", count: 4) }
    @MainActor func testTracksSeekPauseAndRate() throws { try validate("controls", count: 1) }
    @MainActor func testRapidExitAndStaleSeek() throws { try validate("lifecycle", count: 1) }
    @MainActor func testASSSubtitles() throws { try validate("subtitles", count: 2) }
    @MainActor func testASSSubtitleLifecycle() throws { try validate("subtitle-controls", count: 1) }
    @MainActor private func validate(_ suite: String, count: Int) throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--suite", suite]
        if suite == "subtitles" || suite == "subtitle-controls" { app.launchArguments.append("--visual") }
        app.launch()
        let status = app.staticTexts["lab.status"]
        let stages: [(String, Bool)] = suite == "subtitles" ? [("09-ass.mkv", true), ("10-dual-audio-ass.mkv", true)]
            : suite == "subtitle-controls" ? [("control-initial", true), ("control-off", false), ("control-paused-on", true),
                ("control-rate", true), ("control-seek", true), ("control-reopen-off", false), ("control-reopen-on", true)] : []
        if !stages.isEmpty {
            for (name, visible) in stages {
                let frame = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ OR label BEGINSWITH '完成：'", "画面：" + name), object: status)
                XCTAssertEqual(XCTWaiter.wait(for: [frame], timeout: 30), .completed)
                XCTAssertEqual(status.label, "画面：" + name, String(describing: app.textViews["lab.report"].value))
                let shot = app.screenshot()
                let picture = XCTAttachment(screenshot: shot)
                picture.name = name + " on screen"; picture.lifetime = .keepAlways; add(picture)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(shot.image.cgImage), options: [:]).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                XCTAssertEqual(text.lowercased().contains("glide ass subtitle"), visible, "Unexpected ASS visibility: " + text)
                app.buttons["lab.continue"].tap()
            }
        }
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH '完成：'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 90), .completed)
        let json = try XCTUnwrap(app.textViews["lab.report"].value as? String)
        let data = Data(json.utf8)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Compatibility " + suite; attachment.lifetime = .keepAlways; add(attachment)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = suite; screenshot.lifetime = .keepAlways; add(screenshot)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["passed"] as? Bool, true, json)
        XCTAssertEqual((result["results"] as? [[String: Any]])?.count, count)
        XCTAssertFalse(json.contains("file://"))
    }
}
