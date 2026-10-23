import Foundation
import Testing
@testable import GlideCore

@Suite struct PlaybackLoopTests {
    @Test func invalidRangesAreRejected() {
        for (start,end,duration) in [(-1.0,2.0,10.0),(2,2.4,10),(5,2,10),(1,11,10),(1,2,0),(.nan,2,10),(1,.infinity,10),(1,2,.infinity)] {
            #expect(PlaybackLoop(start: start, end: end, duration: duration) == nil)
        }
        #expect(PlaybackLoop(start: 0, end: 0.5, duration: 10) != nil)
        #expect(PlaybackLoop(start: 9, end: 10, duration: 10) != nil)
    }
    @Test func onlyPlayingSettledClockCrossingEndCanLoop() throws {
        let range = try #require(PlaybackLoop(start: 2, end: 4, duration: 10))
        #expect(range.contains(2)); #expect(!range.contains(4)); #expect(!range.contains(.nan))
        #expect(!range.reachedEnd(3.99, playing: true, seeking: false))
        #expect(!range.reachedEnd(4, playing: false, seeking: false))
        #expect(!range.reachedEnd(4, playing: true, seeking: true))
        #expect(range.reachedEnd(4, playing: true, seeking: false))
        #expect(!range.reachedEnd(.nan, playing: true, seeking: false))
    }
    @Test func sentenceRangesUseDelayAndClampAtMediaEdges() throws {
        let row = SubtitleTranscript.Entry(cue: .init(start: 1, end: 4, text: "一句"))
        #expect(row.range(delay: 2, duration: 10)?.start == 3)
        #expect(row.range(delay: -2, duration: 10)?.start == 0)
        #expect(row.range(delay: -2, duration: 10)?.end == 2)
        #expect(row.range(delay: 7, duration: 10)?.end == 10)
        #expect(row.range(delay: -5, duration: 10) == nil)
        #expect(row.range(delay: 10, duration: 10) == nil)
        #expect(row.range(delay: .nan, duration: 10) == nil)
        #expect(row.range(delay: 0, duration: 10)?.mode == .once)
    }
    @Test func transcriptSearchRetainsDuplicateRowsAndStableIdentity() {
        let transcript = SubtitleTranscript(cues: [.init(start: 0,end: 2,text: "Hello 世界"),.init(start: 2,end: 4,text: "Hello 世界")])
        let rows = transcript.search("hello")
        #expect(rows.count == 2); #expect(rows[0].id != rows[1].id)
        #expect(transcript.search("  世界  ").map(\.id) == rows.map(\.id))
        #expect(transcript.search(" ").map(\.id) == transcript.entries.map(\.id))
        #expect(transcript.search("missing").isEmpty)
    }
    @Test func activeSentenceHonorsDelayOverlapAndGaps() {
        let transcript = SubtitleTranscript(cues: [.init(start: 0,end: 4,text: "A"),.init(start: 1,end: 2,text: "B"),.init(start: 6,end: 8,text: "C")])
        #expect(transcript.active(at: 1.5,delay: 0)?.cue.text == "B")
        #expect(transcript.active(at: 2.5,delay: 0)?.cue.text == "A")
        #expect(transcript.active(at: 4,delay: 0) == nil)
        #expect(transcript.active(at: 8,delay: 2)?.cue.text == "C")
        #expect(transcript.active(at: -1,delay: 0) == nil)
    }
    @Test func largeTranscriptLookupAndSearchAreConsistent() {
        let cues = (0..<20_000).map { SubtitleCue(start: Double($0 * 2),end: Double($0 * 2 + 1),text: "台词 \($0)") }
        let transcript = SubtitleTranscript(cues: cues)
        #expect(transcript.active(at: 39_998.5,delay: 0)?.cue.text == "台词 19999")
        #expect(transcript.search("台词 19999").count == 1)
        #expect(transcript.search("").count == 20_000)
    }
    @Test func appearanceMigratesLegacySizesAndRoundTrips() {
        let migrated = SubtitleAppearance.restore(Data(),legacyScale: 150,legacySecondaryScale: 80)
        #expect(migrated.primary.size == 30); #expect(migrated.secondary.size == 24)
        var changed = migrated; changed.secondary.ink = .cyan; changed.primary.outline = 2; changed.background = 0.25
        #expect(SubtitleAppearance.restore(changed.encoded()) == changed)
        #expect(SubtitleAppearance.restore(Data("broken".utf8)).primary.size == 20)
    }
    @Test func appearanceRejectsUnboundedRenderingValues() {
        var value = SubtitleAppearance(); value.primary.size = .infinity; value.secondary.size = -999; value.primary.outline = 100; value.background = .nan
        #expect(value.safe.primary.size == 20); #expect(value.safe.secondary.size == 12)
        #expect(value.safe.primary.outline == 2); #expect(value.safe.background == 0.6)
        #expect(SubtitleAppearance.restore(value.encoded()) == value.safe)
    }
}
