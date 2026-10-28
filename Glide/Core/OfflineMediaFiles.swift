import Foundation

/// Completed transfers stay in durable storage, with the container extension intact.
struct OfflineMediaFiles: Sendable {
    let directory: URL
    /// Reserve full outstanding files conservatively: URLSession's temporary
    /// partial files are not guaranteed to be queryable by the app.
    static func canReserve(bytes: Int64, availableBytes: Int64, reservations: [Int64], safetyMargin: Int64 = 200 * 1024 * 1024) -> Bool {
        guard bytes > 0, safetyMargin >= 0, availableBytes >= safetyMargin else { return false }
        var remaining = availableBytes - safetyMargin
        for value in reservations {
            guard value >= 0, value <= remaining else { return false }
            remaining -= value
        }
        return bytes <= remaining
    }
    static func validFilename(_ filename: String) -> Bool {
        !filename.isEmpty && !filename.hasPrefix(".") && !filename.contains("\\") && filename == (filename as NSString).lastPathComponent && ["mp4", "mov", "m4v", "mkv"].contains((filename as NSString).pathExtension.lowercased())
    }
    func fileURL(_ filename: String) -> URL { directory.appendingPathComponent(filename) }
    func pendingURL(_ filename: String) -> URL { directory.appendingPathComponent("Pending", isDirectory: true).appendingPathComponent(filename) }

    func stage(_ temporary: URL, filename: String) throws {
        guard Self.validFilename(filename) else {
            throw MediaError.message("下载文件名无效，请重试下载。")
        }
        let target = pendingURL(filename)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: target)
    }

    static func validateResponse(status: Int, mimeType: String?) throws {
        guard (200..<300).contains(status) else {
            throw MediaError.message("下载失败（HTTP \(status)），请检查登录状态和下载权限。")
        }
        let mime = mimeType?.lowercased() ?? ""
        guard !mime.hasPrefix("text/"), !mime.contains("json"), !mime.contains("xml"), !mime.contains("mpegurl") else {
            throw MediaError.message("服务器返回的不是视频文件，请检查登录状态和下载权限。")
        }
    }

    static func validateSize(_ url: URL, expectedBytes: Int64?) throws {
        let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else { throw MediaError.message("下载文件为空，请重试下载。") }
        if let expectedBytes, expectedBytes > 0, bytes != expectedBytes {
            throw MediaError.message("文件大小不完整，请重试下载。")
        }
    }

    func commit(_ filename: String) throws {
        try FileManager.default.moveItem(at: pendingURL(filename), to: fileURL(filename))
    }

    func remove(_ filename: String) {
        try? FileManager.default.removeItem(at: pendingURL(filename))
        try? FileManager.default.removeItem(at: fileURL(filename))
    }
}
