import Foundation
import VideoToolbox

/// Do not forward passwords/tokens to a different host or downgrade HTTPS on redirects.
final class OriginRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let next = request.url, ServerURL.sameOrigin(original, next) else { completionHandler(nil); return }
        var authorized = request
        authorized.setValue(task.originalRequest?.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
        completionHandler(authorized)
    }
}

final class MediaClient {
    static let shared = MediaClient()
#if DEBUG
    @MainActor static var qaNegotiationReport: [String: Any] = [:]
    @MainActor static var qaASSReports: [Int: [String: Any]] = [:]
    @MainActor static var qaASSCheckpoints: [Int: Double] = [:]
#endif
    private let redirects = OriginRedirectDelegate()
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    }()
    let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }()
    func authorization(_ token: String? = nil, server: MediaServer? = nil) -> String {
        MediaServerAPI.authorization(kind: server?.kind ?? .jellyfin, deviceID: deviceID,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.7.0",
            token: token, userID: server?.userID)
    }
    func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MediaError.message("没有收到有效的服务器响应。") }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw MediaError.message("账号、密码或访问权限不正确；登录失效时请在来源管理中重新登录。")
        case 300..<400: throw MediaError.message("服务器重定向到了其他地址。请直接填写最终服务器地址。")
        case 404: throw MediaError.message("找不到资源，请检查服务器地址和路径。")
        default: throw MediaError.message("服务器请求失败（HTTP \(response.statusCode)）。")
        }
    }
    private func subtitleData(_ url: URL, authorization: String, maximumBytes: Int = SubtitleDocument.maximumBytes) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MediaError.message("服务器字幕提取失败，请选择其他字幕后重试。")
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw MediaError.message("服务器字幕超过 \(maximumBytes / 1024 / 1024) MB。") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw MediaError.message("服务器字幕超过 \(maximumBytes / 1024 / 1024) MB。") }
            data.append(byte)
        }
        return data
    }
    func serverSubtitle(video: Video, server: MediaServer, sourceID: String, stream: CatalogItem.Stream) async throws -> [SubtitleCue] {
        guard server.kind == .jellyfin, let item = video.remoteID, let token = Credentials.read(server.id),
              stream.Type == "Subtitle", CatalogSubtitlePolicy.textCodecs.contains(stream.Codec?.lowercased() ?? "") else {
            throw MediaError.message("此字幕需要服务器处理。")
        }
        let endpoint = ServerURL.endpoint(server.address, "Videos/\(item)/\(sourceID)/Subtitles/\(stream.Index)/Stream.srt")
        let bytes = try await subtitleData(endpoint, authorization: authorization(token, server: server))
        let cues = try await SubtitleSource.document(bytes, assText: ["ass", "ssa"].contains(stream.Codec?.lowercased() ?? "")).cues
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--glide-ass-investigation") {
            let raw = String(data: bytes, encoding: .utf8) ?? ""
            let report: [String: Any] = ["sourceCodec": PlaybackDiagnostic.token(stream.Codec) ?? "unknown", "rawContainsOverrides": ASSPlainText.hasOverrides(raw),
                "cleanCueCount": cues.count, "cleanOverrideCueCount": cues.filter { ASSPlainText.hasOverrides($0.text) }.count,
                "cleanChineseCueCount": cues.filter { $0.text.unicodeScalars.contains { (0x4e00...0x9fff).contains($0.value) } }.count,
                "cleanMultilineCueCount": cues.filter { $0.text.contains("\n") }.count]
            let checkpoint = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
                .first(where: { ASSPlainText.hasOverrides($0) }).flatMap { SubtitleCue.parse($0).first?.start }
            await MainActor.run {
                Self.qaASSReports[stream.Index] = report
                if let checkpoint { Self.qaASSCheckpoints[stream.Index] = checkpoint }
            }
        }
