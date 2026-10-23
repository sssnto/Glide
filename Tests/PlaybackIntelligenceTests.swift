import Foundation
import Testing
@testable import GlideCore

@Test func original4KBufferingIncludesPortraitVideoAndExcludesConvertedOrLocalMedia() {
    #expect(NativeRebufferPolicy.eligible(local: false, preservesVideo: true, width: 2160, height: 3840, bitrate: nil))
    #expect(NativeRebufferPolicy.eligible(local: false, preservesVideo: true, width: 3840, height: 2160, bitrate: nil))
    #expect(NativeRebufferPolicy.eligible(local: false, preservesVideo: true, width: 1920, height: 1080, bitrate: 25_000_000))
    #expect(!NativeRebufferPolicy.eligible(local: true, preservesVideo: true, width: 3840, height: 2160, bitrate: 50_000_000))
    #expect(!NativeRebufferPolicy.eligible(local: false, preservesVideo: false, width: 3840, height: 2160, bitrate: 50_000_000))
    #expect(!NativeRebufferPolicy.eligible(local: false, preservesVideo: true, width: 1920, height: 1080, bitrate: nil))
}

@Test func rebufferingRequiresUsefulContiguousMediaInsteadOfTheNextSmallPacket() {
    #expect(NativeRebufferPolicy.resumeGoal(rate: 1, remaining: 60) == 6)
    #expect(!NativeRebufferPolicy.canResume(ahead: 1.057, rate: 1, remaining: 60, bufferFull: false))
    #expect(!NativeRebufferPolicy.canResume(ahead: 5.99, rate: 1, remaining: 60, bufferFull: false))
    #expect(NativeRebufferPolicy.canResume(ahead: 6, rate: 1, remaining: 60, bufferFull: false))
    #expect(NativeRebufferPolicy.resumeGoal(rate: 2, remaining: 60) == 12)
    #expect(!NativeRebufferPolicy.canResume(ahead: 6, rate: 2, remaining: 60, bufferFull: false))
    #expect(NativeRebufferPolicy.resumeGoal(rate: 8, remaining: 60) == 12)
    #expect(!NativeRebufferPolicy.canResume(ahead: .nan, rate: 1, remaining: 60, bufferFull: false))
}

@Test func rebufferingHasAnEndOfMovieAndPlatformCapacityEscape() {
    #expect(NativeRebufferPolicy.resumeGoal(rate: 1, remaining: 0.4) == nil)
    #expect(NativeRebufferPolicy.resumeGoal(rate: 1, remaining: .infinity) == nil)
    #expect(NativeRebufferPolicy.canResume(ahead: 2.86, rate: 1, remaining: 3, bufferFull: false))
    #expect(!NativeRebufferPolicy.canResume(ahead: 1, rate: 1, remaining: 60, bufferFull: true))
    #expect(NativeRebufferPolicy.canResume(ahead: 2, rate: 1, remaining: 60, bufferFull: true))
    #expect(NativeRebufferPolicy.resumeGoal(rate: .nan, remaining: 60) == 6)
}

