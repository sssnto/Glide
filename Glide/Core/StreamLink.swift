import Foundation

struct StreamLinkPayload: Codable, Equatable, Sendable {
    var url: URL
    var headers: [String: String]
    static func parse(_ text: String, headers: String = "") throws -> Self {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 16_384, !value.contains(where: { $0.isWhitespace }),
              let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else {
            throw MediaError.message("请输入完整的 HTTP(S) 视频地址；账号密码请放在请求头中。")
        }
        let fields = try parseHeaders(headers)
        guard fields.isEmpty || url.pathExtension.lowercased() != "m3u8" else {
            throw MediaError.message("HLS 链接暂不支持自定义请求头，请使用无需请求头的地址。")
        }
        return Self(url: url, headers: fields)
    }
    static func parseHeaders(_ text: String) throws -> [String: String] {
        guard text.utf8.count <= 8192 else { throw MediaError.message("请求头总长度不能超过 8 KB。") }
        var values: [String: String] = [:], seen = Set<String>()
        let forbidden: Set<String> = ["host", "range", "content-length", "connection", "transfer-encoding", "accept-encoding"]
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard values.count < 10, let colon = line.firstIndex(of: ":") else { throw MediaError.message("每行填写一个「名称: 值」，最多 10 个请求头。") }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let lower = name.lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !forbidden.contains(lower), seen.insert(lower).inserted else {
                throw MediaError.message("请求头无效、重复或由播放器管理，请检查名称和值。")
            }
            values[name] = value
        }
        return values
    }
    static func strm(_ data: Data) throws -> Self {
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            throw MediaError.message("STRM 必须是 64 KB 以内的 UTF-8 文本。")
        }
        let lines = text.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count == 1 else { throw MediaError.message("每个 STRM 文件只支持一条 HTTP(S) 地址。") }
        return try parse(lines[0])
    }
    func validated() throws -> Self {
        guard headers.allSatisfy({ entry in
            !entry.key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                && !entry.value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }) else { throw MediaError.message("请求头不能包含控制字符。") }
        return try Self.parse(url.absoluteString, headers: headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
    }
}

struct SavedStreamLink: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var createdAt: Date
    var revision: UUID? = nil
    var video: Video {
        Video(id: "link:" + id.uuidString + (revision.map { ":" + $0.uuidString } ?? ""), title: name, subtitle: host, addedAt: createdAt, streamLinkID: id)
    }
}