#endif
        return cues
    }
    func serverASSSubtitle(video: Video, server: MediaServer, sourceID: String, stream: CatalogItem.Stream, attachments: [CatalogItem.Attachment]? = nil) async throws -> ASSSubtitle {
        guard server.kind == .jellyfin, let item = video.remoteID, let token = Credentials.read(server.id),
              stream.Type == "Subtitle", ["ass", "ssa"].contains(stream.Codec?.lowercased() ?? "") else { throw MediaError.message("无法读取原始 ASS 字幕。") }
        let auth = authorization(token, server: server)
        let endpoint = ServerURL.endpoint(server.address, "Videos/\(item)/\(sourceID)/Subtitles/\(stream.Index)/Stream.ass", query: ["CopyTimestamps": "true"])
        let data = try await subtitleData(endpoint, authorization: auth)
        let work = Task.detached(priority: .userInitiated) { try ASSDocument.parse(data) }
        let document = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        let available: [CatalogItem.Attachment]
        if let attachments { available = attachments }
        else { available = try await catalogDetail(server: server, id: item).MediaSources?.first(where: { $0.Id == sourceID })?.MediaAttachments ?? [] }
        var fonts = [Data](), total = 0, failedFonts = 0
        let fontAttachments = available.filter(\.isFont)
        for attachment in fontAttachments.prefix(32) {
            try Task.checkCancellation()
            do {
                let url = ServerURL.endpoint(server.address, "Videos/\(item)/\(sourceID)/Attachments/\(attachment.Index)")
                let remaining = ASSFontStore.maximumTotal - total
                guard remaining > 0 else { failedFonts += 1; break }
                let bytes = try await subtitleData(url, authorization: auth, maximumBytes: min(remaining, ASSFontStore.maximumBytes))
                guard total + bytes.count <= ASSFontStore.maximumTotal, ASSFontStore.valid(bytes) else { failedFonts += 1; continue }
                total += bytes.count; fonts.append(bytes)
            } catch is CancellationError { throw CancellationError() }
            catch { failedFonts += 1 }
        }
        let warning = failedFonts > 0 || fontAttachments.count > 32 ? "部分原字体附件未能读取，相关文字暂用替代字体。可在字幕控制中导入原字体。" : nil
        return ASSSubtitle(document: document, fonts: fonts, fontWarning: warning)
    }
    func serverBitmapSubtitle(video: Video, server: MediaServer, sourceID: String, stream: CatalogItem.Stream) async throws -> PGSSubtitle {
        guard server.kind == .jellyfin, let item = video.remoteID, let token = Credentials.read(server.id),
              stream.Type == "Subtitle", CatalogSubtitlePolicy.pgsCodecs.contains(stream.Codec?.lowercased() ?? "") else {
            throw MediaError.message("此图形字幕需要服务器处理。")
        }
        // The API format is pgssub; the returned binary is a SUP stream. It is
        // not a text conversion and must retain the original presentation times.
        let endpoint = ServerURL.endpoint(server.address, "Videos/\(item)/\(sourceID)/Subtitles/\(stream.Index)/Stream.pgssub", query: ["CopyTimestamps": "true"])
        let data = try await subtitleData(endpoint, authorization: authorization(token, server: server), maximumBytes: PGSSubtitle.maximumBytes)
        let work = Task.detached(priority: .userInitiated) { try PGSSubtitle.parse(data) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    func signIn(server: MediaServer, password: String) async throws -> (String, String) {
        struct User: Decodable { let Id: String }
        struct Result: Decodable { let AccessToken: String; let User: User }
        let data = try await request(ServerURL.endpoint(server.address, "Users/AuthenticateByName"), method: "POST", headers: ["Authorization": authorization(server: server), "Content-Type": "application/json"], body: JSONSerialization.data(withJSONObject: ["Username": server.username, "Pw": password]))
        let result = try JSONDecoder().decode(Result.self, from: data)
        try MediaServerAPI.validateSession(token: result.AccessToken, userID: result.User.Id)
        return (result.AccessToken, result.User.Id)
    }
    private struct Item: Codable {
            var Id: String; var Name: String; var ProductionYear: Int?; var RunTimeTicks: Int64?; var SeriesName: String?; var SeriesId: String?; var IndexNumber: Int?; var ParentIndexNumber: Int?; var DateCreated: String?
            var IsFolder: Bool?; var MediaType: String?; var `Type`: String?; var CollectionType: String?; var ImageTags: [String: String]?
            var UserData: Progress?
            struct Progress: Codable { var PlaybackPositionTicks: Int64?; var Played: Bool? }
        }
    private struct Result: Codable { var Items: [Item]; var TotalRecordCount: Int }
    func browse(server: MediaServer, parentID: String?, start: Int = 0, sort: FolderSort = .nameAscending) async throws -> LibraryPage {
        guard let token = Credentials.read(server.id), let user = server.userID else { throw MediaError.message("请重新登录 \(server.kind.title)。") }
        let url: URL
        if let parentID {
            url = ServerURL.endpoint(server.address, "Items", query: DirectoryQuery.items(userID: user, parentID: parentID, start: start, sort: sort))
        } else {
            // UserViews is the current endpoint (including Jellyfin 12); no global video query.
            url = ServerURL.endpoint(server.address, MediaServerAPI.viewsPath(kind: server.kind, userID: user), query: ["UserId": user, "IncludeExternalContent": "false"])
        }
        let data: Data
        do { data = try await request(url, headers: ["Authorization": authorization(token, server: server)]) }
        catch {
            // Older Jellyfin versions only expose the legacy user views route.
            if parentID == nil, server.kind == .jellyfin, case MediaError.message(let message) = error, message.hasPrefix("找不到资源") {
                data = try await request(ServerURL.endpoint(server.address, "Users/\(user)/Views"), headers: ["Authorization": authorization(token, server: server)])
            } else { throw error }
        }
        let result = try JSONDecoder().decode(Result.self, from: data)
        let folders = result.Items.filter { item in
            if parentID == nil { return item.CollectionType != "music" && item.CollectionType != "books" }
            return item.IsFolder == true || ["Folder", "CollectionFolder", "Series", "Season", "BoxSet"].contains(item.Type ?? "")
        }.map { MediaFolder(id: $0.Id, name: $0.Name, isLibrary: parentID == nil, collectionType: $0.CollectionType, primaryImageTag: $0.ImageTags?["Primary"], addedAt: MediaTimestamp.parse($0.DateCreated)) }
        let folderIDs = Set(folders.map(\.id))
        let videos = parentID == nil ? [] : result.Items.filter { item in
            !folderIDs.contains(item.Id) && (item.MediaType == "Video" || ["Movie", "Episode", "Video", "MusicVideo"].contains(item.Type ?? ""))
        }.map { video($0, server: server) }
        return LibraryPage(folders: folders, videos: videos, total: result.TotalRecordCount, nextIndex: start + result.Items.count)
    }
    private func video(_ item: Item, server: MediaServer) -> Video {
        Video(id: server.id.uuidString + item.Id, title: item.Name, subtitle: [item.SeriesName, item.ProductionYear.map(String.init), server.name].compactMap { $0 }.joined(separator: " · "), sourceID: server.id, remoteID: item.Id, artwork: ServerURL.endpoint(server.address, "Items/\(item.Id)/Images/Primary", query: ["maxWidth": "700", "quality": "85"]), duration: Double(item.RunTimeTicks ?? 0) / 10_000_000, resume: Double(item.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000, mediaType: item.Type, addedAt: MediaTimestamp.parse(item.DateCreated), seriesID: item.SeriesId, seriesTitle: item.SeriesName, seasonNumber: item.ParentIndexNumber, episodeNumber: item.IndexNumber, isWatched: item.UserData?.Played)
    }
    func playbackVideos(server: MediaServer, parentID: String, start: Int, search: String = "", options: BrowseOptions = BrowseOptions()) async throws -> VideoPage {
        guard let token = Credentials.read(server.id), let user = server.userID else { throw MediaError.message("请重新登录 \(server.kind.title)。") }
        let url = ServerURL.endpoint(server.address, "Items", query: DirectoryQuery.playback(userID: user, parentID: parentID, start: start, search: search, options: options))
        let data = try await request(url, headers: ["Authorization": authorization(token, server: server)])
        let result = try JSONDecoder().decode(Result.self, from: data)
        let videos = result.Items.filter { $0.IsFolder != true && ($0.MediaType == "Video" || ["Movie", "Episode", "Video", "MusicVideo"].contains($0.Type ?? "")) }.map { video($0, server: server) }
        return VideoPage(videos: videos, total: result.TotalRecordCount, nextIndex: start + result.Items.count)
    }
    func folderPreview(server: MediaServer, folderID: String) async throws -> (id: String, tag: String?)? {
        guard let user = server.userID else { throw MediaError.message("请重新登录 \(server.kind.title)。") }
        let page = try await cached(Result.self, server: server, path: "Items", query: DirectoryQuery.folderPreview(userID: user, parentID: folderID))
        guard let item = page.Items.first(where: { $0.ImageTags?["Primary"] != nil }) ?? page.Items.first else { return nil }
        return (item.Id, item.ImageTags?["Primary"])
    }
    func webDAV(server: MediaServer, directory: URL? = nil, password: String? = nil) async throws -> [DAVEntry] {
        let url = directory ?? server.address
        guard ServerURL.sameOrigin(server.address, url) else { throw MediaError.message("目录地址与服务器不匹配。") }
        let auth = basic(server: server, password: password)
        let body = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/><d:creationdate/><d:getlastmodified/></d:prop></d:propfind>".utf8)
        let data = try await request(url, method: "PROPFIND", headers: ["Authorization": auth, "Depth": "1", "Content-Type": "application/xml; charset=utf-8"], body: body)
        return try DAVParser(base: url).parse(data)
    }
    func basic(server: MediaServer, password: String? = nil) -> String {
        "Basic " + Data("\(server.username):\(password ?? Credentials.read(server.id) ?? "")".utf8).base64EncodedString()
    }
    func mediaSegments(server: MediaServer, itemID: String) async throws -> [SkipSegment] {
        guard server.kind == .jellyfin, let token = Credentials.read(server.id) else { return [] }
        let data = try await request(ServerURL.endpoint(server.address, "MediaSegments/\(itemID)"), headers: ["Authorization": authorization(token, server: server)])
        guard data.count <= 2_000_000 else { throw MediaError.message("服务器片段数据过大。") }
        return Array(try JSONDecoder().decode(JellyfinSegmentResponse.self, from: data).segments(itemID: itemID).prefix(200))
    }
    func playback(video: Video, server: MediaServer?, quality: PlaybackQuality = .automatic, tracks: TrackSelection = TrackSelection(), directOnly: Bool = false) async throws -> PlaybackResource {
        if video.streamLinkID != nil { return try await StreamLinkStore.playback(video) }
        guard let server else {
            guard let url = video.url else { throw MediaError.message("找不到播放地址。") }
            return PlaybackResource(url: url, delivery: url.isFileURL ? .local : .direct)
        }
        if server.kind == .local { return try LocalMediaStore.playback(video, server: server) }
        if server.kind == .smb { return try await SMBSourceProvider.playback(video: video, server: server) }
        if server.kind == .webDAV {
            guard let url = video.url else { throw MediaError.message("文件地址无效。") }
            return PlaybackResource(url: url, headers: ["Authorization": basic(server: server)])
        }
        guard let token = Credentials.read(server.id), let item = video.remoteID, let user = server.userID else { throw MediaError.message("登录已失效，请重新添加服务器。") }
        var tracks = tracks
        if server.kind.isCatalogSource, tracks.needsSourceBinding {
            // Both servers apply stream indices only to the selected source.
            // Explicit subtitle-off (-1) also needs this identity binding.
            let detail = try await catalogDetail(server: server, id: item)
            guard let source = detail.MediaSources?.first else { throw MediaError.message("服务器未提供可选择的媒体版本。") }
            tracks.mediaSourceID = source.Id
        }
        if quality == .original && tracks.requiresServerSelection { throw MediaError.message("当前声音或字幕需要 \(server.kind.title) 处理。") }
        var body = MediaServerAPI.playbackBody(kind: server.kind, userID: user, quality: quality, directVideoCodecs: Self.hardwareVideoCodecs)
        tracks.apply(to: &body)
        if server.kind == .emby, tracks.subtitleIndex.map({ $0 >= 0 }) == true, var profile = body["DeviceProfile"] as? [String: Any] {
            profile["SubtitleProfiles"] = ["srt", "ass", "ssa", "subrip", "pgssub", "dvdsub", "vtt"].map { ["Format": $0, "Method": "Encode"] }
            body["DeviceProfile"] = profile
        }
        struct Source: Decodable { var Id: String; var SupportsDirectPlay: Bool?; var SupportsDirectStream: Bool?; var Container: String?; var TranscodingUrl: String?; var MediaStreams: [CatalogItem.Stream]?; var Path: String?; var Bitrate: Int?; var DefaultAudioStreamIndex: Int?; var DefaultSubtitleStreamIndex: Int?; var MediaAttachments: [CatalogItem.Attachment]? }
        struct Info: Decodable { var MediaSources: [Source]?; var PlaySessionId: String?; var ErrorCode: String? }
        let data = try await request(ServerURL.endpoint(server.address, "Items/\(item)/PlaybackInfo"), method: "POST", headers: ["Authorization": authorization(token, server: server), "Content-Type": "application/json"], body: JSONSerialization.data(withJSONObject: body))
        let info = try JSONDecoder().decode(Info.self, from: data)
        guard info.ErrorCode == nil, let source = info.MediaSources?.first(where: { tracks.mediaSourceID == nil || $0.Id == tracks.mediaSourceID }) else {
            if quality == .compatible { throw OriginalTransportError.noPlayableSource }
            throw MediaError.message("\(server.kind.title) 没有可播放的版本，请检查用户播放权限和转码设置。")
        }
        let playSessionID = info.PlaySessionId ?? (server.kind == .emby ? UUID().uuidString.replacingOccurrences(of: "-", with: "") : nil)
        let stream = source.MediaStreams?.first { $0.Type == "Video" }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--glide-jellyfin-investigation") {
            let safeKeys = Set(["videocodec", "audiocodec", "allowvideostreamcopy", "allowaudiostreamcopy", "segmentcontainer", "transcodereasons", "subtitlemethod", "subtitlestreamindex", "h264-rangetype", "hevc-rangetype", "h264-profile", "hevc-profile", "h264-videobitdepth", "hevc-videobitdepth"])
            let query = URLComponents(string: source.TranscodingUrl ?? "")?.queryItems ?? []
            var safe: [String: Any] = ["supportsDirectPlay": source.SupportsDirectPlay ?? false, "supportsDirectStream": source.SupportsDirectStream ?? false, "container": PlaybackDiagnostic.token(source.Container) ?? "unknown"]
            safe["serverDefaultSubtitleIndex"] = source.DefaultSubtitleStreamIndex ?? -1
            safe["explicitSubtitleIndex"] = tracks.subtitleIndex ?? -2
            for item in query where safeKeys.contains(item.name.lowercased()) {
                if let value = item.value, value.count < 256,
                   value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " ,.|_-".unicodeScalars.contains($0) }) { safe[item.name.lowercased()] = value }
            }
            let snapshot = safe
            await MainActor.run { Self.qaNegotiationReport = snapshot }
        }
#endif
        let sourceBitrate = [source.Bitrate, stream?.BitRate].compactMap { $0 }.first { $0 > 0 }
        let uncertainDirect = PlaybackDelivery.suspectHEVCMP4(stream?.Codec, tag: stream?.CodecTag, container: source.Container)
        let negotiatedURL = source.TranscodingUrl.flatMap { MediaServerAPI.streamURL(path: $0, server: server) }
        let sourceIsHDR = NativeColorPolicy.isHDR(range: stream?.VideoRangeType, transfer: stream?.ColorTransfer)
        let forcedOnly = await PlaybackPreferences.forcedOnly
        let selectedSubtitleIndex = CatalogSubtitlePolicy.selectedIndex(explicit: tracks.subtitleIndex, url: negotiatedURL,
            serverDefault: source.DefaultSubtitleStreamIndex, streams: source.MediaStreams ?? [], forcedOnly: forcedOnly)
        if !directOnly, server.kind == .jellyfin, quality == .automatic, tracks.subtitleIndex == nil, sourceIsHDR, let url = negotiatedURL,
           let alternative = CatalogSubtitlePolicy.alternativeForDefaultBurn(url: url, streams: source.MediaStreams ?? [], forcedOnly: forcedOnly) {
            // Only an implicit bitmap default may change. Keep the language and
            // forced status; explicit choices and subtitle-off remain intact.
            var selected = tracks; selected.mediaSourceID = source.Id; selected.subtitleIndex = alternative
            var resolved = try await playback(video: video, server: server, quality: quality, tracks: selected)
            resolved.resolvedTracks = selected; resolved.preferredTextSubtitle = true
            return resolved
        }
        if server.kind == .jellyfin, let index = selectedSubtitleIndex,
           let subtitle = source.MediaStreams?.first(where: { $0.Type == "Subtitle" && $0.Index == index }),
           (CatalogSubtitlePolicy.textCodecs.contains(subtitle.Codec?.lowercased() ?? "") || CatalogSubtitlePolicy.pgsCodecs.contains(subtitle.Codec?.lowercased() ?? "")) {
            // A warmup resource is used as-is by the controller. Do not cache
            // a video-only resource when the default needs client delivery.
            if directOnly { throw MediaError.message("默认字幕将在开始播放时读取。") }
            let bitmap = CatalogSubtitlePolicy.pgsCodecs.contains(subtitle.Codec?.lowercased() ?? "")
                ? try await serverBitmapSubtitle(video: video, server: server, sourceID: source.Id, stream: subtitle) : nil
            let ass = ["ass", "ssa"].contains(subtitle.Codec?.lowercased() ?? "")
                ? try await serverASSSubtitle(video: video, server: server, sourceID: source.Id, stream: subtitle, attachments: source.MediaAttachments) : nil
            let cues: [SubtitleCue]
            if let ass { cues = ass.cues }
            else if bitmap == nil { cues = try await serverSubtitle(video: video, server: server, sourceID: source.Id, stream: subtitle) }
            else { cues = [] }
#if DEBUG
            let subtitleNegotiation = await MainActor.run { Self.qaNegotiationReport }
#endif
            var withoutSubtitles = tracks; withoutSubtitles.mediaSourceID = source.Id; withoutSubtitles.subtitleIndex = -1
            var resolved = try await playback(video: video, server: server, quality: quality, tracks: withoutSubtitles)
            var selected = tracks; selected.mediaSourceID = source.Id; selected.subtitleIndex = index
            resolved.resolvedTracks = selected; resolved.serverSubtitleCues = cues; resolved.serverBitmapSubtitle = bitmap; resolved.serverASSSubtitle = ass
            let track = SubtitleServerTrack(mediaSourceID: source.Id, stream: subtitle)
            resolved.serverSubtitleTrack = track
            resolved.serverSubtitleLanguage = PlaybackDiagnostic.token(subtitle.Language)
            resolved.serverSubtitleName = track.name
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--glide-jellyfin-investigation") {
                await MainActor.run { Self.qaNegotiationReport["subtitleExtractionNegotiation"] = subtitleNegotiation }
            }
#endif
            return resolved
        }
        if quality == .original || (quality == .automatic && source.SupportsDirectPlay == true && !tracks.requiresServerSelection && !uncertainDirect) {
            let url = MediaServerAPI.directURL(server: server, itemID: item, sourceID: source.Id, sessionID: playSessionID, deviceID: deviceID, token: token)
            return PlaybackResource(url: url, sessionID: playSessionID, mediaSourceID: source.Id, videoStream: stream, sourceBitrate: sourceBitrate, supportsDirectStream: source.SupportsDirectStream, sourcePath: source.Path,
                serverSubtitleStreams: source.MediaStreams?.filter { $0.Type == "Subtitle" } ?? [],
                serverAudioStreams: source.MediaStreams?.filter { $0.Type == "Audio" } ?? [],
                serverAudioIndex: tracks.audioIndex ?? source.DefaultAudioStreamIndex)
        }
        // Warmup may negotiate capabilities, but must never request an HLS URL
        // or extract subtitles for a video not yet selected.
        if directOnly { throw MediaError.message("此视频不适合预备原画播放。") }
        guard let negotiatedURL else {
            if quality == .compatible { throw OriginalTransportError.noCopyURL }
            throw MediaError.message("此格式需要 \(server.kind.title) 转码；请在服务器上启用转码权限。")
        }
        let url = MediaServerAPI.subtitleOffURL(negotiatedURL, kind: server.kind, tracks: tracks)
        // Some Jellyfin versions report SupportsDirectStream=false for HLS
        // video-copy jobs. Validate the actual negotiated URL below instead.
        let nativeURL: URL
        if quality == .compatible {
            nativeURL = try OriginalTransportPolicy.videoCopyURL(url, sourceCodec: stream?.Codec,
                burnsSubtitles: server.kind == .emby && tracks.subtitleIndex.map { $0 >= 0 } == true)
        } else {
            nativeURL = quality == .automatic
                ? (OriginalTransportPolicy.preferredHDRCopyURL(url, sourceCodec: stream?.Codec, hdr: sourceIsHDR, bitrate: sourceBitrate)
                    ?? NativeColorPolicy.preferHEVCForHDR(url, sourceCodec: stream?.Codec, sourceIsHDR: sourceIsHDR)) : url
        }
        let streamURL = NativeColorPolicy.constrainAVC(JellyfinPlaybackPolicy.transcodeURL(nativeURL, quality: quality), sourceIsHDR: sourceIsHDR)
        if quality == .compatible && PlaybackDelivery.negotiated(url: streamURL, quality: quality) != .remux && PlaybackDelivery.negotiated(url: streamURL, quality: quality) != .audioConversion {
            throw OriginalTransportError.videoCopyNotConfirmed
        }
        var resource = PlaybackResource(url: streamURL, sessionID: playSessionID, mediaSourceID: source.Id, isTranscoding: true,
                                        delivery: PlaybackDelivery.negotiated(url: streamURL, quality: quality), videoStream: stream, sourceBitrate: sourceBitrate, supportsDirectStream: source.SupportsDirectStream, sourcePath: source.Path)
        resource.sourceContainer = source.Container
        resource.serverSubtitleStreams = source.MediaStreams?.filter { $0.Type == "Subtitle" } ?? []
        resource.serverAudioStreams = source.MediaStreams?.filter { $0.Type == "Audio" } ?? []
        resource.serverAudioIndex = URLComponents(url: nativeURL, resolvingAgainstBaseURL: false)?.queryItems?
            .last(where: { $0.name.lowercased() == "audiostreamindex" })?.value.flatMap(Int.init)
            ?? tracks.audioIndex ?? source.DefaultAudioStreamIndex
        if streamURL.lastPathComponent.lowercased() == "master.m3u8" {
            do {
                let master = try await request(streamURL, headers: ["Authorization": authorization(token, server: server)])
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--glide-jellyfin-investigation") {
                    let declarations = Self.qaMasterDeclarations(master)
                    await MainActor.run { Self.qaNegotiationReport["masterDeclarations"] = declarations }
                }
#endif
                try Task.checkCancellation()
                if quality == .automatic || quality == .compatible {
                    resource.prefersFirstHDRVariant = Self.hardwareVideoCodecs.split(separator: ",").contains("hevc")
                        && NativeHLSPlaylist.prefersFirstHDRVariant(master: streamURL, data: master, sourceCodec: stream?.Codec, sourceIsHDR: sourceIsHDR)
                }
                if let media = NativeHLSPlaylist.mediaURL(master: streamURL, data: master, sourceIsHDR: sourceIsHDR) {
                    resource.url = media; resource.usesMediaPlaylist = true
                }
            } catch {
                if Task.isCancelled {
                    Task { try? await self.stopTranscoding(server: server, resource: resource) }
                    throw CancellationError()
                }
                // Keep AVPlayer's normal HLS handling when the server cannot
                // provide an eligible self-contained media playlist.
            }
        }
        return resource
    }
