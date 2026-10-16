import Foundation
import Testing
@testable import GlideCore

@Test func jellyfinCodecCandidateURLIsExplicitlyConstrainedToVideoCopy() throws {
    let url = URL(string: "https://fixture.invalid/jellyfin/Videos/id/master.m3u8?api_key=secret&VideoCodec=h264,hevc&AudioCodec=aac&MediaSourceId=version&PlaySessionId=session&AllowVideoStreamCopy=true")!
    let copy = try OriginalTransportPolicy.videoCopyURL(url, sourceCodec: "h264")
    let query = URLComponents(url: copy, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(query.first { $0.name == "VideoCodec" }?.value == "copy")
    #expect(query.first { $0.name == "AudioCodec" }?.value == "aac")
    #expect(query.first { $0.name == "MediaSourceId" }?.value == "version")
    #expect(query.first { $0.name == "PlaySessionId" }?.value == "session")
    #expect(query.first { $0.name == "api_key" }?.value == "secret")
    #expect(query.filter { $0.name.lowercased() == "videocodec" }.count == 1)
    #expect(PlaybackDelivery.negotiated(url: copy, quality: .compatible) == .audioConversion)
    for invalid in ["VideoCodec=h264&AllowVideoStreamCopy=false", "VideoCodec=h264&SubtitleMethod=Encode", "VideoCodec=vp9", "AudioCodec=aac"] {
        #expect(throws: OriginalTransportError.self) {
            try OriginalTransportPolicy.videoCopyURL(URL(string: "https://fixture.invalid/master.m3u8?" + invalid)!, sourceCodec: "h264")
        }
    }
    #expect(throws: OriginalTransportError.self) { try OriginalTransportPolicy.videoCopyURL(url, sourceCodec: "h264", burnsSubtitles: true) }
}

@Test func originalTransportProbesLargeNetworkDirectSourcesBasedOnLoad() {
    func preferred(local: Bool = false, delivery: PlaybackDelivery = .direct,
                   width: Int? = 1920, height: Int? = 1080, bitrate: Int? = 8_000_000) -> Bool {
        OriginalTransportPolicy.prefersSegments(local: local, delivery: delivery,
            width: width, height: height, bitrate: bitrate)
    }
    #expect(preferred(width: 3840, height: 2160))
    #expect(preferred(width: 2160, height: 3840))
    #expect(preferred(width: nil, height: nil, bitrate: 20_000_000))
    #expect(!preferred(bitrate: 19_999_999))
    #expect(!preferred(width: nil, height: nil, bitrate: nil))
    #expect(!preferred(local: true, width: 3840))
    #expect(!preferred(delivery: .remux, width: 3840))
    #expect(!preferred(delivery: .videoConversion, width: 3840))
}

@Test func explicitManualRetryRemainsAvailableAfterAutomaticFailureButCannotOverlap() {
    var recovery = OriginalTransportRecovery()
    let auto = recovery.begin(), overlap = recovery.begin(manual: true)
    #expect(auto && !overlap)
    let returned = recovery.returnToDirectIfPending()
    let automaticAgain = recovery.begin(), manual = recovery.begin(manual: true)
    #expect(returned && !automaticAgain && manual)
    recovery.displayedFrame()
    let automaticAfterManual = recovery.begin()
    #expect(!automaticAfterManual)
}

@Test func transportDecisionAndFailureSurviveRepeatedNativeNotifications() throws {
    var diagnostic = PlaybackDiagnostic()
    diagnostic.originalTransportAttempts = 1
    diagnostic.originalTransportOutcome = "returned_to_direct"
    diagnostic.originalTransportFailure = PlaybackFailure.chain(OriginalTransportError.noCopyURL)
    diagnostic.event("transport_return_to_direct")
    for _ in 0..<51 { diagnostic.event("native_stall_notification") }
    #expect(diagnostic.events.count == 2)
    for i in 0..<40 { diagnostic.event("synthetic_\(i)") }
    #expect(diagnostic.events.count == 30)
    let exported = try #require(JSONSerialization.jsonObject(with: Data(diagnostic.export.utf8)) as? [String: Any])
    #expect(exported["originalTransportAttempts"] as? Int == 1)
    #expect(exported["originalTransportOutcome"] as? String == "returned_to_direct")
    #expect(diagnostic.originalTransportFailure == [PlaybackFailure(domain: "GlideTransportError", code: 2)])
}

