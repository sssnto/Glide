import Foundation
import Observation

@MainActor @Observable final class MomentStore {
    static let shared = MomentStore()
    private(set) var moments: [MediaMoment] = []
    private(set) var message: String?
    private let store: RecoverableStore<[MediaMoment]>
    init(file: URL? = nil) {
        var folder = "Moments"
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--glide-map-fixture") {
            folder = "MomentsUIQA"
        }
#endif
        let path = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(folder + "/moments-v1.json")
#if DEBUG
        if file == nil, folder == "MomentsUIQA", ProcessInfo.processInfo.arguments.contains("--glide-map-reset") {
            try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: path.appendingPathExtension("backup"))
        }
#endif
        store = RecoverableStore(file: path)
        do {
            if let saved = try store.load() { moments = saved.value; if saved.recovered { message = "时刻收藏已从备份恢复。" } }
        } catch { message = "时刻收藏暂时无法读取，已保留原文件。" }
    }
    func save(_ moment: MediaMoment) throws {
        let moment = try moment.validated()
        var values = try store.load()?.value ?? []
        if let index = values.firstIndex(where: { $0.id == moment.id }) { values[index] = moment }
        else {
            guard values.count < 1000 else { throw MediaError.message("最多保存 1000 个时刻，请先整理已有收藏。") }
            values.insert(moment, at: 0)
        }
        try store.save(values); moments = values; message = nil
    }
    func remove(_ id: UUID) throws {
        var values = try store.load()?.value ?? []
        values.removeAll { $0.id == id }; try store.save(values); moments = values; message = nil
    }
}
