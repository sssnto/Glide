import Foundation

enum SourceCapability: String, Codable, Hashable, Sendable {
    case catalog, directories, recursiveQueue, credentials, download, progressReporting
}

extension SourceKind {
    var capabilities: Set<SourceCapability> {
        switch self {
        case .jellyfin, .emby: [.catalog, .directories, .recursiveQueue, .credentials, .download, .progressReporting]
        case .webDAV, .smb: [.directories, .recursiveQueue, .credentials]
        case .local: [.directories, .recursiveQueue]
        }
    }
}

enum LocalMediaIdentity {
    static func relativePath(root: URL, file: URL) throws -> String {
        guard root.isFileURL, file.isFileURL else { throw MediaError.message("本地来源只接受文件位置。") }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let child = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard child.starts(with: base) else { throw MediaError.message("文件超出了已授权目录。") }
        return child.dropFirst(base.count).joined(separator: "/")
    }

    static func fileURL(root: URL, relativePath: String) throws -> URL {
        guard root.isFileURL, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }) else {
            throw MediaError.message("本地文件位置无效，请重新选择目录。")
        }
        let file = relativePath.isEmpty ? root : root.appendingPathComponent(relativePath)
        // Resolving a nonexistent leaf does not reliably resolve a symlink in its parent.
        // Reject link components explicitly before accepting even a missing file.
        var component = root
        for name in relativePath.split(separator: "/") {
            component.appendPathComponent(String(name))
            if (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw MediaError.message("本地文件位置包含链接，请选择原始文件。")
            }
        }
        _ = try self.relativePath(root: root.resolvingSymlinksInPath(), file: file.resolvingSymlinksInPath())
        return file
    }

    static func id(sourceID: UUID, relativePath: String) -> String {
        sourceID.uuidString + ":local:" + relativePath
    }
}

/// File-only enumeration; symlinks and package contents are not followed.
enum LocalDirectoryIndex {
    static func entries(root: URL, directory: URL) throws -> [DAVEntry] {
        _ = try LocalMediaIdentity.relativePath(root: root.resolvingSymlinksInPath(), file: directory.resolvingSymlinksInPath())
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .creationDateKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]).compactMap { url in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isPackage != true,
                  values.isDirectory == true || values.isRegularFile == true else { return nil }
            return DAVEntry(url: url, name: url.lastPathComponent, isDirectory: values.isDirectory == true,
                            createdAt: values.creationDate, modifiedAt: values.contentModificationDate)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
