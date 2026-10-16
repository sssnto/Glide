import XCTest
@testable import GlideCore

final class PlaybackEngineModelsTests: XCTestCase {
    func testCompatibilityPreferenceNeverEscapesTheLocalFileBoundary() {
        XCTAssertEqual(PlaybackEngineSelection.resolve(preferred: .vlc, localFile: true, hasHeaders: false), .vlc)
        for preferred in [PlaybackEngineID.avPlayer, .vlc] {
            XCTAssertEqual(PlaybackEngineSelection.resolve(preferred: preferred, localFile: false, hasHeaders: false), .avPlayer)
            XCTAssertEqual(PlaybackEngineSelection.resolve(preferred: preferred, localFile: false, hasHeaders: true), .avPlayer)
            XCTAssertEqual(PlaybackEngineSelection.resolve(preferred: preferred, localFile: true, hasHeaders: true), .avPlayer)
        }
        XCTAssertEqual(PlaybackEngineSelection.resolve(preferred: .avPlayer, localFile: true, hasHeaders: false), .avPlayer)
    }
    func testOnlyLatestLoadAndSeekCanPublish() {
        var lifetime = PlaybackEngineLifetime()
        let oldLoad = lifetime.load, oldSeek = lifetime.beginSeek()
        let newLoad = lifetime.begin()
        XCTAssertFalse(lifetime.accepts(oldLoad))
        XCTAssertTrue(lifetime.accepts(newLoad))
        XCTAssertFalse(lifetime.finishSeek(oldSeek))
        let superseded = lifetime.beginSeek(), latest = lifetime.beginSeek()
        XCTAssertFalse(lifetime.finishSeek(superseded))
        XCTAssertTrue(lifetime.finishSeek(latest))
        XCTAssertFalse(lifetime.finishSeek(latest), "Completion can publish only once")
        let cancelled = lifetime.beginSeek(); lifetime.cancelSeek()
        XCTAssertFalse(lifetime.finishSeek(cancelled))
    }

    func testContainerHintsUseBytesAndTolerateTruncation() {
        XCTAssertEqual(MediaContainer.identify(Data([0x1a, 0x45, 0xdf, 0xa3])), .matroska)
        XCTAssertEqual(MediaContainer.identify(Data([0, 0, 0, 24] + Array("ftypisom".utf8))), .mp4)
        XCTAssertEqual(MediaContainer.identify(Data([0, 0, 0, 24] + Array("ftypqt  ".utf8))), .quickTime)
        XCTAssertEqual(MediaContainer.identify(Data("RIFF1234AVI ".utf8)), .avi)
        XCTAssertEqual(MediaContainer.identify(Data("RIFF1234WAVE".utf8)), .unknown)
        var transport = Data(repeating: 0, count: 377)
        for index in [0, 188, 376] { transport[index] = 0x47 }
        XCTAssertEqual(MediaContainer.identify(transport), .transportStream)
        for count in 0..<12 {
            XCTAssertEqual(MediaContainer.identify(Data(repeating: 0, count: count)), .unknown)
        }
        XCTAssertEqual(MediaContainer.identify(Data("a file named movie.mp4".utf8)), .unknown)
    }

    func testMissingMetadataDoesNotAssertUnsupportedOrNoVideo() {
        let unknown = LocalMediaInspection(container: .matroska)
        XCTAssertFalse(unknown.hasNoVideo)
        XCTAssertNil(unknown.failureMessage)
        XCTAssertEqual(unknown.summary, "未能完成系统检查")
        let audio = LocalMediaInspection(container: .mp4, playable: true, videoTracks: 0, audioTracks: 1)
        XCTAssertTrue(audio.hasNoVideo)
        XCTAssertTrue(audio.failureMessage?.contains("没有视频轨道") == true)
        let corrupt = LocalMediaInspection(container: .mp4, playable: false)
        XCTAssertFalse(corrupt.hasNoVideo)
        XCTAssertNotNil(corrupt.failureMessage)
        let valid = LocalMediaInspection(container: .mp4, playable: true, videoTracks: 1)
        XCTAssertNil(valid.failureMessage, "Metadata eligibility is not a frame guarantee")
    }
}
