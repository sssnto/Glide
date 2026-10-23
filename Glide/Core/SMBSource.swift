import Foundation

struct SMBOptions: Codable, Equatable, Sendable {
    var guest = false
    var domain = ""
    var encrypted = false
}

/// Credential-free SMB locator. A source is confined to one share and optional root.
struct SMBLocation: Equatable, Sendable {
    let url: URL
    let host: String
    let share: String
    let path: String

    init(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "smb", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw MediaError.message("请输入 SMB 地址，不要在地址中包含账号或密码。")
        }
        let names = try parts.percentEncodedPath.split(separator: "/").map { encoded -> String in
            guard let name = String(encoded).removingPercentEncoding,
                  Self.validName(name) else { throw MediaError.message("共享目录位置无效，不能包含上级路径或链接分隔符。") }
            return name
        }
        guard let share = names.first else { throw MediaError.message("请填写共享目录名称，例如 video。") }
        var normalized = parts
        normalized.scheme = "smb"; normalized.host = host.lowercased()
        normalized.path = "/" + names.joined(separator: "/")
        if normalized.port == 445 { normalized.port = nil }
        self.url = normalized.url!; self.share = share; self.path = names.dropFirst().joined(separator: "/")
        let transportHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        self.host = transportHost + (parts.port.map { ":\($0)" } ?? "")
    }

    static func parse(address: String, share: String = "") throws -> URL {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text.lowercased().hasPrefix("smb://") ? text : "smb://" + text) else {
            throw MediaError.message("SMB 服务器地址无效。")
        }
        if !share.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard parts.path.isEmpty || parts.path == "/" else { throw MediaError.message("地址已包含共享目录，请只在一处填写。") }
            let names = share.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard names.allSatisfy(validName) else { throw MediaError.message("共享目录位置无效。") }
            parts.path = "/" + names.joined(separator: "/")
        }
        guard let url = parts.url else { throw MediaError.message("SMB 服务器地址无效。") }
        return try Self(url).url
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    func relativePath(_ child: URL) throws -> String {
        let value = try Self(child)
        guard url.host?.lowercased() == child.host?.lowercased(), (url.port ?? 445) == (child.port ?? 445),
              share == value.share, path.isEmpty || value.path == path || value.path.hasPrefix(path + "/") else {
            throw MediaError.message("文件超出了此来源的共享目录。")
        }
        return value.path
    }

    func child(_ name: String, directory: Bool) throws -> URL {
        guard Self.validName(name) else { throw MediaError.message("服务器返回了无效文件名。") }
        return url.appendingPathComponent(name, isDirectory: directory)
    }
}

enum SMBFailure {
    static func message(code: Int) -> String {
        switch code {
        case 1001: "SMB 认证失败，请检查账号、密码与域，或重新登录此来源。"
        case 1, 13: "没有此 SMB 共享目录或视频的读取权限，请检查 NAS 的共享权限。"
        case 2, 6: "共享目录或视频已不存在，请刷新目录。"
        case 110, 60: "SMB 读取超时，请确认 NAS 已唤醒并检查网络后重试。"
        case 89, 95, 45: "服务器要求的 SMB 协议或加密方式暂不支持，请检查共享设置。"
        default: "SMB 连接已中断，请确认 NAS 与设备在可互通的网络中，然后重试。"
        }
    }
}
