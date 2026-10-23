import Foundation

enum CatalogSubtitlePolicy {
    static let pgsCodecs: Set<String> = ["pgssub", "hdmv_pgs_subtitle", "pgs"]
    static let textCodecs: Set<String> = ["srt", "subrip", "vtt", "webvtt", "ass", "ssa", "mov_text", "ttml", "text"]
    static func selectedIndex(explicit: Int?, url: URL?, serverDefault: Int?, streams: [CatalogItem.Stream], forcedOnly: Bool) -> Int? {
        let query = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        let urlIndex = query.last(where: { $0.name.lowercased() == "subtitlestreamindex" })?.value.flatMap(Int.init)
        // External delivery need not put the subtitle index in the video URL.
        // The negotiated source default includes the server user's preferences;
        // a file's IsDefault flag alone does not authorize enabling subtitles.
        guard let index = explicit ?? urlIndex ?? serverDefault, index >= 0,
              let stream = streams.first(where: { $0.Type == "Subtitle" && $0.Index == index }),
              explicit != nil || !forcedOnly || stream.IsForced == true else { return nil }
        return index
    }
    static func preferred(_ streams: [CatalogItem.Stream], language: String, forcedOnly: Bool) -> Int? {
        let text = streams.filter { textCodecs.contains($0.Codec?.lowercased() ?? "") }
        return LanguagePreference.stream(text, language: language, forcedOnly: forcedOnly)
            ?? LanguagePreference.stream(streams, language: language, forcedOnly: forcedOnly)
    }
    static func alternativeForDefaultBurn(url: URL, streams: [CatalogItem.Stream], forcedOnly: Bool) -> Int? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.last(where: { $0.name.lowercased() == "subtitlemethod" })?.value?.lowercased() == "encode",
              let raw = query.last(where: { $0.name.lowercased() == "subtitlestreamindex" })?.value,
              let index = Int(raw), index >= 0,
              let selected = streams.first(where: { $0.Type == "Subtitle" && $0.Index == index }),
              ["pgssub", "hdmv_pgs_subtitle", "dvdsub", "dvbsub"].contains(selected.Codec?.lowercased() ?? "") else { return nil }
        let language = LanguagePreference.normalized(selected.Language)
        guard !language.isEmpty else { return nil }
        return streams.first {
            $0.Type == "Subtitle" && textCodecs.contains($0.Codec?.lowercased() ?? "")
                && LanguagePreference.normalized($0.Language) == language
                && ($0.IsForced == true) == (selected.IsForced == true) && (!forcedOnly || $0.IsForced == true)
        }?.Index
    }
}

/// Protocol differences that must not be inferred from a server's display name.
enum MediaServerAPI {
    static func subtitleOffURL(_ url: URL, kind: SourceKind, tracks: TrackSelection) -> URL {
        // Drop is a Jellyfin method; Emby rejects that enum value with HTTP 400.
        guard kind == .jellyfin, tracks.subtitleIndex == -1, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let keys = Set(["subtitlestreamindex", "subtitlemethod"])
        parts.queryItems = (parts.queryItems ?? []).filter { !keys.contains($0.name.lowercased()) }
            + [URLQueryItem(name: "SubtitleStreamIndex", value: "-1"), URLQueryItem(name: "SubtitleMethod", value: "Drop")]
        return parts.url ?? url
    }
    static func validateSession(token: String, userID: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !userID.isEmpty, userID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw MediaError.message("服务器未返回有效的登录凭据，请检查地址与服务器版本。")
        }
    }
    static func authorization(kind: SourceKind, deviceID: String, version: String, token: String? = nil, userID: String? = nil) -> String {
        func quoted(_ value: String) -> String {
            value.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
                .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let scheme = kind == .emby ? "Emby" : "MediaBrowser"
        var result = scheme + " Client=\"Glide\", Device=\"iOS\", DeviceId=\"\(quoted(deviceID))\", Version=\"\(quoted(version))\""
        if kind == .emby, let userID { result += ", UserId=\"\(quoted(userID))\"" }
        if let token { result += ", Token=\"\(quoted(token))\"" }
        return result
    }

    static func viewsPath(kind: SourceKind, userID: String) -> String {
        kind == .emby ? "Users/\(userID)/Views" : "UserViews"
    }

    static func directURL(server: MediaServer, itemID: String, sourceID: String, sessionID: String?, deviceID: String, token: String) -> URL {
        var query = ["static": "true", "MediaSourceId": sourceID, "api_key": token]
        if server.kind == .emby {
            query["PlaySessionId"] = sessionID ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
            query["DeviceId"] = deviceID
        }
        return ServerURL.endpoint(server.address, "Videos/\(itemID)/stream", query: query)
    }

    static func playbackBody(kind: SourceKind, userID: String, quality: PlaybackQuality, directVideoCodecs: String) -> [String: Any] {
        var body = JellyfinPlaybackPolicy.body(userID: userID, quality: quality, directVideoCodecs: directVideoCodecs)
        if kind == .jellyfin, var profile = body["DeviceProfile"] as? [String: Any] {
            // Read bounded text tracks separately; a subtitle rendition must
            // not hold video preparation. Bitmap tracks still need encoding.
            profile["SubtitleProfiles"] = [["Format": "srt", "Method": "External"], ["Format": "vtt", "Method": "External"],
                ["Format": "pgssub", "Method": "Encode"], ["Format": "dvdsub", "Method": "Encode"], ["Format": "dvbsub", "Method": "Encode"]]
            body["DeviceProfile"] = profile
        }
        if kind == .emby {
            // Emby DirectStream is progressive HTTP. Request its HLS route for
            // fallback; compatible mode still enforces VideoCodec=copy on the URL.
            body["EnableDirectStream"] = false
            body["EnableTranscoding"] = quality != .original
        }
        if kind == .emby, var profile = body["DeviceProfile"] as? [String: Any],
           let codecs = profile["CodecProfiles"] as? [[String: Any]] {
            // Emby's profile contract has no Jellyfin VideoRangeType condition.
            profile["CodecProfiles"] = codecs.map { codec in
                var codec = codec
                codec["Conditions"] = (codec["Conditions"] as? [[String: Any]])?.filter { $0["Property"] as? String != "VideoRangeType" }
                return codec
            }
            body["DeviceProfile"] = profile
        }
        return body
    }

    static func streamURL(path: String, server: MediaServer) -> URL? {
        guard var parts = URLComponents(string: path) else { return nil }
        if server.kind == .emby, parts.scheme == nil, parts.host == nil, parts.path.hasPrefix("/") {
            let prefix = server.address.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !prefix.isEmpty, parts.path != "/" + prefix, !parts.path.hasPrefix("/" + prefix + "/") {
                parts.path = "/" + prefix + parts.path
            }
        }
        guard let relative = parts.string, let url = URL(string: relative, relativeTo: server.address.appendingPathComponent(""))?.absoluteURL,
              url.user == nil, url.password == nil, ServerURL.sameOrigin(server.address, url) else { return nil }
        return url
    }

    static func reportMethod(kind: SourceKind, negotiatedMethod: String) -> String {
        // Emby names a static HTTP file DirectStream; DirectPlay bypasses its server.
        kind == .emby && negotiatedMethod == "DirectPlay" ? "DirectStream" : negotiatedMethod
    }
}