#if DEBUG
    private static func qaMasterDeclarations(_ data: Data) -> [[String: String]] {
        guard data.count < 262_144, let text = String(data: data, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: "(?:^|,)(CODECS|VIDEO-RANGE|RESOLUTION|FRAME-RATE)=(\"[^\"]*\"|[^,]*)") else { return [] }
        return text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }.prefix(8).map { line in
            let attributes = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            var values: [String: String] = [:]
            for match in regex.matches(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)) {
                guard let key = Range(match.range(at: 1), in: attributes), let value = Range(match.range(at: 2), in: attributes) else { continue }
                let clean = String(attributes[value]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if clean.count < 128, clean.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " ,._-".unicodeScalars.contains($0) }) { values[String(attributes[key])] = clean }
            }
            return values
        }
    }
#endif
    func report(_ event: String, video: Video, server: MediaServer, resource: PlaybackResource, position: Double, paused: Bool) async throws {
        guard server.kind.isCatalogSource, let item = video.remoteID, let token = Credentials.read(server.id) else { return }
        var body: [String: Any] = ["ItemId": item, "PositionTicks": Int64(max(0, position.isFinite ? position : 0) * 10_000_000), "IsPaused": paused, "CanSeek": true, "PlayMethod": MediaServerAPI.reportMethod(kind: server.kind, negotiatedMethod: resource.sessionReportMethod)]
        if server.kind == .emby {
            body["QueueableMediaTypes"] = ["Video"]
            body["EventName"] = paused ? "Pause" : "TimeUpdate"
        }
        body["PlaySessionId"] = resource.sessionID
        body["MediaSourceId"] = resource.mediaSourceID
        _ = try await request(ServerURL.endpoint(server.address, "Sessions/Playing" + (event.isEmpty ? "" : "/" + event)), method: "POST", headers: ["Authorization": authorization(token, server: server), "Content-Type": "application/json"], body: JSONSerialization.data(withJSONObject: body))
        if event == "Stopped" { try await stopTranscoding(server: server, resource: resource) }
    }
    func stopTranscoding(server: MediaServer, resource: PlaybackResource) async throws {
        guard server.kind.isCatalogSource, resource.isTranscoding, let sessionID = resource.sessionID,
              let token = Credentials.read(server.id) else { return }
        _ = try await request(ServerURL.endpoint(server.address, "Videos/ActiveEncodings", query: ["DeviceId": deviceID, "PlaySessionId": sessionID]), method: "DELETE", headers: ["Authorization": authorization(token, server: server)])
    }
}


