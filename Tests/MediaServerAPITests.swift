import Foundation
import Testing
@testable import GlideCore

struct MediaServerAPITests {
    private var subtitleStreams: [CatalogItem.Stream] {
        [.init(Index: 3, Type: "Subtitle", Language: "zho", Codec: "PGSSUB", IsDefault: true, IsForced: false),
         .init(Index: 11, Type: "Subtitle", Language: "eng", Codec: "subrip", IsForced: false),
         .init(Index: 13, Type: "Subtitle", Language: "chi", Codec: "subrip", IsForced: false),
         .init(Index: 14, Type: "Subtitle", Language: "zho", Codec: "subrip", IsForced: true)]
    }
    @Test func externalSubtitleUsesNegotiatedDefaultWithoutVideoURLIndexOrLanguageTag() {
        let streams = [CatalogItem.Stream(Index: 4, Type: "Subtitle", Codec: "subrip", IsDefault: true)]
        for url in [nil, URL(string: "https://fixture.invalid/master.m3u8?VideoCodec=h264")] {
            #expect(CatalogSubtitlePolicy.selectedIndex(explicit: nil, url: url, serverDefault: 4, streams: streams, forcedOnly: false) == 4)
        }
    }
    @Test func negotiatedSubtitleOffDoesNotFallBackToFileDefault() {
        let streams = [CatalogItem.Stream(Index: 4, Type: "Subtitle", Codec: "subrip", IsDefault: true)]
        for serverDefault in [nil, -1] as [Int?] {
            #expect(CatalogSubtitlePolicy.selectedIndex(explicit: nil, url: nil, serverDefault: serverDefault, streams: streams, forcedOnly: false) == nil)
        }
        #expect(CatalogSubtitlePolicy.selectedIndex(explicit: -1, url: URL(string: "https://fixture.invalid/master.m3u8?SubtitleStreamIndex=4"), serverDefault: 4, streams: streams, forcedOnly: false) == nil)
    }
    @Test func explicitSubtitleAndURLSelectionPrecedeNegotiatedDefault() {
        let url = URL(string: "https://fixture.invalid/master.m3u8?subtitleStreamIndex=13")!
        #expect(CatalogSubtitlePolicy.selectedIndex(explicit: 11, url: url, serverDefault: 3, streams: subtitleStreams, forcedOnly: false) == 11)
        #expect(CatalogSubtitlePolicy.selectedIndex(explicit: nil, url: url, serverDefault: 3, streams: subtitleStreams, forcedOnly: false) == 13)
        #expect(CatalogSubtitlePolicy.selectedIndex(explicit: nil, url: URL(string: "https://fixture.invalid/master.m3u8?SubtitleStreamIndex=-1"), serverDefault: 3, streams: subtitleStreams, forcedOnly: false) == nil)
    }
    @Test func defaultSubtitleIndexMustBelongToSelectedSourceSubtitleInventory() {
        let streams = subtitleStreams + [.init(Index: 2, Type: "Audio", Codec: "aac")]
        for index in [2, 999] {
            #expect(CatalogSubtitlePolicy.selectedIndex(explicit: nil, url: nil, serverDefault: index, streams: streams, forcedOnly: false) == nil)
            #expect(CatalogSubtitlePolicy.selectedIndex(explicit: index, url: nil, serverDefault: 13, streams: streams, forcedOnly: false) == nil)
        }
    }
    @Test func automaticDefaultHonorsForcedOnlyWhileExplicitChoiceRemainsSelectable() {
        #expect(CatalogSubtitlePolicy.selectedIndex(explicit: nil, url: nil, serverDefault: 13, streams: subtitleStreams, forcedOnly: true) == nil)
        #expect(CatalogSubtitlePolicy.selectedIndex(explicit: nil, url: nil, serverDefault: 14, streams: subtitleStreams, forcedOnly: true) == 14)
        #expect(CatalogSubtitlePolicy.selectedIndex(explicit: 13, url: nil, serverDefault: 14, streams: subtitleStreams, forcedOnly: true) == 13)
    }
    @Test func preferredTextSubtitleKeepsRequestedLanguageAndForcedFilter() {
        #expect(CatalogSubtitlePolicy.preferred(subtitleStreams, language: "zh-Hans", forcedOnly: false) == 13)
        #expect(CatalogSubtitlePolicy.preferred(subtitleStreams, language: "zh", forcedOnly: true) == 14)
        #expect(CatalogSubtitlePolicy.preferred(subtitleStreams, language: "en", forcedOnly: false) == 11)
        #expect(CatalogSubtitlePolicy.preferred(subtitleStreams, language: "ja", forcedOnly: false) == nil)
        #expect(CatalogSubtitlePolicy.preferred(subtitleStreams, language: "", forcedOnly: false) == nil)
        #expect(CatalogSubtitlePolicy.preferred(Array(subtitleStreams.prefix(1)), language: "zh", forcedOnly: false) == 3)
    }
    @Test func implicitBitmapAlternativeKeepsLanguageAndForcedStatus() {
        let encoded = URL(string: "https://fixture.invalid/master.m3u8?SubtitleMethod=Encode&SubtitleStreamIndex=3")!
        #expect(CatalogSubtitlePolicy.alternativeForDefaultBurn(url: encoded, streams: subtitleStreams, forcedOnly: false) == 13)
        #expect(CatalogSubtitlePolicy.alternativeForDefaultBurn(url: encoded, streams: subtitleStreams, forcedOnly: true) == nil)
        #expect(CatalogSubtitlePolicy.alternativeForDefaultBurn(url: encoded, streams: Array(subtitleStreams.prefix(2)), forcedOnly: false) == nil)
        for query in ["SubtitleMethod=Hls&SubtitleStreamIndex=3", "SubtitleMethod=Encode&SubtitleStreamIndex=-1", "SubtitleMethod=Encode&SubtitleStreamIndex=13", "SubtitleMethod=Encode"] {
            #expect(CatalogSubtitlePolicy.alternativeForDefaultBurn(url: URL(string: "https://fixture.invalid/master.m3u8?" + query)!, streams: subtitleStreams, forcedOnly: false) == nil)
        }
        var unknown = subtitleStreams; unknown[0].Language = nil
        #expect(CatalogSubtitlePolicy.alternativeForDefaultBurn(url: encoded, streams: unknown, forcedOnly: false) == nil)
    }
    @Test func explicitSubtitleOffRemovesBurnParametersWithoutChangingSession() throws {
        let url = URL(string: "https://fixture.invalid/prefix/master.m3u8?SubtitleMethod=Encode&subtitleStreamIndex=3&SubtitleMethod=Encode&MediaSourceId=source&PlaySessionId=session&VideoCodec=hevc&api_key=fixture-token")!
        let fixed = MediaServerAPI.subtitleOffURL(url, kind: .jellyfin, tracks: TrackSelection(mediaSourceID: "source", subtitleIndex: -1))
        let query = try #require(URLComponents(url: fixed, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.filter { $0.name.lowercased() == "subtitlemethod" }.map(\.value) == ["Drop"])
        #expect(query.filter { $0.name.lowercased() == "subtitlestreamindex" }.map(\.value) == ["-1"])
        #expect(query.contains(URLQueryItem(name: "MediaSourceId", value: "source")))
        #expect(query.contains(URLQueryItem(name: "PlaySessionId", value: "session")))
        #expect(query.contains(URLQueryItem(name: "api_key", value: "fixture-token")))
        #expect(NativeColorPolicy.outputOptions(try OriginalTransportPolicy.videoCopyURL(fixed, sourceCodec: "hevc")).codec == "copy")
        #expect(MediaServerAPI.subtitleOffURL(url, kind: .jellyfin, tracks: TrackSelection()) == url)
        #expect(MediaServerAPI.subtitleOffURL(url, kind: .jellyfin, tracks: TrackSelection(subtitleIndex: 3)) == url)
    }
    @Test func embySubtitleOffPreservesNegotiatedMethod() {
        let url = URL(string: "https://fixture.invalid/emby/master.m3u8?SubtitleStreamIndex=-1&MediaSourceId=source&AudioStreamIndex=2&VideoCodec=h264&api_key=fixture-token")!
        #expect(MediaServerAPI.subtitleOffURL(url, kind: .emby, tracks: TrackSelection(mediaSourceID: "source", audioIndex: 2, subtitleIndex: -1)) == url)
    }
    @Test func explicitSubtitleOffAlsoRequiresSourceBinding() throws {
        #expect(!TrackSelection().needsSourceBinding)
        #expect(TrackSelection(audioIndex: 2).needsSourceBinding)
        #expect(TrackSelection(subtitleIndex: 13).needsSourceBinding)
        var selection = TrackSelection(subtitleIndex: -1)
        #expect(selection.needsSourceBinding && !selection.requiresServerSelection)
        selection.mediaSourceID = "selected-version"
        #expect(!selection.needsSourceBinding)
        var body = MediaServerAPI.playbackBody(kind: .jellyfin, userID: "user", quality: .automatic, directVideoCodecs: "h264,hevc")
        selection.apply(to: &body)
        let decoded = try #require(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: body)) as? [String: Any])
        #expect(decoded["SubtitleStreamIndex"] as? Int == -1)
        #expect(decoded["MediaSourceId"] as? String == "selected-version")
        #expect(decoded["EnableDirectPlay"] as? Bool == true)
    }
    @Test func jellyfinTextSubtitlesUseClientDeliveryWithoutRemovingBitmapFallback() throws {
        for quality in [PlaybackQuality.automatic, .compatible, .hd1080] {
            let body = MediaServerAPI.playbackBody(kind: .jellyfin, userID: "user", quality: quality, directVideoCodecs: "h264,hevc")
            let profile = try #require(body["DeviceProfile"] as? [String: Any])
            let subtitles = try #require(profile["SubtitleProfiles"] as? [[String: String]])
            #expect(subtitles.contains(["Format": "srt", "Method": "External"]))
            #expect(subtitles.contains(["Format": "vtt", "Method": "External"]))
            #expect(subtitles.contains(["Format": "pgssub", "Method": "Encode"]))
            #expect(!subtitles.contains { $0["Method"] == "Hls" })
            #expect(body["EnableTranscoding"] as? Bool == true)
        }
        let url = URL(string: "https://fixture.invalid/master.m3u8?VideoCodec=hevc,h264&SubtitleMethod=Hls&SubtitleStreamIndex=13&MediaSourceId=source&PlaySessionId=session")!
        let copy = try OriginalTransportPolicy.videoCopyURL(url, sourceCodec: "hevc")
        #expect(NativeColorPolicy.outputOptions(copy).codec == "copy")
        #expect(URLComponents(url: copy, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "SubtitleMethod", value: "Hls")) == true)
        #expect(throws: OriginalTransportError.self) { try OriginalTransportPolicy.videoCopyURL(URL(string: url.absoluteString.replacingOccurrences(of: "SubtitleMethod=Hls", with: "SubtitleMethod=Encode"))!, sourceCodec: "hevc") }
    }
    @Test func copiedEmbySeekRecoversOnceWithoutDroppingTrackChoices() {
        var recovery = CatalogSeekRecovery()
        let decision1 = recovery.returnToOriginal(kind: .emby, container: "mp4", delivery: .remux, originalWasPlayable: true, hasServerTracks: false, target: 5, actual: 4.5, tolerance: 0.5)
        #expect(!decision1)
        let decision2 = recovery.returnToOriginal(kind: .jellyfin, container: "mp4", delivery: .remux, originalWasPlayable: true, hasServerTracks: false, target: 24, actual: 28.4, tolerance: 0.5)
        #expect(!decision2)
        let decision3 = recovery.returnToOriginal(kind: .emby, container: "mkv", delivery: .remux, originalWasPlayable: true, hasServerTracks: false, target: 24, actual: 28.4, tolerance: 0.5)
        #expect(!decision3)
        let decision4 = recovery.returnToOriginal(kind: .emby, container: "mp4", delivery: .videoConversion, originalWasPlayable: true, hasServerTracks: false, target: 24, actual: 28.4, tolerance: 0.5)
        #expect(!decision4)
        let decision5 = recovery.returnToOriginal(kind: .emby, container: "mp4", delivery: .audioConversion, originalWasPlayable: true, hasServerTracks: true, target: 24, actual: 28.4, tolerance: 0.5)
        #expect(!decision5)
        let decision6 = recovery.returnToOriginal(kind: .emby, container: "mp4", delivery: .remux, originalWasPlayable: true, hasServerTracks: false, target: .nan, actual: 28.4, tolerance: 0.5)
        #expect(!decision6)
        let unproven = recovery.returnToOriginal(kind: .emby, container: "mp4", delivery: .remux, originalWasPlayable: false, hasServerTracks: false, target: 24, actual: 28.4, tolerance: 0.5)
        #expect(!unproven)
        let decision7 = recovery.returnToOriginal(kind: .emby, container: "mp4", delivery: .audioConversion, originalWasPlayable: true, hasServerTracks: false, target: 24, actual: 28.4, tolerance: 0.5)
        #expect(decision7)
        let decision8 = recovery.returnToOriginal(kind: .emby, container: "mp4", delivery: .remux, originalWasPlayable: true, hasServerTracks: false, target: 24, actual: 28.4, tolerance: 0.5)
        #expect(!decision8)
    }
    private var server: MediaServer {
        MediaServer(name: "Emby fixture", kind: .emby, address: URL(string: "https://nas.example/prefix/emby")!, username: "fixture", userID: "user")
    }
    @Test func embyIsCatalogAndExistingSourcesStillDecode() throws {
        #expect(SourceKind.emby.isCatalogSource && !SourceKind.emby.isFileSource)
        #expect(SourceKind.emby.capabilities == SourceKind.jellyfin.capabilities)
        for kind in [SourceKind.jellyfin, .smb, .webDAV, .local, .emby] {
            var source = server; source.kind = kind
            #expect(try JSONDecoder().decode(MediaServer.self, from: JSONEncoder().encode(source)) == source)
        }
        let old = Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"Old","kind":"jellyfin","address":"https://nas.example","username":"a"}"#.utf8)
        #expect(try JSONDecoder().decode(MediaServer.self, from: old).kind == .jellyfin)
    }
    @Test func authUsesServerSchemeAndEscapesQuotedValues() {
        let emby = MediaServerAPI.authorization(kind: .emby, deviceID: "device\r\n", version: "1.7.0", token: "a\"b\\c", userID: "user")
        #expect(emby.hasPrefix("Emby ") && emby.contains("UserId=\"user\""))
        #expect(emby.contains("Token=\"a\\\"b\\\\c\"") && !emby.contains("\n") && !emby.contains("\r"))
        let jellyfin = MediaServerAPI.authorization(kind: .jellyfin, deviceID: "d", version: "1", token: "t", userID: "u")
        #expect(jellyfin.hasPrefix("MediaBrowser ") && !jellyfin.contains("UserId="))
        #expect(throws: (any Error).self) { try MediaServerAPI.validateSession(token: "", userID: "user") }
        #expect(throws: (any Error).self) { try MediaServerAPI.validateSession(token: "token", userID: "../other") }
        #expect(throws: (any Error).self) { try MediaServerAPI.validateSession(token: "token\nInjected", userID: "user") }
    }
    @Test func embyRoutesPreservePrefixAndPlaybackSession() throws {
        #expect(MediaServerAPI.viewsPath(kind: .emby, userID: "user") == "Users/user/Views")
        let url = MediaServerAPI.directURL(server: server, itemID: "item", sourceID: "source", sessionID: "session", deviceID: "device", token: "a+b&c#d")
        let query = Dictionary(uniqueKeysWithValues: try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        #expect(url.path == "/prefix/emby/Videos/item/stream")
        #expect(query["PlaySessionId"] == "session" && query["DeviceId"] == "device")
        #expect(query["MediaSourceId"] == "source" && query["static"] == "true" && query["api_key"] == "a+b&c#d")
    }
    @Test func jellyfinRoutesKeepLegacyContract() {
        var source = server; source.kind = .jellyfin
        #expect(MediaServerAPI.viewsPath(kind: source.kind, userID: "user") == "UserViews")
        let url = MediaServerAPI.directURL(server: source, itemID: "item", sourceID: "source", sessionID: "session", deviceID: "device", token: "token")
        #expect(!url.absoluteString.contains("PlaySessionId") && !url.absoluteString.contains("DeviceId"))
    }
    @Test func embyProfileRetainsCodecLimitsAndCopyRules() throws {
        func conditions(_ kind: SourceKind, _ quality: PlaybackQuality) throws -> [[String: Any]] {
            let body = MediaServerAPI.playbackBody(kind: kind, userID: "user", quality: quality, directVideoCodecs: "h264,hevc")
            let profile = try #require(body["DeviceProfile"] as? [String: Any])
            let codecs = try #require(profile["CodecProfiles"] as? [[String: Any]])
            return try #require(codecs.first?["Conditions"] as? [[String: Any]])
        }
        #expect(try !conditions(.emby, .automatic).contains { $0["Property"] as? String == "VideoRangeType" })
        #expect(try conditions(.jellyfin, .automatic).contains { $0["Property"] as? String == "VideoRangeType" })
        #expect(try conditions(.emby, .hd720).contains { $0["Property"] as? String == "Width" && $0["Value"] as? String == "1280" })
        let copy = MediaServerAPI.playbackBody(kind: .emby, userID: "user", quality: .compatible, directVideoCodecs: "h264")
        #expect(copy["EnableTranscoding"] as? Bool == true && copy["EnableDirectStream"] as? Bool == false && copy["AllowVideoStreamCopy"] as? Bool == true)
        let legacyCopy = MediaServerAPI.playbackBody(kind: .jellyfin, userID: "user", quality: .compatible, directVideoCodecs: "h264")
        #expect(legacyCopy["EnableTranscoding"] as? Bool == true && legacyCopy["EnableDirectStream"] as? Bool == true)
        let hd = MediaServerAPI.playbackBody(kind: .emby, userID: "user", quality: .hd720, directVideoCodecs: "h264")
        #expect(hd["AllowVideoStreamCopy"] as? Bool == false)
        #expect(PlaybackDelivery.negotiated(url: URL(string: "https://nas.example/master.m3u8?VideoCodec=copy&SubtitleMethod=Encode")!, quality: .automatic) == .videoConversion)
    }
    @Test func subtitleAndSkipIdentityDoNotCrossServerKindsOrAccounts() throws {
        let video = Video(id: "video", title: "Fixture", subtitle: "", remoteID: "item")
        let original = try SubtitleIdentity(video: video, server: server)
        var other = server; other.kind = .jellyfin
        #expect(try SubtitleIdentity(video: video, server: other) != original)
        other = server; other.username = "other"
        #expect(try SubtitleIdentity(video: video, server: other) != original)
        other = server; other.address = URL(string: "https://nas.example/other")!
        #expect(try SubtitleIdentity(video: video, server: other) != original)
    }
    @Test func episodeMetadataAndResumeDecodeFromEmbyContract() throws {
        let raw = Data(#"{"Id":"episode","Name":"原创第二集","Type":"Episode","SeriesId":"show","SeriesName":"原创剧集","IndexNumber":2,"ParentIndexNumber":1,"RunTimeTicks":6000000000,"UserData":{"PlaybackPositionTicks":1200000000,"Played":false}}"#.utf8)
        let item = try JSONDecoder().decode(CatalogItem.self, from: raw)
        let source = server
        let video = item.video(server: source)
        #expect(video.sourceID == source.id && video.remoteID == "episode" && video.duration == 600 && video.resume == 120)
        #expect(video.mediaType == "Episode" && video.seriesID == "show" && video.episodeNumber == 2 && video.seasonNumber == 1)
        #expect(video.isWatched == false)
    }
    @Test func embyStaticHTTPIsReportedAsDirectStream() {
        #expect(MediaServerAPI.reportMethod(kind: .emby, negotiatedMethod: "DirectPlay") == "DirectStream")
        #expect(MediaServerAPI.reportMethod(kind: .jellyfin, negotiatedMethod: "DirectPlay") == "DirectPlay")
        #expect(MediaServerAPI.reportMethod(kind: .emby, negotiatedMethod: "Transcode") == "Transcode")
    }
    @Test func embyHLSKeepsAPIPathPrefixAndRejectsOtherOrigins() throws {
        let source = server
        let url = try #require(MediaServerAPI.streamURL(path: "/videos/14/master.m3u8?api_key=fixture", server: source))
        #expect(url.path == "/prefix/emby/videos/14/master.m3u8")
        #expect(MediaServerAPI.streamURL(path: "/prefix/emby/videos/14/master.m3u8", server: source)?.path == url.path)
        #expect(MediaServerAPI.streamURL(path: "https://other.example/videos/14/master.m3u8", server: source) == nil)
        #expect(MediaServerAPI.streamURL(path: "//other.example/videos/14/master.m3u8", server: source) == nil)
        #expect(MediaServerAPI.streamURL(path: "https://user:password@nas.example/videos/14/master.m3u8", server: source) == nil)
    }
}
