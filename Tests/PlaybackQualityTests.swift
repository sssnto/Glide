import Foundation
import Testing
@testable import GlideCore

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

@Test func repeatedBufferingTriggersOneAutomaticDowngrade() {
    var tracker = PlaybackStallTracker()
    let start = Date()
    #expect(tracker.record(at: start, duration: 2.6) == false)
    #expect(tracker.record(at: start.addingTimeInterval(10), duration: 2.6) == true)
    var separate = PlaybackStallTracker()
    #expect(separate.record(at: start, duration: 3) == false)
    #expect(separate.record(at: start.addingTimeInterval(91), duration: 3) == false)
    var longStall = PlaybackStallTracker()
    #expect(longStall.record(at: start, duration: 8) == true)
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