@Test func originalTransportTrialReturnsToDirectOnceAndRequiresANewSessionToRetry() {
    var recovery = OriginalTransportRecovery()
    recovery.unproductiveRefill = true
    let began = recovery.begin()
    #expect(began)
    #expect(recovery.pending && !recovery.unproductiveRefill)
    let repeated = recovery.begin()
    #expect(!repeated)
    let returned = recovery.returnToDirectIfPending()
    #expect(returned)
    let returnedAgain = recovery.returnToDirectIfPending(), retried = recovery.begin()
    #expect(!returnedAgain && !retried)
    recovery = OriginalTransportRecovery()
    let newSessionBegan = recovery.begin()
    #expect(newSessionBegan)
    recovery.displayedFrame()
    let returnedAfterFrame = recovery.returnToDirectIfPending()
    #expect(!recovery.pending && !returnedAfterFrame)
}

@Test func originalTransportNegotiationForbidsVideoEncoding() {
    let body = JellyfinPlaybackPolicy.body(userID: "fixture-user", quality: .compatible)
    #expect(body["EnableDirectPlay"] as? Bool == false)
    #expect(body["EnableDirectStream"] as? Bool == true)
    #expect(body["EnableTranscoding"] as? Bool == false)
    #expect(body["AllowVideoStreamCopy"] as? Bool == true)
    #expect(body["MaxStreamingBitrate"] as? Int == 200_000_000)
}

@Test func originalNeverRequestsTranscoding() {
    let body = JellyfinPlaybackPolicy.body(userID: "user", quality: .original)
    #expect(body["EnableDirectPlay"] as? Bool == true)
    #expect(body["EnableTranscoding"] as? Bool == false)
    #expect(body["EnableDirectStream"] as? Bool == false)
}

@Test func hd1080ForcesEncodingAndBoundsResolutionAndBitrate() throws {
    let body = JellyfinPlaybackPolicy.body(userID: "user", quality: .hd1080)
    #expect(body["EnableDirectPlay"] as? Bool == false)
    #expect(body["EnableDirectStream"] as? Bool == false)
    #expect(body["EnableTranscoding"] as? Bool == true)
    #expect(body["AllowVideoStreamCopy"] as? Bool == false)
    #expect(body["MaxStreamingBitrate"] as? Int == 8_000_000)
    let profile = try #require(body["DeviceProfile"] as? [String: Any])
    let codecs = try #require(profile["CodecProfiles"] as? [[String: Any]])
    let conditions = try #require(codecs[0]["Conditions"] as? [[String: Any]])
    #expect(conditions.first { $0["Property"] as? String == "Height" }?["Value"] as? String == "1080")
    #expect(conditions.first { $0["Property"] as? String == "Width" }?["Value"] as? String == "1920")
    let url = URL(string: "https://nas/jellyfin/master.m3u8?api_key=token&maxHeight=2160&VideoBitrate=40000000&PlaySessionId=abc")!
    let resolved = JellyfinPlaybackPolicy.transcodeURL(url, quality: .hd1080)
    let query = try #require(URLComponents(url: resolved, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.filter { $0.name.lowercased() == "maxheight" }.count == 1)
    #expect(query.first { $0.name == "MaxHeight" }?.value == "1080")
    #expect(query.first { $0.name == "VideoBitrate" }?.value == "7808000")
    #expect(query.first { $0.name == "api_key" }?.value == "token")
    #expect(query.first { $0.name == "PlaySessionId" }?.value == "abc")
    #expect(JellyfinPlaybackPolicy.transcodeURL(url, quality: .automatic) == url)
}