extension MediaClient {
    func catalogDetail(server: MediaServer, id: String, refresh: Bool = false) async throws -> CatalogItem {
        guard let user = server.userID, let token = Credentials.read(server.id) else { throw MediaError.message("请重新登录 \(server.kind.title)。") }
        let data = try await MediaCache.shared.data(scope: MediaCache.scope(server), key: "detail:" + id, ttl: 900, refresh: refresh) {
            let raw: Data
            do { raw = try await self.request(ServerURL.endpoint(server.address, "Users/\(user)/Items/\(id)"), headers: ["Authorization": self.authorization(token, server: server)]) }
            catch {
                guard case MediaError.message(let message) = error, message.hasPrefix("找不到资源") else { throw error }
                raw = try await self.request(ServerURL.endpoint(server.address, "Items/\(id)", query: ["UserId": user]), headers: ["Authorization": self.authorization(token, server: server)])
            }
            return try JSONEncoder().encode(JSONDecoder().decode(CatalogItem.self, from: raw))
        }
        return try JSONDecoder().decode(CatalogItem.self, from: data)
    }
    func catalogPage(server: MediaServer, parentID: String, type: String, start: Int, order: CatalogOrder = CatalogOrder(), search: String = "", refresh: Bool = false) async throws -> PersonMediaPage {
        guard let user = server.userID else { throw MediaError.message("请重新登录 \(server.kind.title)。") }
        var query = order.query
        query.merge(["UserId": user, "ParentId": parentID, "IncludeItemTypes": type, "Recursive": "true", "Fields": "Overview,Genres,MediaSources", "EnableUserData": "true", "StartIndex": String(start), "Limit": "60"]) { _, value in value }
        if !search.isEmpty { query["SearchTerm"] = search }
        return try await cached(PersonMediaPage.self, server: server, path: "Items", query: query, refresh: refresh)
    }
    func catalogItems(server: MediaServer, parentID: String, type: String, refresh: Bool = false) async throws -> [CatalogItem] {
        guard Credentials.read(server.id) != nil, let user = server.userID else { throw MediaError.message("请重新登录 \(server.kind.title)。") }
        struct Page: Codable { var Items: [CatalogItem]; var TotalRecordCount: Int }
        var items: [CatalogItem] = [], start = 0
        while true {
            try Task.checkCancellation()
            let query = ["UserId": user, "ParentId": parentID, "IncludeItemTypes": type,
                         "Recursive": ["Movie", "Series", "Episode"].contains(type) ? "true" : "false",
                         "Fields": "Overview,Genres,MediaSources", "EnableUserData": "true",
                         "SortBy": type == "Season" || type == "Episode" ? "ParentIndexNumber,IndexNumber,SortName" : "SortName",
                         "SortOrder": "Ascending", "StartIndex": String(start), "Limit": "100"]
            let page = try await cached(Page.self, server: server, path: "Items", query: query, refresh: refresh)
            let known = Set(items.map(\.id))
            let added = page.Items.filter { !known.contains($0.id) }
            items += added; start += page.Items.count
            if start >= page.TotalRecordCount { break }
            guard !added.isEmpty else { throw MediaError.message("媒体列表分页没有进展，请刷新重试。") }
        }
        return type == "Season" || type == "Episode" ? CatalogItem.episodeOrder(items) : items
    }
}


