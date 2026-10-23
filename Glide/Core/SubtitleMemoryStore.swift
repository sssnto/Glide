import Foundation

/// Independent from the library schema; failed reads never overwrite existing memory.
struct SubtitleMemoryStore {
    let directory: URL
    private var store: RecoverableStore<[String: SubtitleMemory]> { RecoverableStore(file: directory.appendingPathComponent("selection-v1.json")) }
    var imports: URL { directory.appendingPathComponent("Imports", isDirectory: true) }
    func load() throws -> (value: [String: SubtitleMemory], recovered: Bool) {
        try store.load() ?? ([:], false)
    }
    func set(_ value: SubtitleMemory?, for key: String) throws {
        var values = try load().value
        if var value { value.delay = value.safeDelay; values[key] = value }
        else { values[key] = nil }
        try store.save(values)
        collectUnusedImports(values)
    }
    func remove(sourceID: UUID) throws {
        let values = try load().value.filter { $0.value.sourceID != sourceID }
        try store.save(values); collectUnusedImports(values)
    }
    func remove(videoID: String) throws {
        let values = try load().value.filter { $0.value.videoID != videoID }
        try store.save(values); collectUnusedImports(values)
    }
    func makeImportedCopy(_ data: Data, extension ext: String) throws -> String {
        guard ["srt", "vtt", "ass", "ssa"].contains(ext.lowercased()), data.count <= SubtitleDocument.maximumBytes else {
            throw MediaError.message("请选择不超过 2 MB 的 SRT／VTT／ASS／SSA 字幕。")
        }
        let name = UUID().uuidString + "." + ext.lowercased()
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: imports.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: imports.appendingPathComponent(name), options: .atomic)
        #endif
        return name
    }
    func importedURL(_ name: String) throws -> URL {
        guard !name.contains("/"), ["srt", "vtt", "ass", "ssa"].contains((name as NSString).pathExtension),
              UUID(uuidString: (name as NSString).deletingPathExtension) != nil else { throw MediaError.message("字幕副本位置无效，请重新导入。") }
        return try LocalMediaIdentity.fileURL(root: imports, relativePath: name)
    }
    private func collectUnusedImports(_ values: [String: SubtitleMemory]) {
        // The recoverable snapshot may still reference the previously selected copy.
        let backup = (try? RecoverableStore<[String: SubtitleMemory]>(file: store.backup).load())?.value ?? [:]
        let entries = Array(values.values) + Array(backup.values)
        let retained = Set(entries.flatMap { [$0.choice.managedFile, $0.importedCopy?.file].compactMap { $0 } })
        for file in (try? FileManager.default.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil)) ?? [] {
            if !retained.contains(file.lastPathComponent), !SubtitleImportLease.contains(file), (try? importedURL(file.lastPathComponent)) != nil { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// A copy awaiting its video's revision must survive collection triggered by the other lane.
final class SubtitleImportLease {
    private static let registry = Registry()
    private let path: String
    init(file: URL) { path = file.standardizedFileURL.path; Self.registry.retain(path) }
    deinit { Self.registry.release(path) }
    static func contains(_ file: URL) -> Bool { registry.contains(file.standardizedFileURL.path) }
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var references: [String: Int] = [:]
        func retain(_ path: String) { lock.lock(); defer { lock.unlock() }; references[path, default: 0] += 1 }
        func release(_ path: String) { lock.lock(); defer { lock.unlock() }; if let count = references[path], count > 1 { references[path] = count - 1 } else { references[path] = nil } }
        func contains(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return references[path, default: 0] > 0 }
    }
}
