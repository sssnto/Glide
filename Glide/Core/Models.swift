import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum SourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case jellyfin, emby, smb, webDAV, local
    var id: String { rawValue }
    var title: String {
        switch self { case .jellyfin: "Jellyfin"; case .emby: "Emby"; case .smb: "SMB"; case .webDAV: "WebDAV"; case .local: "本地视频" }
    }
    var symbol: String {
        switch self { case .jellyfin, .emby: "play.rectangle.on.rectangle"; case .smb, .webDAV: "externaldrive.connected.to.line.below"; case .local: "folder" }
    }
    var isCatalogSource: Bool { self == .jellyfin || self == .emby }
    var isFileSource: Bool { !isCatalogSource }
    var requiresCredentials: Bool { self != .local }
}

struct MediaServer: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var kind: SourceKind
    var address: URL
    var username: String
    var userID: String?
    /// Nil for the app's imported collection; otherwise an explicitly authorized folder.
    var localBookmark: Data? = nil
    var smb: SMBOptions? = nil
    /// File sources keep private swipe behavior unless explicitly enabled.
    var remembersPlayback: Bool? = nil
}

struct Video: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var sourceID: UUID?
    var remoteID: String?
    var url: URL?
    var artwork: URL?
    var duration: Double = 0
    var resume: Double = 0
    var demoIndex: Int?
    var mediaType: String?
    var addedAt: Date? = nil
    var seriesID: String? = nil
    var seriesTitle: String? = nil
    var seasonNumber: Int? = nil
    var episodeNumber: Int? = nil
    var isWatched: Bool? = nil
    /// Relative to the authorized source, independent of a changing sandbox/root URL.
    var localRelativePath: String? = nil
    var streamLinkID: UUID? = nil
    /// A deliberate local-only session. Never negotiate, prefetch, or recover online.
    var offlineOnly: Bool? = nil
}

struct DAVEntry: Identifiable, Equatable, Sendable {
    var url: URL
    var name: String
    var isDirectory: Bool
    var createdAt: Date? = nil
    var modifiedAt: Date? = nil
    var artwork: URL? = nil
    var id: String { url.absoluteString }
    var displayDate: Date? { createdAt ?? modifiedAt }
}

enum MediaFilePath {
    /// Display a file location, never the credentials or query of a remote URL.
    static func display(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.contains("://") || text.lowercased().hasPrefix("file:") else { return text }
        guard var parts = URLComponents(string: text), parts.scheme != nil else { return nil }
        parts.user = nil; parts.password = nil; parts.query = nil; parts.fragment = nil
        guard let url = parts.url else { return nil }
        if url.isFileURL { return url.path }
        guard url.host != nil else { return nil }
        return url.absoluteString.removingPercentEncoding ?? url.absoluteString
    }
}

enum MediaTimestamp {
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        let http = DateFormatter()
        http.locale = Locale(identifier: "en_US_POSIX")
        http.timeZone = TimeZone(secondsFromGMT: 0)
        http.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return http.date(from: text)
    }
}

enum MediaError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum ServerURL {
    static func parse(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw MediaError.message("请输入完整的 http:// 或 https:// 服务器地址，不要在地址中包含账号或密码。")
        }
        return url
    }
    static func endpoint(_ base: URL, _ path: String, query: [String: String] = [:]) -> URL {
        let url = base.appendingPathComponent(path)
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return parts.url!
    }
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ u: URL) -> Int { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : u.scheme?.lowercased() == "smb" ? 445 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }
}

/// Namespace-aware, Depth:1 WebDAV parsing. Ignore failed propstats and off-origin hrefs.
final class DAVParser: NSObject, XMLParserDelegate {
    private let base: URL
    private var entries: [DAVEntry] = []
    private var text = ""
    private var href = ""
    private var name = ""
    private var collection = false
    private var valid = false
    private var propertyName = ""
    private var propertyCollection = false
    private var status = ""
    private var createdAt: Date?
    private var modifiedAt: Date?
    private var propertyCreatedAt: Date?
    private var propertyModifiedAt: Date?
    init(base: URL) { self.base = base }
    func parse(_ data: Data) throws -> [DAVEntry] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else { throw MediaError.message("服务器返回的 WebDAV 文件列表无法解析。") }
        let current = base.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Array(Dictionary(entries.filter {
            $0.url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != current
        }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values).sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        text = ""
        if elementName == "response" { href = ""; name = ""; collection = false; valid = false; createdAt = nil; modifiedAt = nil }
        if elementName == "propstat" { propertyName = ""; propertyCollection = false; propertyCreatedAt = nil; propertyModifiedAt = nil; status = "" }
        if elementName == "collection" { propertyCollection = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "href": href = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "displayname": propertyName = text
        case "creationdate": propertyCreatedAt = MediaTimestamp.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "getlastmodified": propertyModifiedAt = MediaTimestamp.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "status": status = text
        case "propstat":
            if status.contains(" 200 ") {
                valid = true
                if !propertyName.isEmpty { name = propertyName }
                collection = collection || propertyCollection
                createdAt = createdAt ?? propertyCreatedAt
                modifiedAt = modifiedAt ?? propertyModifiedAt
            }
        case "response":
            guard valid, !href.isEmpty, let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  ServerURL.sameOrigin(base, url), url.user == nil, url.password == nil else { return }
            entries.append(DAVEntry(url: url, name: name.isEmpty ? url.lastPathComponent : name, isDirectory: collection, createdAt: createdAt, modifiedAt: modifiedAt))
        default: break
        }
        text = ""
    }
}

extension Double {
    var mediaTime: String {
        guard isFinite, self >= 0 else { return "00:00" }
        let value = Int(self)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60)
    }
}

struct MediaFolder: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var isLibrary = false
    var collectionType: String?
    var primaryImageTag: String? = nil
    var addedAt: Date? = nil
}

struct LibraryPage {
    var folders: [MediaFolder]
    var videos: [Video]
    var total: Int
    var nextIndex: Int
}

enum DirectoryQuery {
    /// Every page and refresh must retain ParentId and disable recursive enumeration.
    static func items(userID: String, parentID: String, start: Int, sort: FolderSort = .nameAscending) -> [String: String] {
        ["UserId": userID, "ParentId": parentID, "Recursive": "false", "Fields": "ParentId", "SortBy": "IsFolder,\(sort.jellyfinField)", "SortOrder": sort.jellyfinOrder, "StartIndex": String(start), "Limit": "100", "EnableUserData": "true"]
    }
    static func folderPreview(userID: String, parentID: String) -> [String: String] {
        ["UserId": userID, "ParentId": parentID, "Recursive": "true", "MediaTypes": "Video", "IsFolder": "false", "SortBy": "DateCreated", "SortOrder": "Descending", "StartIndex": "0", "Limit": "20"]
    }
}
