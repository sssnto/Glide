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

struct PlaybackResource {
    var url: URL
    var headers: [String: String] = [:]
    var sessionID: String?
    var mediaSourceID: String?
    var isTranscoding = false
    var delivery: PlaybackDelivery = .direct
    var videoStream: CatalogItem.Stream?
    var supportsDirectStream: Bool?
    var usesMediaPlaylist = false
    var prefersFirstHDRVariant = false
    var sessionReportMethod: String { delivery == .direct || delivery == .local ? "DirectPlay" : delivery == .remux || delivery == .audioConversion ? "DirectStream" : "Transcode" }
}

final class MediaClient {
    static let shared = MediaClient()
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
    func authorization(_ token: String? = nil) -> String {
        var result = "MediaBrowser Client=\"Glide\", Device=\"iOS\", DeviceId=\"\(deviceID)\", Version=\"0.1.0\""
        if let token { result += ", Token=\"\(token)\"" }
        return result
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
    func signIn(server: MediaServer, password: String) async throws -> (String, String) {
        struct User: Decodable { let Id: String }
        struct Result: Decodable { let AccessToken: String; let User: User }
        let data = try await request(ServerURL.endpoint(server.address, "Users/AuthenticateByName"), method: "POST", headers: ["Authorization": authorization(), "Content-Type": "application/json"], body: JSONSerialization.data(withJSONObject: ["Username": server.username, "Pw": password]))
        let result = try JSONDecoder().decode(Result.self, from: data)
        return (result.AccessToken, result.User.Id)
    }
    private struct Item: Codable {
            var Id: String; var Name: String; var ProductionYear: Int?; var RunTimeTicks: Int64?; var SeriesName: String?; var DateCreated: String?
            var IsFolder: Bool?; var MediaType: String?; var `Type`: String?; var CollectionType: String?; var ImageTags: [String: String]?
            var UserData: Progress?
            struct Progress: Codable { var PlaybackPositionTicks: Int64? }
        }
    private struct Result: Codable { var Items: [Item]; var TotalRecordCount: Int }
    func browse(server: MediaServer, parentID: String?, start: Int = 0, sort: FolderSort = .nameAscending) async throws -> LibraryPage {
        guard let token = Credentials.read(server.id), let user = server.userID else { throw MediaError.message("请重新登录 Jellyfin。") }
        let url: URL
        if let parentID {
            url = ServerURL.endpoint(server.address, "Items", query: DirectoryQuery.items(userID: user, parentID: parentID, start: start, sort: sort))
        } else {
            // UserViews is the current endpoint (including Jellyfin 12); no global video query.
            url = ServerURL.endpoint(server.address, "UserViews", query: ["UserId": user, "IncludeExternalContent": "false"])
        }
        let data: Data
        do { data = try await request(url, headers: ["Authorization": authorization(token)]) }
        catch {
            // Older Jellyfin versions only expose the legacy user views route.
            if parentID == nil, case MediaError.message(let message) = error, message.hasPrefix("找不到资源") {
                data = try await request(ServerURL.endpoint(server.address, "Users/\(user)/Views"), headers: ["Authorization": authorization(token)])
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
        Video(id: server.id.uuidString + item.Id, title: item.Name, subtitle: [item.SeriesName, item.ProductionYear.map(String.init), server.name].compactMap { $0 }.joined(separator: " · "), sourceID: server.id, remoteID: item.Id, artwork: ServerURL.endpoint(server.address, "Items/\(item.Id)/Images/Primary", query: ["maxWidth": "700", "quality": "85"]), duration: Double(item.RunTimeTicks ?? 0) / 10_000_000, resume: Double(item.UserData?.PlaybackPositionTicks ?? 0) / 10_000_000, addedAt: MediaTimestamp.parse(item.DateCreated))
    }
    func playbackVideos(server: MediaServer, parentID: String, start: Int, search: String = "", options: BrowseOptions = BrowseOptions()) async throws -> VideoPage {
        guard let token = Credentials.read(server.id), let user = server.userID else { throw MediaError.message("请重新登录 Jellyfin。") }
        let url = ServerURL.endpoint(server.address, "Items", query: DirectoryQuery.playback(userID: user, parentID: parentID, start: start, search: search, options: options))
        let data = try await request(url, headers: ["Authorization": authorization(token)])
        let result = try JSONDecoder().decode(Result.self, from: data)
        let videos = result.Items.filter { $0.IsFolder != true && ($0.MediaType == "Video" || ["Movie", "Episode", "Video", "MusicVideo"].contains($0.Type ?? "")) }.map { video($0, server: server) }
        return VideoPage(videos: videos, total: result.TotalRecordCount, nextIndex: start + result.Items.count)
    }
    func folderPreview(server: MediaServer, folderID: String) async throws -> (id: String, tag: String?)? {
        guard let user = server.userID else { throw MediaError.message("请重新登录 Jellyfin。") }
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
    func playback(video: Video, server: MediaServer?, quality: PlaybackQuality = .automatic, tracks: TrackSelection = TrackSelection(), directOnly: Bool = false) async throws -> PlaybackResource {
        guard let server else {
            guard let url = video.url else { throw MediaError.message("找不到播放地址。") }
            return PlaybackResource(url: url, delivery: url.isFileURL ? .local : .direct)
        }
        if server.kind == .webDAV {
            guard let url = video.url else { throw MediaError.message("文件地址无效。") }
            return PlaybackResource(url: url, headers: ["Authorization": basic(server: server)])
        }
        guard let token = Credentials.read(server.id), let item = video.remoteID, let user = server.userID else { throw MediaError.message("登录已失效，请重新添加服务器。") }
        if quality == .original && tracks.requiresServerSelection { throw MediaError.message("当前声音或字幕需要 Jellyfin 处理。") }
        var body = JellyfinPlaybackPolicy.body(userID: user, quality: quality, directVideoCodecs: Self.hardwareVideoCodecs)
        tracks.apply(to: &body)
        if tracks.subtitleIndex.map({ $0 >= 0 }) == true, var profile = body["DeviceProfile"] as? [String: Any] {
            profile["SubtitleProfiles"] = ["srt", "ass", "ssa", "subrip", "pgssub", "dvdsub", "vtt"].map { ["Format": $0, "Method": "Encode"] }
            body["DeviceProfile"] = profile
        }
        struct Source: Decodable { var Id: String; var SupportsDirectPlay: Bool?; var SupportsDirectStream: Bool?; var Container: String?; var TranscodingUrl: String?; var MediaStreams: [CatalogItem.Stream]? }
        struct Info: Decodable { var MediaSources: [Source]?; var PlaySessionId: String?; var ErrorCode: String? }
        let data = try await request(ServerURL.endpoint(server.address, "Items/\(item)/PlaybackInfo"), method: "POST", headers: ["Authorization": authorization(token), "Content-Type": "application/json"], body: JSONSerialization.data(withJSONObject: body))
        let info = try JSONDecoder().decode(Info.self, from: data)
        guard info.ErrorCode == nil, let source = info.MediaSources?.first(where: { tracks.mediaSourceID == nil || $0.Id == tracks.mediaSourceID }) else { throw MediaError.message("Jellyfin 没有可播放的版本，请检查用户播放权限和转码设置。") }
        let stream = source.MediaStreams?.first { $0.Type == "Video" }
        let uncertainDirect = PlaybackDelivery.suspectHEVCMP4(stream?.Codec, tag: stream?.CodecTag, container: source.Container)
        if quality == .original || (quality == .automatic && source.SupportsDirectPlay == true && !tracks.requiresServerSelection && !uncertainDirect) {
            let url = ServerURL.endpoint(server.address, "Videos/\(item)/stream", query: ["static": "true", "MediaSourceId": source.Id, "api_key": token])
            return PlaybackResource(url: url, sessionID: info.PlaySessionId, mediaSourceID: source.Id, videoStream: stream, supportsDirectStream: source.SupportsDirectStream)
        }
        // Warmup may negotiate capabilities, but must never request an HLS URL
        // or create a competing server conversion for a video not yet selected.
        if directOnly { throw MediaError.message("此视频不适合预备原画播放。") }
        guard let path = source.TranscodingUrl, let url = URL(string: path, relativeTo: server.address.appendingPathComponent(""))?.absoluteURL, ServerURL.sameOrigin(server.address, url) else { throw MediaError.message("此格式需要 Jellyfin 转码；请在服务器上启用转码权限。") }
        if quality == .compatible, source.SupportsDirectStream != true { throw MediaError.message("服务器没有提供兼容的视频流。") }
        let sourceIsHDR = NativeColorPolicy.isHDR(range: stream?.VideoRangeType, transfer: stream?.ColorTransfer)
        let nativeURL = quality == .automatic || quality == .compatible
            ? NativeColorPolicy.preferHEVCForHDR(url, sourceCodec: stream?.Codec, sourceIsHDR: sourceIsHDR) : url
        let streamURL = NativeColorPolicy.constrainAVC(JellyfinPlaybackPolicy.transcodeURL(nativeURL, quality: quality), sourceIsHDR: sourceIsHDR)
        if quality == .compatible && PlaybackDelivery.negotiated(url: streamURL, quality: quality) != .remux && PlaybackDelivery.negotiated(url: streamURL, quality: quality) != .audioConversion {
            throw MediaError.message("服务器没有提供可直接播放的视频流。")
        }
        var resource = PlaybackResource(url: streamURL, sessionID: info.PlaySessionId, mediaSourceID: source.Id, isTranscoding: true,
                                        delivery: PlaybackDelivery.negotiated(url: streamURL, quality: quality), videoStream: stream)
        if streamURL.lastPathComponent.lowercased() == "master.m3u8" {
            do {
                let master = try await request(streamURL, headers: ["Authorization": authorization(token)])
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
    func report(_ event: String, video: Video, server: MediaServer, resource: PlaybackResource, position: Double, paused: Bool) async throws {
        guard server.kind == .jellyfin, let item = video.remoteID, let token = Credentials.read(server.id) else { return }
        var body: [String: Any] = ["ItemId": item, "PositionTicks": Int64(max(0, position.isFinite ? position : 0) * 10_000_000), "IsPaused": paused, "CanSeek": true, "PlayMethod": resource.sessionReportMethod]
        body["PlaySessionId"] = resource.sessionID
        body["MediaSourceId"] = resource.mediaSourceID
        _ = try await request(ServerURL.endpoint(server.address, "Sessions/Playing" + (event.isEmpty ? "" : "/" + event)), method: "POST", headers: ["Authorization": authorization(token), "Content-Type": "application/json"], body: JSONSerialization.data(withJSONObject: body))
        if event == "Stopped" { try await stopTranscoding(server: server, resource: resource) }
    }
    func stopTranscoding(server: MediaServer, resource: PlaybackResource) async throws {
        guard server.kind == .jellyfin, resource.isTranscoding, let sessionID = resource.sessionID,
              let token = Credentials.read(server.id) else { return }
        _ = try await request(ServerURL.endpoint(server.address, "Videos/ActiveEncodings", query: ["DeviceId": deviceID, "PlaySessionId": sessionID]), method: "DELETE", headers: ["Authorization": authorization(token)])
    }
}


extension MediaClient {
    func catalogDetail(server: MediaServer, id: String, refresh: Bool = false) async throws -> CatalogItem {
        guard let user = server.userID, let token = Credentials.read(server.id) else { throw MediaError.message("请重新登录 Jellyfin。") }
        let data = try await MediaCache.shared.data(scope: MediaCache.scope(server), key: "detail:" + id, ttl: 900, refresh: refresh) {
            let raw: Data
            do { raw = try await self.request(ServerURL.endpoint(server.address, "Users/\(user)/Items/\(id)"), headers: ["Authorization": self.authorization(token)]) }
            catch {
                guard case MediaError.message(let message) = error, message.hasPrefix("找不到资源") else { throw error }
                raw = try await self.request(ServerURL.endpoint(server.address, "Items/\(id)", query: ["UserId": user]), headers: ["Authorization": self.authorization(token)])
            }
            return try JSONEncoder().encode(JSONDecoder().decode(CatalogItem.self, from: raw))
        }
        return try JSONDecoder().decode(CatalogItem.self, from: data)
    }
    func catalogPage(server: MediaServer, parentID: String, type: String, start: Int, order: CatalogOrder = CatalogOrder(), search: String = "", refresh: Bool = false) async throws -> PersonMediaPage {
        guard let user = server.userID else { throw MediaError.message("请重新登录 Jellyfin。") }
        var query = order.query
        query.merge(["UserId": user, "ParentId": parentID, "IncludeItemTypes": type, "Recursive": "true", "Fields": "Overview,Genres", "EnableUserData": "true", "StartIndex": String(start), "Limit": "60"]) { _, value in value }
        if !search.isEmpty { query["SearchTerm"] = search }
        return try await cached(PersonMediaPage.self, server: server, path: "Items", query: query, refresh: refresh)
    }
    func catalogItems(server: MediaServer, parentID: String, type: String, refresh: Bool = false) async throws -> [CatalogItem] {
        guard Credentials.read(server.id) != nil, let user = server.userID else { throw MediaError.message("请重新登录 Jellyfin。") }
        struct Page: Codable { var Items: [CatalogItem]; var TotalRecordCount: Int }
        var items: [CatalogItem] = [], start = 0
        while true {
            try Task.checkCancellation()
            let query = ["UserId": user, "ParentId": parentID, "IncludeItemTypes": type,
                         "Recursive": ["Movie", "Series", "Episode"].contains(type) ? "true" : "false",
                         "Fields": "Overview,Genres", "EnableUserData": "true",
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
        guard Credentials.read(server.id) != nil, let user = server.userID else { throw MediaError.message("请重新登录 Jellyfin。") }
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
        guard let user = server.userID else { throw MediaError.message("请重新登录 Jellyfin。") }
        return try await cached(PersonMediaPage.self, server: server, path: "Items", query: facet.query(user: user, start: start), refresh: refresh)
    }
    func similarMedia(server: MediaServer, item: CatalogItem, refresh: Bool = false) async throws -> [CatalogItem] {
        guard let user = server.userID else { throw MediaError.message("请重新登录 Jellyfin。") }
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
        let data = try await request(ServerURL.endpoint(server.address, "Users/\(user)/Items/\(id)"), headers: ["Authorization": authorization(token)])
        return try JSONDecoder().decode(ProgressOnly.self, from: data).UserData
    }
}


extension MediaClient {
    func setWatched(_ watched: Bool, video: Video, server: MediaServer) async throws {
        guard let user = server.userID, let id = video.remoteID, let token = Credentials.read(server.id) else { throw MediaError.message("请重新登录此来源。") }
        _ = try await request(ServerURL.endpoint(server.address, "Users/\(user)/PlayedItems/\(id)"), method: watched ? "POST" : "DELETE", headers: ["Authorization": authorization(token)])
        await MediaCache.shared.clear(server: server)
    }
}