@Test func jellyfinPerformanceMetadataDecodesWithoutRequiringNewFieldsInOlderServers() throws {
    let source = Data(#"{"Index":0,"Type":"Video","Width":2160,"Height":3840,"BitRate":48000000,"RealFrameRate":59.94,"AverageFrameRate":59.94}"#.utf8)
    let stream = try JSONDecoder().decode(CatalogItem.Stream.self, from: source)
    #expect(stream.BitRate == 48_000_000)
    #expect(stream.AverageFrameRate == 59.94)
    #expect(try JSONDecoder().decode(CatalogItem.Stream.self, from: Data(#"{"Index":0,"Type":"Video"}"#.utf8)).BitRate == nil)
}

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

@Test func nativeBufferingAdaptsToRebufferingWithoutDelayingStartupOrGrowingWithoutBounds() {
    #expect(NativePlaybackPolicy.forwardBufferDuration(local: false, firstFrame: true, rate: 1) == 30)
    #expect(NativePlaybackPolicy.forwardBufferDuration(local: false, firstFrame: true, rate: 2) == 60)
    #expect(NativePlaybackPolicy.forwardBufferDuration(local: false, firstFrame: true, rate: 1, rebuffered: true) == 45)
    #expect(NativePlaybackPolicy.forwardBufferDuration(local: false, firstFrame: true, rate: 2, rebuffered: true) == 90)
    #expect(NativePlaybackPolicy.forwardBufferDuration(local: false, firstFrame: true, rate: 8, rebuffered: true) == 90)
    #expect(NativePlaybackPolicy.forwardBufferDuration(local: false, firstFrame: false, rate: 2, rebuffered: true) == 2)
    #expect(NativePlaybackPolicy.forwardBufferDuration(local: true, firstFrame: true, rate: 2, rebuffered: true) == 0)
    for invalid in [Float.nan, .infinity, -.infinity, 0, -1] {
        #expect(NativePlaybackPolicy.forwardBufferDuration(local: false, firstFrame: true, rate: invalid) == 30)
    }
}

@Test func bufferedAheadDoesNotCountDisjointDownloadedRanges() {
    let ranges = BufferedTimeline.normalized([BufferedRange(start: 0, end: 12), BufferedRange(start: 30, end: 70)], duration: 80)
    #expect(BufferedTimeline.ahead(of: 5, in: ranges) == 7)
    #expect(BufferedTimeline.ahead(of: 12, in: ranges) == 0)
    #expect(BufferedTimeline.ahead(of: 20, in: ranges) == 0)
    #expect(BufferedTimeline.ahead(of: 30, in: ranges) == 40)
    #expect(BufferedTimeline.ahead(of: 70, in: ranges) == 0)
    #expect(BufferedTimeline.ahead(of: .nan, in: ranges) == 0)
}

@Test func compatiblePlaybackPreservesVideoWithoutClaimingTranscode() throws {
    let body = JellyfinPlaybackPolicy.body(userID: "u", quality: .compatible)
    #expect(PlaybackDelivery.suspectHEVCMP4("HEVC", tag: "hev1", container: "mp4"))
    #expect(!PlaybackDelivery.suspectHEVCMP4("HEVC", tag: "hvc1", container: "mp4"))
    #expect(body["EnableDirectPlay"] as? Bool == false)
    #expect(body["EnableDirectStream"] as? Bool == true)
    #expect(body["EnableTranscoding"] as? Bool == true, "HLS remux/audio conversion uses this route; the copy URL is validated separately")
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
    #expect(value.schema == 10)
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

@Test func hdrSourceNeverBypassesHLSMasterValidation() {
    let master = URL(string: "https://nas.test/master.m3u8?api_key=secret")!
    let data = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=8000000,VIDEO-RANGE=SDR,CODECS=\"avc1.424029,mp4a.40.2\"\nmain.m3u8\n".utf8)
    #expect(NativeHLSPlaylist.mediaURL(master: master, data: data, sourceIsHDR: true) == nil)
    #expect(NativeHLSPlaylist.mediaURL(master: master, data: data, sourceIsHDR: false) != nil)
    #expect(NativeColorPolicy.isHDR(range: "HDR10"))
    #expect(NativeColorPolicy.isHDR(range: "DOVIWithHDR10"))
    #expect(NativeColorPolicy.isHDR(range: nil, transfer: "smpte2084"))
    #expect(!NativeColorPolicy.isHDR(range: "SDR", transfer: "bt709"))
    #expect(!NativeColorPolicy.isHDR(range: "DOVIWithSDR"))
}

@Test func nativeHDRInitialSelectionRequiresFirstDeclaredHEVCHDRVariant() {
    let master = URL(string: "https://nas.test/master.m3u8?api_key=secret")!
    let hdr = "#EXT-X-STREAM-INF:BANDWIDTH=22000000,CODECS=\"hvc1.2.4.L150.B0,mp4a.40.2\",VIDEO-RANGE=PQ,AUDIO=\"audio\"\nmain.m3u8\n"
    let sdr = "#EXT-X-STREAM-INF:BANDWIDTH=22000000,CODECS=\"avc1.42E029,mp4a.40.2\",VIDEO-RANGE=SDR\nsdr.m3u8\n"
    let header = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",URI=\"audio.m3u8\"\n"
    func prefers(_ text: String, codec: String = "hevc", isHDR: Bool = true) -> Bool {
        NativeHLSPlaylist.prefersFirstHDRVariant(master: master, data: Data(text.utf8), sourceCodec: codec, sourceIsHDR: isHDR)
    }
    #expect(prefers(header + hdr + sdr))
    #expect(prefers(header + hdr.replacingOccurrences(of: "VIDEO-RANGE=PQ", with: "VIDEO-RANGE=HLG") + sdr))
    #expect(!prefers(header + sdr + hdr), "Never request the first variant when SDR is first")
    #expect(!prefers(header + hdr, codec: "h264"))
    #expect(!prefers(header + hdr, isHDR: false))
    #expect(!prefers(header + hdr.replacingOccurrences(of: "VIDEO-RANGE=PQ", with: "VIDEO-RANGE=SDR")))
    #expect(NativeHLSPlaylist.mediaURL(master: master, data: Data((header + hdr + sdr).utf8), sourceIsHDR: true) == nil,
            "Audio renditions and the complete HDR master remain intact")
}

