import Foundation
import Testing
@testable import GlideCore

struct LinkSkipTests {
    @Test func linkAcceptsSignedQueriesButRejectsAmbiguousOrUnsafeInput() throws {
        let link = try StreamLinkPayload.parse(" https://media.example/movie.mp4?token=fixture&quality=original ")
        #expect(link.url.query == "token=fixture&quality=original")
        for value in ["", "movie.mp4", "file:///tmp/a.mp4", "smb://nas/a.mp4", "javascript:alert(1)", "https://u:p@media.example/a.mp4", "https://media.example/a\nhttps://media.example/b", "https://media.example/a#part", "https://media.example:0/a", "https://media.example:99999/a"] {
            #expect(throws: (any Error).self) { try StreamLinkPayload.parse(value) }
        }
    }
    @Test func headersPreserveValuesAndRejectDuplicatesOrTransportOverrides() throws {
        let value = try StreamLinkPayload.parse("https://example.com/a.mp4", headers: "Referer: https://example.com/watch?a=b\nAuthorization: Bearer fixture")
        #expect(value.headers["Referer"] == "https://example.com/watch?a=b")
        #expect(try value.validated() == value)
        for headers in ["Host: other.example", "Range: bytes=0-", "Content-Length: 1", "Connection: close", "X-Test: a\nx-test: b", "Bad Header: x", "Authorization: x\u{0000}y", "X: ", String(repeating: "x", count: 8193)] {
            #expect(throws: (any Error).self) { try StreamLinkPayload.parseHeaders(headers) }
        }
        #expect(throws: (any Error).self) { try StreamLinkPayload.parse("https://example.com/a.m3u8", headers: "Authorization: Bearer fixture") }
        #expect(try StreamLinkPayload.parse("https://example.com/a.m3u8").headers.isEmpty)
        let injected = StreamLinkPayload(url: URL(string: "https://example.com/a.mp4")!, headers: ["Authorization": "fixture\nCookie: injected"])
        #expect(throws: (any Error).self) { try injected.validated() }
    }
    @Test func strmIsOneBoundedUTF8Address() throws {
        #expect(try StreamLinkPayload.strm(Data("\u{feff}https://example.com/中文%20片.mp4?token=fixture\r\n".utf8)).url.host == "example.com")
        for data in [Data(), Data([0xff]), Data(repeating: 65, count: 65_537), Data("file:///private/video.mp4".utf8), Data("#EXTM3U\nhttps://example.com/a.mp4".utf8), Data("https://example.com/a.mp4\nhttps://example.com/b.mp4".utf8)] {
            #expect(throws: (any Error).self) { try StreamLinkPayload.strm(data) }
        }
    }
    @Test func savedMetadataAndPersonalRecordsContainNoPlaybackSecret() throws {
        let record = SavedStreamLink(id: UUID(), name: "原创样例", host: "media.example", createdAt: Date(), revision: UUID())
        let text = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(!text.contains("headers") && !text.contains("token") && !text.contains("url"))
        #expect(record.video.streamLinkID == record.id && record.video.url == nil)
        #expect(try JSONDecoder().decode(SavedStreamLink.self, from: JSONEncoder().encode(record)) == record)
        let oldVideo = Data(#"{"id":"old","title":"Old","subtitle":"","duration":12,"resume":0}"#.utf8)
        #expect(try JSONDecoder().decode(Video.self, from: oldVideo).streamLinkID == nil)
        #expect(PersonalVideo(video: record.video).video.url == nil)
    }
    @Test func manualIntervalsOverrideOnlyCorrespondingServerKinds() throws {
        let server = [SkipSegment(id: "server-intro", kind: .intro, start: 1, end: 10), SkipSegment(id: "server-recap", kind: .recap, start: 10, end: 15), SkipSegment(id: "server-outro", kind: .outro, start: 90, end: 100)]
        var rule = PlaybackSkipRule(); rule.intro = 8
        let intervals = rule.segments(duration: 100, server: server)
        #expect(intervals.map(\.id) == ["manual-intro", "server-recap", "server-outro"])
        #expect(intervals.first?.contains(7) == true)
        #expect(intervals.first?.contains(8) == false)
        rule.outro = 5; rule.serverMarkers = false
        #expect(rule.segments(duration: 100, server: server).map(\.id) == ["manual-intro", "manual-outro"])
        rule.enabled = false
        #expect(rule.segments(duration: 100, server: server).isEmpty)
    }
    @Test func invalidRulesNeverSkipWholeOrUnknownDuration() throws {
        for pair in [(-1.0, 0.0), (.nan, 0), (.infinity, 0), (1801, 0), (6, 6), (12, 0)] {
            var rule = PlaybackSkipRule(); rule.intro = pair.0; rule.outro = pair.1
            #expect(throws: (any Error).self) { try rule.validate(duration: 12) }
            #expect(rule.segments(duration: 12, server: []).isEmpty)
        }
        var rule = PlaybackSkipRule(); rule.intro = 3; rule.outro = 2
        #expect(rule.segments(duration: 0, server: []).isEmpty)
        let outro = try #require(rule.segments(duration: 12, server: []).last)
        #expect(outro.target(duration: 12) == 11.9)
        #expect(!outro.contains(.nan) && !outro.valid(duration: .infinity))
    }
    @Test func jellyfinTicksIdentityUnknownTypesAndDuplicatesAreValidated() throws {
        let data = Data(#"{"Items":[{"Id":"intro","ItemId":"AB-CD","Type":"Intro","StartTicks":0,"EndTicks":30000000},{"Id":"intro","ItemId":"abcd","Type":"Intro","StartTicks":0,"EndTicks":30000000},{"Id":"other","ItemId":"other","Type":"Intro","StartTicks":0,"EndTicks":30000000},{"Type":"FutureType","ItemId":"abcd","StartTicks":0,"EndTicks":30000000},{"Type":"Outro","ItemId":"abcd","StartTicks":-1,"EndTicks":5}]}"#.utf8)
        let values = try JSONDecoder().decode(JellyfinSegmentResponse.self, from: data).segments(itemID: "abcd")
        #expect(values.count == 1 && values[0].end == 3 && values[0].kind == .intro)
        #expect(!SkipSegment(id: "bad", kind: .intro, start: 0, end: 20).valid(duration: 12))
    }
    @Test func ruleSnapshotsRoundTripWithoutMixingVideos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoverableStore<[String: PlaybackSkipMemory]>(file: root.appendingPathComponent("rules.json"))
        var rule = PlaybackSkipRule(); rule.intro = 5
        let values = ["video-a": PlaybackSkipMemory(sourceID: UUID(), videoID: "a", rule: rule), "video-b": PlaybackSkipMemory(sourceID: UUID(), videoID: "b", rule: PlaybackSkipRule())]
        try store.save(values)
        #expect(try store.load()?.value == values)
        #expect(try store.load()?.value["video-b"]?.rule.automatic == false)
    }
}
