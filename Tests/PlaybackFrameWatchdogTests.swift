import Foundation
import Testing
@testable import GlideCore

@Suite struct PlaybackFrameWatchdogTests {
    private func expect(_ tracker: inout PlaybackFrameWatchdog, at seconds: Double, requested: Bool = true,
                        playing: Bool = true, frame: Bool = false, external: Bool = false, pip: Bool = false,
                        recovers: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = tracker.shouldRecover(at: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
            requested: requested, playing: playing, frameReady: frame, externalPlayback: external, pictureInPicture: pip)
        #expect(actual == recovers, sourceLocation: sourceLocation)
    }

    @Test func inlineBlackScreenStillRecoversAfterSixSeconds() {
        var tracker = PlaybackFrameWatchdog()
        for time in [0.0, 1, 5, 6] { expect(&tracker, at: time, recovers: false) }
        expect(&tracker, at: 7, recovers: true)
    }
    @Test func pipMayStopInlineFramesWithoutInterruptingPlayback() {
        var tracker = PlaybackFrameWatchdog()
        for time in [0.0, 1, 6, 7, 30, 120] { expect(&tracker, at: time, pip: true, recovers: false) }
    }
    @Test func pipEntryAndExitResetTheInlineFailureDeadline() {
        var tracker = PlaybackFrameWatchdog()
        expect(&tracker, at: 0, recovers: false)
        expect(&tracker, at: 5, recovers: false)
        expect(&tracker, at: 6, pip: true, recovers: false)
        expect(&tracker, at: 120, pip: true, recovers: false)
        expect(&tracker, at: 121, recovers: false)
        expect(&tracker, at: 127, recovers: false)
        expect(&tracker, at: 128, recovers: true)
    }
    @Test func restoredInlineFrameClearsOldFailure() {
        var tracker = PlaybackFrameWatchdog()
        expect(&tracker, at: 0, recovers: false)
        expect(&tracker, at: 5, frame: true, recovers: false)
        expect(&tracker, at: 10, recovers: false)
        expect(&tracker, at: 16, recovers: false)
        expect(&tracker, at: 17, recovers: true)
    }
    @Test func pausedAndBufferingVideoMustNotAccumulateFrameFailure() {
        var tracker = PlaybackFrameWatchdog()
        expect(&tracker, at: 0, recovers: false)
        expect(&tracker, at: 5, requested: false, recovers: false)
        expect(&tracker, at: 100, requested: false, recovers: false)
        expect(&tracker, at: 101, playing: false, recovers: false)
        expect(&tracker, at: 120, playing: false, recovers: false)
        expect(&tracker, at: 121, recovers: false)
        expect(&tracker, at: 128, recovers: true)
    }
    @Test func externalPlaybackIsNotJudgedByTheInlineLayer() {
        var tracker = PlaybackFrameWatchdog()
        for time in [0.0, 7, 120] { expect(&tracker, at: time, external: true, recovers: false) }
    }
}