@Test func nativeHDRInitialSelectionRejectsAmbiguousAndInvalidMasters() {
    let master = URL(string: "https://nas.test/master.m3u8?api_key=secret")!
    let stream = "#EXT-X-STREAM-INF:BANDWIDTH=22000000,CODECS=\"hvc1.2.4.L150.B0,mp4a.40.2\",VIDEO-RANGE=PQ\nmain.m3u8\n"
    func prefers(_ text: String) -> Bool {
        NativeHLSPlaylist.prefersFirstHDRVariant(master: master, data: Data(text.utf8), sourceCodec: "hevc", sourceIsHDR: true)
    }
    for uri in ["https://other.test/main.m3u8", "http://nas.test/main.m3u8", "https://user:password@nas.test/main.m3u8", "main.mp4", "master.m3u8?api_key=secret"] {
        #expect(!prefers("#EXTM3U\n" + stream.replacingOccurrences(of: "main.m3u8", with: uri)))
    }
    for change in [stream.replacingOccurrences(of: "hvc1.", with: "not-hvc1."),
                   stream.replacingOccurrences(of: "BANDWIDTH=22000000", with: "BANDWIDTH=0"),
                   stream.replacingOccurrences(of: "VIDEO-RANGE=PQ", with: "VIDEO-RANGE=PQ,VIDEO-RANGE=SDR"),
                   stream.replacingOccurrences(of: "mp4a.40.2\"", with: "mp4a.40.2"),
                   stream.replacingOccurrences(of: "main.m3u8", with: "#EXT-X-STREAM-INF:BANDWIDTH=1000\nmain.m3u8")] {
        #expect(!prefers("#EXTM3U\n" + change))
    }
    for tag in ["#EXT-X-DEFINE:NAME=\"codec\",VALUE=\"hevc\"", "#EXT-X-CONTENT-STEERING:SERVER-URI=\"steering.json\""] {
        #expect(!prefers("#EXTM3U\n" + tag + "\n" + stream))
    }
    #expect(!prefers("#EXTM3U\n#EXTINF:4\nsegment.ts"))
    #expect(!NativeHLSPlaylist.prefersFirstHDRVariant(master: master, data: Data(repeating: 32, count: 262_145), sourceCodec: "hevc", sourceIsHDR: true))
}

@Test func hdrAVCConversionHasOneSDRConstraintWithoutChangingCopyOrHEVC() throws {
    let original = URL(string: "https://nas.test/master.m3u8?VideoCodec=h264&H264-RangeType=HDR10&AllowVideoStreamCopy=true&api_key=secret&PlaySessionId=abc")!
    let fixed = NativeColorPolicy.constrainAVC(original, sourceIsHDR: true)
    let pairs = try #require(URLComponents(url: fixed, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(pairs.filter { $0.name.lowercased() == "h264-rangetype" }.count == 1)
    #expect(NativeColorPolicy.outputOptions(fixed).range == "SDR")
    #expect(pairs.first { $0.name == "AllowVideoStreamCopy" }?.value == "false")
    #expect(pairs.first { $0.name == "api_key" }?.value == "secret")
    #expect(pairs.first { $0.name == "PlaySessionId" }?.value == "abc")
    #expect(NativeColorPolicy.constrainAVC(original, sourceIsHDR: false) == original)
    for codec in ["hevc", "copy", "h264,hevc"] {
        let copy = URL(string: "https://nas.test/master.m3u8?VideoCodec=" + codec)!
        #expect(NativeColorPolicy.constrainAVC(copy, sourceIsHDR: true) == copy)
    }
}

