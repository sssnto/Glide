import Foundation
import Testing
@testable import GlideCore

@Test func bufferedTimelineShowsOnlyLoadedIntervals() {
    let normalized = BufferedTimeline.normalized([
        BufferedRange(start: 40, end: 50),
        BufferedRange(start: 0, end: 12),
        BufferedRange(start: 10, end: 20),
        BufferedRange(start: 80, end: 130),
        BufferedRange(start: .nan, end: 90),
        BufferedRange(start: 30, end: 29)
    ], duration: 100)
    #expect(normalized == [BufferedRange(start: 0, end: 20), BufferedRange(start: 40, end: 50), BufferedRange(start: 80, end: 100)])
    #expect(BufferedTimeline.contains(15, in: normalized))
    #expect(!BufferedTimeline.contains(30, in: normalized))
    #expect(!BufferedTimeline.contains(99.9, in: normalized))
    #expect(BufferedTimeline.normalized([BufferedRange(start: 0, end: 5)], duration: .infinity).isEmpty)
}

@Test func nativeBufferingKeepsStartupShortAndScalesWithPlaybackSpeed() {
    let startup = NativePlaybackPolicy.forwardBufferDuration(local: false, firstFrame: false, rate: 1)
    #expect(startup == NativePlaybackPolicy.forwardBufferDuration(local: false, firstFrame: false, rate: 2))
    #expect(startup < NativePlaybackPolicy.forwardBufferDuration(local: false, firstFrame: true, rate: 1))
    let normal = NativePlaybackPolicy.forwardBufferDuration(local: false, firstFrame: true, rate: 1)
    let doubleSpeed = NativePlaybackPolicy.forwardBufferDuration(local: false, firstFrame: true, rate: 2)
    #expect(doubleSpeed / 2 == normal)
    #expect(NativePlaybackPolicy.forwardBufferDuration(local: true, firstFrame: true, rate: 2) == 0)
    #expect(NativePlaybackPolicy.forwardBufferDuration(local: false, firstFrame: true, rate: .nan).isFinite)
    #expect(NativePlaybackPolicy.seekTolerance(local: false, buffered: true) < NativePlaybackPolicy.seekTolerance(local: false, buffered: false))
}

@Test func compatiblePlaybackPreservesVideoWithoutClaimingTranscode() throws {
    let body = JellyfinPlaybackPolicy.body(userID: "u", quality: .compatible)
    #expect(PlaybackDelivery.suspectHEVCMP4("HEVC", tag: "hev1", container: "mp4"))
    #expect(!PlaybackDelivery.suspectHEVCMP4("HEVC", tag: "hvc1", container: "mp4"))
    #expect(body["EnableDirectPlay"] as? Bool == false)
    #expect(body["EnableDirectStream"] as? Bool == true)
    #expect(body["EnableTranscoding"] as? Bool == false)
    #expect(body["AllowVideoStreamCopy"] as? Bool == true)
    #expect(PlaybackDelivery.negotiated(url: URL(string: "https://example.test/a.m3u8?AllowVideoStreamCopy=true")!, quality: .automatic) == .serverStream)
    #expect(PlaybackDelivery.negotiated(url: URL(string: "https://example.test/a.m3u8?VideoCodec=copy&AudioCodec=copy")!, quality: .compatible) == .remux)
    #expect(PlaybackDelivery.negotiated(url: URL(string: "https://example.test/a.m3u8?VideoCodec=copy&AudioCodec=aac")!, quality: .compatible) == .audioConversion)
}

@Test func progressConflictHonorsUnsentLocalChangesAndNewerServer() {
    let local = ProgressSnapshot(position: 20, updatedAt: Date(timeIntervalSince1970: 100), pending: true)
    #expect(local.resolved(serverPosition: 10, serverLastPlayed: Date(timeIntervalSince1970: 90)) == 20)
    #expect(local.resolved(serverPosition: 35, serverLastPlayed: Date(timeIntervalSince1970: 110)) == 35)
    #expect(local.resolved(serverPosition: 0, serverLastPlayed: nil) == 20)
    let sent = ProgressSnapshot(position: 20, updatedAt: Date(timeIntervalSince1970: 100), pending: false)
    #expect(sent.resolved(serverPosition: 0, serverLastPlayed: nil) == 0)
}

@Test func languagePreferencesUseSemanticLanguageAndForcedFlag() throws {
    let data = Data("""
    [{"Index":14,"Type":"Subtitle","Language":"chi","IsForced":false},
     {"Index":27,"Type":"Subtitle","Language":"zho","IsForced":true},
     {"Index":33,"Type":"Subtitle","Language":"eng"}]
    """.utf8)
    let streams = try JSONDecoder().decode([CatalogItem.Stream].self, from: data)
    #expect(LanguagePreference.stream(streams, language: "zh-CN", forcedOnly: true) == 27)
    #expect(LanguagePreference.stream(streams, language: "en") == 33)
    #expect(LanguagePreference.stream(streams, language: "ja") == nil)
}

@Test func diagnosticsNeverIncludeURLAndKeepBoundedEvents() {
    #expect(PlaybackDiagnostic.token("https://private.test/movie?api_key=secret") == nil)
    var value = PlaybackDiagnostic()
    for i in 0..<40 { value.event("event_\(i)") }
    #expect(value.events.count == 30)
    #expect(!value.export.contains("api_key"))
    #expect(value.schema == 3)
}

