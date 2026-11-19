import Foundation

enum VideoSort: String, Codable, CaseIterable, Identifiable {
    case nameAscending, nameDescending, addedNewest, addedOldest, sizeDescending, sizeAscending
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nameAscending: "名称升序"
        case .nameDescending: "名称降序"
        case .addedNewest: "最新添加"
        case .addedOldest: "最早添加"
        case .sizeDescending: "文件大小：从大到小"
        case .sizeAscending: "文件大小：从小到大"
        }
    }
    var isFileSize: Bool { self == .sizeAscending || self == .sizeDescending }
    var symbol: String { isFileSize ? "externaldrive" : self == .addedNewest || self == .addedOldest ? "calendar.badge.clock" : "textformat.abc" }
    var jellyfinField: String { self == .addedNewest || self == .addedOldest ? "DateCreated" : "SortName" }
    // Size isn't a native Jellyfin sort field. Fetch stable pages before sorting locally.
    var jellyfinOrder: String { isFileSize || self == .nameAscending || self == .addedOldest ? "Ascending" : "Descending" }
    func sorted(_ videos: [Video]) -> [Video] {
        videos.sorted {
            if isFileSize, let result = MediaFileSize.precedes($0.fileSize, $1.fileSize, descending: self == .sizeDescending) { return result }
            if self == .addedNewest || self == .addedOldest {
                switch ($0.addedAt, $1.addedAt) {
                case let (a?, b?) where a != b: return self == .addedNewest ? a > b : a < b
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            let order = $0.title.localizedStandardCompare($1.title)
            if order == .orderedSame { return $0.id < $1.id }
            return self == .nameDescending ? order == .orderedDescending : order == .orderedAscending
        }
    }
}

enum FolderSort: String, Codable, CaseIterable, Identifiable {
    case nameAscending, nameDescending, addedNewest, addedOldest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .nameAscending: "名称升序"
        case .nameDescending: "名称降序"
        case .addedNewest: "最新添加"
        case .addedOldest: "最早添加"
        }
    }
    var jellyfinField: String { self == .addedNewest || self == .addedOldest ? "DateCreated" : "SortName" }
    var jellyfinOrder: String { self == .nameAscending || self == .addedOldest ? "Ascending" : "Descending" }

    func sorted(_ folders: [MediaFolder]) -> [MediaFolder] {
        folders.sorted { precedes(name: $0.name, date: $0.addedAt, id: $0.id,
                                   name: $1.name, date: $1.addedAt, id: $1.id) }
    }
    func sorted(_ directories: [DAVEntry]) -> [DAVEntry] {
        directories.sorted { precedes(name: $0.name, date: $0.displayDate, id: $0.id,
                                       name: $1.name, date: $1.displayDate, id: $1.id) }
    }
    private func precedes(name firstName: String, date firstDate: Date?, id firstID: String,
                          name secondName: String, date secondDate: Date?, id secondID: String) -> Bool {
        if self == .addedNewest || self == .addedOldest {
            switch (firstDate, secondDate) {
            case let (first?, second?) where first != second:
                return self == .addedNewest ? first > second : first < second
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
        }
        let comparison = firstName.localizedStandardCompare(secondName)
        if comparison == .orderedSame { return firstID < secondID }
        return self == .nameDescending ? comparison == .orderedDescending : comparison == .orderedAscending
    }
}

struct BrowseOptions: Codable, Equatable {
    var includesDescendants = true
    var sort: VideoSort = .nameAscending
    var scopeTitle: String { includesDescendants ? "包含子目录" : "仅当前层" }
    var key: String { "\(includesDescendants):\(sort.rawValue)" }
}

struct DirectoryBookmark: Codable, Identifiable, Equatable {
    var sourceID: UUID
    var name: String
    var jellyPath: [MediaFolder]
    var davPath: [URL]
    var options: BrowseOptions? = nil
    var mode: PlaybackMode? = nil
    var accountID: String? = nil
    var localPath: String? = nil
    var id: String {
        if let localPath { return sourceID.uuidString + ":local:" + localPath }
        return sourceID.uuidString + ":" + (jellyPath.last?.id ?? davPath.last?.absoluteString ?? "root")
    }
}
