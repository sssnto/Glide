import Foundation

struct LibrarySnapshot: Codable, Equatable {
    var servers: [MediaServer]
    var directoryPreferences: [String: BrowseOptions]
    var folderSortPreferences: [String: FolderSort]
    var bookmarks: [DirectoryBookmark]
    var personalVideos: [String: PersonalVideo]
    var favorites: Set<String>
    var positions: [String: Double]
    var progressSnapshots: [String: ProgressSnapshot]
    var episodeCatalog: [String: [Video]]

    static func legacy(from defaults: UserDefaults) throws -> LibrarySnapshot {
        func value<T: Decodable>(_ key: String, _ fallback: T) throws -> T {
            guard let stored = defaults.object(forKey: key) else { return fallback }
            guard let data = stored as? Data else { throw MediaError.message("旧版本机数据无法读取：" + key) }
            return try JSONDecoder().decode(T.self, from: data)
        }
        let favorites = defaults.object(forKey: "favorites")
        let positions = defaults.object(forKey: "positions")
        guard favorites == nil || favorites is [String], positions == nil || positions is [String: Double] else {
            throw MediaError.message("旧版本机收藏或进度无法读取。")
        }
        return try LibrarySnapshot(servers: value("servers", []), directoryPreferences: value("directoryPreferences.v1", [:]),
            folderSortPreferences: value("folderSortPreferences.v1", [:]), bookmarks: value("directoryBookmarks.v1", []),
            personalVideos: value("personalVideos.v1", [:]), favorites: Set(favorites as? [String] ?? []),
            positions: positions as? [String: Double] ?? [:],
            progressSnapshots: value("progressSnapshots.v1", [:]), episodeCatalog: value("episodeCatalog.v1", [:]))
    }
}