@Test func nativeHLSUnwrapsOnlyOneSelfContainedRendition() throws {
    let master = URL(string: "https://nas.test/jellyfin/videos/1/master.m3u8?ApiKey=private-token&VideoCodec=h264")!
    let header = "#EXTM3U\n#EXT-X-VERSION:3\n"
    let stream = "#EXT-X-STREAM-INF:BANDWIDTH=8000000,VIDEO-RANGE=SDR,CODECS=\"avc1.424029,mp4a.40.2\"\nmain.m3u8?PlaySessionId=session\n"
    let media = try #require(NativeHLSPlaylist.mediaURL(master: master, data: Data((header + stream).utf8)))
    #expect(media.path == "/jellyfin/videos/1/main.m3u8")
    let query = try #require(URLComponents(url: media, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.first { $0.name == "ApiKey" }?.value == "private-token")
    #expect(query.first { $0.name == "PlaySessionId" }?.value == "session")
    #expect(!query.contains { $0.name == "VideoCodec" })
    let explicitToken = stream.replacingOccurrences(of: "main.m3u8?PlaySessionId=session", with: "main.m3u8?api_key=child-token")
    #expect(NativeHLSPlaylist.mediaURL(master: master, data: Data((header + explicitToken).utf8))?.query == "api_key=child-token")
    #expect(NativeHLSPlaylist.mediaURL(master: master, data: Data((header + stream + stream).utf8)) == nil)
    for tag in ["#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",URI=\"audio.m3u8\"", "#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"key\"", "#EXT-X-DEFINE:NAME=\"token\",VALUE=\"value\"", "#EXT-X-CONTENT-STEERING:SERVER-URI=\"steering.json\"", "#EXT-X-START:TIME-OFFSET=10"] {
        #expect(NativeHLSPlaylist.mediaURL(master: master, data: Data((header + tag + "\n" + stream).utf8)) == nil)
    }
    for group in ["AUDIO", "SUBTITLES", "VIDEO"] {
        let grouped = stream.replacingOccurrences(of: "BANDWIDTH=8000000", with: "BANDWIDTH=8000000,\(group)=\"alternate\"")
        #expect(NativeHLSPlaylist.mediaURL(master: master, data: Data((header + grouped).utf8)) == nil)
    }
    for protected in [stream.replacingOccurrences(of: "VIDEO-RANGE=SDR", with: "VIDEO-RANGE=PQ"),
                      stream.replacingOccurrences(of: "VIDEO-RANGE=SDR", with: "VIDEO-RANGE=HLG"),
                      stream.replacingOccurrences(of: "avc1.424029", with: "hvc1.2.4.L150.B0"),
                      stream.replacingOccurrences(of: "BANDWIDTH=8000000", with: "BANDWIDTH=8000000,SUPPLEMENTAL-CODECS=\"dvh1.08.06\"")] {
        #expect(NativeHLSPlaylist.mediaURL(master: master, data: Data((header + protected).utf8)) == nil)
    }
}

@Test func nativeHLSRejectsInvalidAndCrossOriginPlaylists() {
    let master = URL(string: "https://nas.test/jellyfin/master.m3u8?api_key=secret")!
    for uri in ["https://other.test/main.m3u8", "http://nas.test/main.m3u8", "file:///tmp/main.m3u8", "https://user:password@nas.test/main.m3u8", "main.mp4", "master.m3u8?api_key=secret"] {
        let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,CODECS=\"avc1.424029,mp4a.40.2\"\n\(uri)\n"
        #expect(NativeHLSPlaylist.mediaURL(master: master, data: Data(text.utf8)) == nil)
    }
    for text in ["not a playlist", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000", "#EXTM3U\n#EXTINF:4\nsegment.ts", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\n#EXT-X-STREAM-INF:BANDWIDTH=2000\nmain.m3u8"] {
        #expect(NativeHLSPlaylist.mediaURL(master: master, data: Data(text.utf8)) == nil)
    }
    #expect(NativeHLSPlaylist.mediaURL(master: master, data: Data(repeating: 32, count: 262_145)) == nil)
}

@Test func nativeDecoderDiagnosticsRetainCodesWithoutSensitiveErrorText() throws {
    let underlying = NSError(domain: "CoreMediaErrorDomain", code: -12927, userInfo: [NSLocalizedDescriptionKey: "https://nas.test/private?api_key=secret"])
    let root = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: underlying])
    var value = PlaybackDiagnostic()
    value.errorChain = PlaybackFailure.chain(root)
    #expect(value.errorChain == [PlaybackFailure(domain: "AVFoundationErrorDomain", code: -11800), PlaybackFailure(domain: "CoreMediaErrorDomain", code: -12927)])
    #expect(!value.export.contains("secret"))
    #expect(!value.export.contains("nas.test"))
    let untrusted = NSError(domain: "private-url-with-secret", code: 500)
    #expect(PlaybackFailure.chain(untrusted).first?.domain == "ApplicationError")
    value.schema = 2
    let legacy = try JSONDecoder().decode(PlaybackDiagnostic.self, from: Data(value.export.utf8))
    #expect(legacy.schema == 2)
    #expect(legacy.outputVideoCodec == nil)
}

@Test func externalSubtitlesParseSRTVTTAndRespectPositiveDelay() {
    let srt = "1\n00:00:01,000 --> 00:00:03,000\n<b>你好</b>\n\n2\n00:00:04,000 --> 00:00:05,500\n第二句"
    let cues = SubtitleCue.parse(srt)
    #expect(cues.count == 2)
    #expect(SubtitleCue.visible(cues, time: 1.5, delay: 1) == nil)
    #expect(SubtitleCue.visible(cues, time: 2.5, delay: 1) == "你好")
    #expect(SubtitleCue.visible(cues, time: 4, delay: 1) == nil)
    #expect(SubtitleCue.parse("WEBVTT\n\n00:01.000 --> 00:03.000 align:center\nhello").first?.text == "hello")
    #expect(SubtitleCue.parse("1\nwrong --> time\ntext").isEmpty)
}