@Test func outputColorValidationDoesNotGuessFromTenBitOrBT2020Alone() {
    #expect(NativeColorPolicy.unsupportedAVCOutput(codec: "avc1", transfer: "SMPTE_ST_2084_PQ"))
    #expect(NativeColorPolicy.unsupportedAVCOutput(codec: "avc3", transfer: "ITU_R_2100_HLG"))
    #expect(!NativeColorPolicy.unsupportedAVCOutput(codec: "hvc1", transfer: "SMPTE_ST_2084_PQ"))
    #expect(!NativeColorPolicy.unsupportedAVCOutput(codec: "avc1", transfer: "ITU_R_709_2"))
    #expect(!NativeColorPolicy.unsupportedAVCOutput(codec: "avc1", transfer: nil))
    #expect(!NativeColorPolicy.isHDR(range: nil, transfer: "bt2020"))
    #expect(NativeColorPolicy.isHDR(range: "SDR", transfer: "smpte2084"))
    #expect(NativeColorPolicy.isHDR(range: "DOVIWithSDR", transfer: "arib-std-b67"))
    #expect(NativeColorPolicy.unexpectedHDRTransfer(requestedRange: "SDR", actualTransfer: "SMPTE_ST_2084_PQ"))
    #expect(!NativeColorPolicy.unexpectedHDRTransfer(requestedRange: nil, actualTransfer: "SMPTE_ST_2084_PQ"))
    #expect(!NativeColorPolicy.unexpectedHDRTransfer(requestedRange: "SDR", actualTransfer: "ITU_R_709_2"))
}

@Test func nativeHDRPrefersNegotiatedHEVCAndKeepsCodecQualifiedRangesSeparate() throws {
    let original = URL(string: "https://nas.test/master.m3u8?videoCodec=h264,hevc&h264-rangetype=SDR&api_key=secret&PlaySessionId=abc")!
    let selected = NativeColorPolicy.preferHEVCForHDR(original, sourceCodec: "HEVC", sourceIsHDR: true)
    let items = try #require(URLComponents(url: selected, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items.filter { $0.name.lowercased() == "videocodec" }.count == 1)
    #expect(NativeColorPolicy.outputOptions(selected).codec == "hevc")
    #expect(NativeColorPolicy.outputOptions(selected).range == nil, "AVC SDR does not describe HEVC HDR")
    #expect(NativeColorPolicy.outputOptions(original).range == nil, "Multiple candidates have no single requested dynamic range")
    #expect(items.first { $0.name == "api_key" }?.value == "secret")
    #expect(items.first { $0.name == "PlaySessionId" }?.value == "abc")
    #expect(NativeColorPolicy.preferHEVCForHDR(original, sourceCodec: "hevc", sourceIsHDR: false) == original)
    #expect(NativeColorPolicy.preferHEVCForHDR(original, sourceCodec: "h264", sourceIsHDR: true) == original)
    let avcOnly = URL(string: "https://nas.test/master.m3u8?VideoCodec=h264&h264-rangetype=SDR")!
    #expect(NativeColorPolicy.preferHEVCForHDR(avcOnly, sourceCodec: "hevc", sourceIsHDR: true) == avcOnly)
    #expect(NativeColorPolicy.outputOptions(avcOnly).range == "SDR")
    let hevcRange = URL(string: "https://nas.test/master.m3u8?VideoCodec=hevc&hevc-rangetype=HDR10&h264-rangetype=SDR")!
    #expect(NativeColorPolicy.outputOptions(hevcRange).range == "HDR10")
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