extension MediaClient {
    func personMedia(server: MediaServer, personID: String, start: Int, refresh: Bool = false) async throws -> PersonMediaPage {
        guard Credentials.read(server.id) != nil, let user = server.userID else { throw MediaError.message("请重新登录 \(server.kind.title)。") }
        let query = try PersonMediaQuery.items(userID: user, personID: personID, start: start)
        return try await cached(PersonMediaPage.self, server: server, path: "Items", query: query, refresh: refresh)
    }
}


extension MediaClient {
    static var hardwareVideoCodecs: String {
        var codecs = ["h264"]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { codecs.append("hevc") }
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) { codecs.append("av1") }
        return codecs.joined(separator: ",")
    }
}


extension MediaClient {
    func facetMedia(server: MediaServer, facet: CatalogFacet, start: Int, refresh: Bool = false) async throws -> PersonMediaPage {
        guard let user = server.userID else { throw MediaError.message("请重新登录 \(server.kind.title)。") }
        return try await cached(PersonMediaPage.self, server: server, path: "Items", query: facet.query(user: user, start: start), refresh: refresh)
    }
    func similarMedia(server: MediaServer, item: CatalogItem, refresh: Bool = false) async throws -> [CatalogItem] {
        guard let user = server.userID else { throw MediaError.message("请重新登录 \(server.kind.title)。") }
        let target = item.Type == "Episode" ? item.SeriesId ?? item.id : item.id
        let page = try await cached(PersonMediaPage.self, server: server, path: "Items/\(target)/Similar",
                                    query: ["UserId": user, "Limit": "12", "Fields": "Overview,Genres,Tags"], refresh: refresh)
        var seen = Set([target, item.id]); var results: [CatalogItem] = []
        for candidate in page.Items {
            try Task.checkCancellation()
            let id = candidate.Type == "Episode" ? candidate.SeriesId : candidate.id
            guard let id, seen.insert(id).inserted else { continue }
            if candidate.Type == "Episode" {
                results.append(try await catalogDetail(server: server, id: id, refresh: refresh))
            } else if ["Movie", "Series", "Video", "MusicVideo"].contains(candidate.Type ?? "") { results.append(candidate) }
        }
        return results
    }
}


extension MediaClient {
    func freshProgress(video: Video, server: MediaServer) async throws -> CatalogItem.Progress? {
        guard let user = server.userID, let id = video.remoteID, let token = Credentials.read(server.id) else { return nil }
        struct ProgressOnly: Decodable { var UserData: CatalogItem.Progress? }
        let data = try await request(ServerURL.endpoint(server.address, "Users/\(user)/Items/\(id)"), headers: ["Authorization": authorization(token, server: server)])
        return try JSONDecoder().decode(ProgressOnly.self, from: data).UserData
    }
}


extension MediaClient {
    func setWatched(_ watched: Bool, video: Video, server: MediaServer) async throws {
        guard let user = server.userID, let id = video.remoteID, let token = Credentials.read(server.id) else { throw MediaError.message("请重新登录此来源。") }
        _ = try await request(ServerURL.endpoint(server.address, "Users/\(user)/PlayedItems/\(id)"), method: watched ? "POST" : "DELETE", headers: ["Authorization": authorization(token, server: server)])
        await MediaCache.shared.clear(server: server)
    }
}
