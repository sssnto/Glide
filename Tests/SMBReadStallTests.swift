import XCTest
@testable import GlideCore

final class SMBReadStallTests: XCTestCase {

    func testCachedVideoMayContinueAfterNetworkStops() {
        var monitor = SMBReadStall()
        for second in 0..<60 {
            XCTAssertFalse(monitor.sample(at: Double(second), eligible: true, frames: UInt64(second * 24 + 1), bytes: 1_000_000))
        }
        XCTAssertFalse(monitor.sample(at: 70, eligible: true, frames: 1417, bytes: 1_000_000))
        XCTAssertTrue(monitor.sample(at: 72, eligible: true, frames: 1417, bytes: 1_000_000))
    }

    func testMovingAudioClockDoesNotHideMissingInputAndPictures() {
        var monitor = SMBReadStall()
        XCTAssertFalse(monitor.sample(at: 0, eligible: true, frames: 240, bytes: 2_000_000))
        XCTAssertFalse(monitor.sample(at: 11, eligible: true, frames: 240, bytes: 2_000_000))
        XCTAssertTrue(monitor.sample(at: 12, eligible: true, frames: 240, bytes: 2_000_000))
        XCTAssertFalse(monitor.sample(at: 13, eligible: true, frames: 241, bytes: 2_000_000))
    }

    func testPauseSeekAndBackgroundDoNotBecomeNetworkFailures() {
        var monitor = SMBReadStall()
        XCTAssertFalse(monitor.sample(at: 0, eligible: true, frames: 10, bytes: 10))
        XCTAssertFalse(monitor.sample(at: 100, eligible: false, frames: 10, bytes: 10))
        XCTAssertFalse(monitor.sample(at: 101, eligible: true, frames: 10, bytes: 10))
        XCTAssertFalse(monitor.sample(at: 112, eligible: true, frames: 10, bytes: 10))
        XCTAssertFalse(monitor.sample(at: 113, eligible: true, frames: 11, bytes: 5), "A new input or seek resets progress evidence")
    }

}
