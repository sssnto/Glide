import Foundation

enum PlaybackMode: String, CaseIterable, Identifiable {
    case sequential, random
    var id: String { rawValue }
    var title: String { self == .sequential ? "顺序播放" : "随机播放" }
    var symbol: String { self == .sequential ? "list.number" : "shuffle" }
}

/// A complete, scoped snapshot. Moving backwards follows the same shuffled order.
struct PlaybackQueue {
    private(set) var source: [Video]
    private(set) var ordered: [Video]
    private(set) var index: Int = 0
    private(set) var mode: PlaybackMode
    var current: Video? { ordered.indices.contains(index) ? ordered[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < ordered.count }

    init(videos: [Video], mode: PlaybackMode, startID: String? = nil, shuffle: ([Video]) -> [Video] = { $0.shuffled() }) {
        var seen = Set<String>()
        source = videos.filter { seen.insert($0.id).inserted }
        self.mode = mode
        ordered = mode == .random ? shuffle(source) : source
        if mode == .random, let startID, let selected = ordered.firstIndex(where: { $0.id == startID }) {
            ordered.insert(ordered.remove(at: selected), at: 0)
        }
        index = startID.flatMap { id in ordered.firstIndex { $0.id == id } } ?? 0
    }
    @discardableResult mutating func move(_ delta: Int) -> Bool {
        let next = index + delta
        guard ordered.indices.contains(next) else { return false }
        index = next
        return true
    }
    @discardableResult mutating func select(_ videoID: String) -> Bool {
        guard let selected = ordered.firstIndex(where: { $0.id == videoID }) else { return false }
        index = selected
        return true
    }
    mutating func setMode(_ mode: PlaybackMode, shuffle: ([Video]) -> [Video] = { $0.shuffled() }) {
        guard self.mode != mode else { return }
        let selected = current
        self.mode = mode
        if mode == .random {
            ordered = selected.map { [$0] } ?? []
            ordered += shuffle(source.filter { $0.id != selected?.id })
            index = 0
        } else {
            ordered = source
            index = selected.flatMap { selected in ordered.firstIndex { $0.id == selected.id } } ?? 0
        }
    }
    /// Extend an already playing preview without replacing the current item or random history.
    mutating func replaceVideos(_ videos: [Video], shuffle: ([Video]) -> [Video] = { $0.shuffled() }) {
        let selected = current
        var seen = Set<String>()
        var complete = videos.filter { seen.insert($0.id).inserted }
        if let selected, seen.insert(selected.id).inserted { complete.append(selected) }
        guard !complete.isEmpty else { return }
        source = complete
        if mode == .random {
            let valid = Set(complete.map(\.id))
            let existing = ordered.filter { valid.contains($0.id) }
            let existingIDs = Set(existing.map(\.id))
            ordered = existing + shuffle(complete.filter { !existingIDs.contains($0.id) })
        } else { ordered = complete }
        index = selected.flatMap { selected in ordered.firstIndex { $0.id == selected.id } } ?? 0
    }
}

struct VideoPage {
    var videos: [Video]
    var total: Int
    var nextIndex: Int
}

extension DirectoryQuery {
    /// Playback recursively includes descendants, while ALWAYS retaining the selected parent.
    static func playback(userID: String, parentID: String, start: Int, search: String = "", options: BrowseOptions = BrowseOptions()) -> [String: String] {
        var query = ["UserId": userID, "ParentId": parentID, "Recursive": options.includesDescendants ? "true" : "false", "MediaTypes": "Video", "IsFolder": "false", "SortBy": options.sort.jellyfinField, "SortOrder": options.sort.jellyfinOrder, "StartIndex": String(start), "Limit": "200", "EnableUserData": "true"]
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty { query["SearchTerm"] = term }
        return query
    }
}

enum DirectoryScope {
    static func contains(root: URL, child: URL) -> Bool {
        guard ServerURL.sameOrigin(root, child) else { return false }
        let base = root.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = child.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return base.isEmpty || path == base || path.hasPrefix(base + "/")
    }
    static func key(_ url: URL) -> String { url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    static func isVideo(_ url: URL) -> Bool { ["mp4", "mov", "m4v", "mkv", "avi", "ts", "webm"].contains(url.pathExtension.lowercased()) }
}

@MainActor enum ScopedQueueCollector {
    static func pages(fetch: (Int) async throws -> VideoPage, progress: (Int) -> Void) async throws -> [Video] {
        var result: [Video] = [], seen = Set<String>(), cursor = 0
        while true {
            try Task.checkCancellation()
            let page = try await fetch(cursor)
            try Task.checkCancellation()
            result += page.videos.filter { seen.insert($0.id).inserted }
            progress(result.count)
            if page.nextIndex >= page.total { break }
            guard page.nextIndex > cursor else { throw MediaError.message("服务器分页没有继续前进，请刷新目录后重试。") }
            cursor = page.nextIndex
        }
        return result
    }
    static func webDAV(root: URL, recursive: Bool = true, fetch: (URL) async throws -> [DAVEntry], progress: (Int) -> Void) async throws -> [DAVEntry] {
        var pending = [root], cursor = 0, seenFolders = Set<String>(), seenFiles = Set<String>()
        var result: [DAVEntry] = []
        while cursor < pending.count {
            try Task.checkCancellation()
            let directory = pending[cursor]; cursor += 1
            guard seenFolders.insert(DirectoryScope.key(directory)).inserted else { continue }
            let entries = try await fetch(directory)
            try Task.checkCancellation()
            for entry in entries where DirectoryScope.contains(root: root, child: entry.url) {
                if entry.isDirectory {
                    if recursive && !seenFolders.contains(DirectoryScope.key(entry.url)) { pending.append(entry.url) }
                } else if DirectoryScope.isVideo(entry.url), seenFiles.insert(DirectoryScope.key(entry.url)).inserted {
                    result.append(entry)
                }
            }
            progress(result.count)
        }
        return result.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
}
