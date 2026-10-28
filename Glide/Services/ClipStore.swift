import Foundation
import Observation

@MainActor @Observable final class ClipStore {
    static let shared = ClipStore()
    private(set) var snapshot = ClipLibrarySnapshot()
    private(set) var message: String?
    private let file: RecoverableStore<ClipLibrarySnapshot>
    init(url: URL? = nil) {
        var folder = "Clips"
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--glide-clip-fixture") { folder = "ClipsQA" }
#endif
        let path = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(folder + "/clips-v1.json")
        file = RecoverableStore(file: path)
        do {
            if let saved = try file.load() { snapshot = saved.value; if saved.recovered { message = "精彩片段集已从备份恢复。" } }
        } catch { message = "片段资料暂时无法读取，原数据已保留。" }
    }
    func change(_ edit: (inout ClipLibrarySnapshot) throws -> Void) throws {
        var next = try file.load()?.value ?? ClipLibrarySnapshot()
        try edit(&next); try file.save(next); snapshot = next; message = nil
    }
    func save(_ clip: MediaClip, to collectionID: UUID?, newName: String? = nil) throws {
        try change { try $0.save(clip, to: collectionID, newName: newName) }
    }
    func record(collectionID: UUID?, clipID: UUID, position: Double, finished: Bool = false) throws {
        guard let collectionID else { return }
        try change { $0.record(collectionID: collectionID, clipID: clipID, position: position, finished: finished) }
    }
}
