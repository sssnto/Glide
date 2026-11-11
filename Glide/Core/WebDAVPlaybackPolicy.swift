import Foundation

/// Only a resolved, scoped WebDAV file can opt into authenticated compatibility.
enum WebDAVPlaybackPolicy {
    static func accepts(file: URL, root: URL) -> Bool {
        ["http", "https"].contains(file.scheme?.lowercased() ?? "") && file.host != nil
            && file.user == nil && file.password == nil && file.query == nil && file.fragment == nil
            && DirectoryScope.contains(root: root, child: file)
    }
    static func prefersCompatibility(_ url: URL) -> Bool {
        ["mkv", "webm", "avi", "divx", "wmv", "flv", "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "ogv"].contains(url.pathExtension.lowercased())
    }
    static func canRecover(webDAV: Bool, engine: PlaybackEngineID, attempted: Bool, external: Bool) -> Bool {
        webDAV && engine == .avPlayer && !attempted && !external
    }
}

/// Small HTTP boundary shared with the loopback bridge. No client can select an upstream URL.
enum WebDAVBridgeHTTP {
    struct Request: Equatable {
        var head: Bool
        var range: String?
    }
    static func request(_ data: Data, path: String) -> Request? {
        guard data.count <= 8192, let text = String(data: data, encoding: .ascii), text.hasSuffix("\r\n\r\n") else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, ["GET", "HEAD"].contains(first[0]), first[1] == Substring(path),
              ["HTTP/1.0", "HTTP/1.1"].contains(first[2]) else { return nil }
        var range: String?
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "range" {
                guard range == nil, validRange(value) else { return nil }; range = value
            }
            if key == "transfer-encoding" || key == "content-length" && value != "0" { return nil }
        }
        return Request(head: first[0] == "HEAD", range: range)
    }
    static func validRange(_ value: String) -> Bool {
        guard value.hasPrefix("bytes="), value.count < 80 else { return false }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        func number(_ part: Substring) -> Int64? {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(part)
        }
        if parts[0].isEmpty { return number(parts[1]).map { $0 > 0 } ?? false }
        guard let start = number(parts[0]) else { return false }
        return parts[1].isEmpty || number(parts[1]).map { $0 >= start } == true
    }
    static func validResponse(status: Int, range: String?, contentRange: String?, length: Int64) -> Bool {
        if status == 200 { return range == nil || range == "bytes=0-" }
        guard status == 206, let range, validRange(range), let value = contentRange, value.hasPrefix("bytes ") else { return false }
        let parts = value.dropFirst(6).split(separator: "/"), limits = parts.first?.split(separator: "-") ?? []
        guard parts.count == 2, limits.count == 2, let start = Int64(limits[0]), let end = Int64(limits[1]),
              let total = Int64(parts[1]), start >= 0, end >= start, total > end, length == end - start + 1 else { return false }
        let requested = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        if requested[0].isEmpty, let suffix = Int64(requested[1]) { return start == max(0, total - suffix) && end == total - 1 }
        guard let offset = Int64(requested[0]), start == offset else { return false }
        return requested[1].isEmpty ? end == total - 1 : Int64(requested[1]).map { end == min($0, total - 1) } == true
    }
}