@Test func automaticStartsWithOriginalAndFallsBackWithoutQualityPicker() {
    let body = JellyfinPlaybackPolicy.body(userID: "user", quality: .automatic)
    #expect(body["EnableDirectPlay"] as? Bool == true)
    #expect(body["MaxStreamingBitrate"] as? Int == 200_000_000)
    #expect(AutomaticPlaybackPolicy.quality(at: 0) == .automatic)
    #expect(AutomaticPlaybackPolicy.nextStep(after: 0, stalled: false, preservingVideo: true) == 1)
    #expect(AutomaticPlaybackPolicy.nextStep(after: 0, stalled: false, preservingVideo: true, videoFailed: true) == 2)
    #expect(AutomaticPlaybackPolicy.nextStep(after: 0, stalled: false, preservingVideo: true, canDirectStream: false) == 2)
    #expect(AutomaticPlaybackPolicy.nextStep(after: 0, stalled: true, preservingVideo: true) == 2)
    #expect(AutomaticPlaybackPolicy.nextStep(after: 1, stalled: true, preservingVideo: true) == 2)
    #expect(AutomaticPlaybackPolicy.nextStep(after: 2, stalled: true, preservingVideo: false) == 3)
    #expect(AutomaticPlaybackPolicy.nextStep(after: 3, stalled: true, preservingVideo: false) == nil)
}

@Test func nativeNegotiationPreservesHEVCButConstrainsAVCToSDR() throws {
    for quality in [PlaybackQuality.automatic, .compatible, .hd1080, .hd720] {
        let body = JellyfinPlaybackPolicy.body(userID: "user", quality: quality)
        let profile = try #require(body["DeviceProfile"] as? [String: Any])
        let codecs = try #require(profile["CodecProfiles"] as? [[String: Any]])
        let avc = try #require(codecs.first { $0["Codec"] as? String == "h264" })
        let conditions = try #require(avc["Conditions"] as? [[String: Any]])
        #expect(conditions.first { $0["Property"] as? String == "VideoRangeType" }?["Value"] as? String == "SDR")
        #expect(conditions.first { $0["Property"] as? String == "VideoBitDepth" }?["Value"] as? String == "8")
        #expect(!codecs.contains { $0["Codec"] as? String == "hevc" }, "HDR-compatible native HEVC is not forced to SDR")
        let transcode = try #require(profile["TranscodingProfiles"] as? [[String: Any]])
        if quality == .automatic || quality == .compatible {
            #expect(transcode[0]["Container"] as? String == "mp4")
            #expect(transcode[0]["VideoCodec"] as? String == "h264,hevc")
        } else {
            #expect(transcode[0]["VideoCodec"] as? String == "h264")
        }
    }
    let encoded = JellyfinPlaybackPolicy.transcodeURL(URL(string: "https://nas.test/master.m3u8?VideoCodec=hevc&H264-RangeType=HDR10&api_key=token")!, quality: .hd1080)
    #expect(NativeColorPolicy.outputOptions(encoded).codec == "h264")
    #expect(NativeColorPolicy.outputOptions(encoded).range == "SDR")
}

@Test func hd720ForcesLowerBitrateAndResolution() throws {
    let body = JellyfinPlaybackPolicy.body(userID: "user", quality: .hd720)
    #expect(body["EnableDirectPlay"] as? Bool == false)
    #expect(body["AllowVideoStreamCopy"] as? Bool == false)
    #expect(body["MaxStreamingBitrate"] as? Int == 3_000_000)
    let profile = try #require(body["DeviceProfile"] as? [String: Any])
    let codecs = try #require(profile["CodecProfiles"] as? [[String: Any]])
    let conditions = try #require(codecs[0]["Conditions"] as? [[String: Any]])
    #expect(conditions.first { $0["Property"] as? String == "Height" }?["Value"] as? String == "720")
    let url = URL(string: "https://nas/jellyfin/master.m3u8?api_key=token&MaxHeight=2160")!
    let query = try #require(URLComponents(url: JellyfinPlaybackPolicy.transcodeURL(url, quality: .hd720), resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.first { $0.name == "MaxHeight" }?.value == "720")
    #expect(query.first { $0.name == "VideoBitrate" }?.value == "2808000")
    #expect(query.first { $0.name == "api_key" }?.value == "token")
}

private func expectStallDecision(_ tracker: inout PlaybackStallTracker, at date: Date, stalled: Bool, bufferedEnd: Double?, expected: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    let actual = tracker.shouldRecover(at: date, stalled: stalled, bufferedEnd: bufferedEnd)
    #expect(actual == expected, sourceLocation: sourceLocation)
}

@Test func recoveredBufferingKeepsTheWorkingStream() {
    var tracker = PlaybackStallTracker()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    for seconds in [0.0, 2.6, 8, 25, 44] {
        expectStallDecision(&tracker, at: start.addingTimeInterval(seconds), stalled: true, bufferedEnd: 10, expected: false)
    }
    expectStallDecision(&tracker, at: start.addingTimeInterval(45), stalled: false, bufferedEnd: 20, expected: false)
    // Two stalls of eight seconds no longer count as accumulated failure.
    for seconds in [50.0, 58] {
        expectStallDecision(&tracker, at: start.addingTimeInterval(seconds), stalled: true, bufferedEnd: 20, expected: false)
    }
    expectStallDecision(&tracker, at: start.addingTimeInterval(59), stalled: false, bufferedEnd: 30, expected: false)
}

@Test func ongoingStallNeedsBothTimeAndLackOfUsableBufferProgress() {
    var tracker = PlaybackStallTracker()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    expectStallDecision(&tracker, at: start, stalled: true, bufferedEnd: 10, expected: false)
    expectStallDecision(&tracker, at: start.addingTimeInterval(40), stalled: true, bufferedEnd: 12, expected: false)
    expectStallDecision(&tracker, at: start.addingTimeInterval(45), stalled: true, bufferedEnd: 12, expected: false)
    expectStallDecision(&tracker, at: start.addingTimeInterval(59.9), stalled: true, bufferedEnd: 12, expected: false)
    expectStallDecision(&tracker, at: start.addingTimeInterval(60), stalled: true, bufferedEnd: 12, expected: true)
    var stopped = PlaybackStallTracker()
    expectStallDecision(&stopped, at: start, stalled: true, bufferedEnd: nil, expected: false)
    expectStallDecision(&stopped, at: start.addingTimeInterval(44.9), stalled: true, bufferedEnd: nil, expected: false)
    expectStallDecision(&stopped, at: start.addingTimeInterval(45), stalled: true, bufferedEnd: .nan, expected: true)
}

@Test func aGrowingBufferGetsExtraTimeButCannotWaitForever() {
    var tracker = PlaybackStallTracker()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    for seconds in stride(from: 0.0, through: 80, by: 10) {
        expectStallDecision(&tracker, at: start.addingTimeInterval(seconds), stalled: true, bufferedEnd: 10 + seconds, expected: false)
    }
    expectStallDecision(&tracker, at: start.addingTimeInterval(90), stalled: true, bufferedEnd: 100, expected: true)
}

@Test func intentionalPlaybackChangesAndBackwardsClockResetStallObservation() {
    var tracker = PlaybackStallTracker()
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    expectStallDecision(&tracker, at: start, stalled: true, bufferedEnd: 10, expected: false)
    expectStallDecision(&tracker, at: start.addingTimeInterval(40), stalled: false, bufferedEnd: 10, expected: false)
    expectStallDecision(&tracker, at: start.addingTimeInterval(80), stalled: true, bufferedEnd: 10, expected: false)
    expectStallDecision(&tracker, at: start.addingTimeInterval(100), stalled: true, bufferedEnd: 10, expected: false)
    expectStallDecision(&tracker, at: start.addingTimeInterval(70), stalled: true, bufferedEnd: 10, expected: false)
    expectStallDecision(&tracker, at: start.addingTimeInterval(114), stalled: true, bufferedEnd: 10, expected: false)
    expectStallDecision(&tracker, at: start.addingTimeInterval(115), stalled: true, bufferedEnd: 10, expected: true)
}

@Test func learnedConversionRouteIsScopedAndExpires() throws {
    let suite = "GlidePlaybackRouteTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let memory = PlaybackRouteMemory(defaults: defaults)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(!memory.prefersVideoConversion(for: "server-a:movie", at: start))
    memory.rememberVideoConversion(for: "server-a:movie", at: start)
    #expect(memory.prefersVideoConversion(for: "server-a:movie", at: start.addingTimeInterval(30)))
    #expect(!memory.prefersVideoConversion(for: "server-b:movie", at: start.addingTimeInterval(30)))
    #expect(!memory.prefersVideoConversion(for: "server-a:movie", at: start.addingTimeInterval(PlaybackRouteMemory.lifetime + 1)))
}
