import Foundation

struct MediaClip: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var moment: MediaMoment
    var end: Double
    var length: Double { end - moment.position }
    func validated() throws -> Self {
        var result = self
        result.moment = try moment.validated()
        guard end.isFinite, end <= moment.duration, length >= 0.5 else {
            throw MediaError.message("请选择视频内至少 0.5 秒的片段，终点必须晚于起点。")
        }
        if moment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.moment.name = "片段 " + moment.position.mediaTime + "–" + end.mediaTime }
        return result
    }
    func resume(_ position: Double?) -> Double {
        guard let position, position.isFinite, position >= moment.position, position < end - 0.1 else { return moment.position }
        return position
    }
}

struct ClipCollection: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var clipIDs: [UUID] = []
    var coverID: UUID?
    var cursor: ClipCursor?
}
struct ClipCursor: Codable, Equatable, Sendable {
    var clipID: UUID
    var position: Double
    var finished = false
}
struct ClipLibrarySnapshot: Codable, Equatable, Sendable {
    var clips: [MediaClip] = []
    var collections: [ClipCollection] = []
    func entries(_ collection: ClipCollection) -> [MediaClip] {
        let lookup = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        return collection.clipIDs.compactMap { lookup[$0] }
    }
    mutating func save(_ clip: MediaClip, to collectionID: UUID?, newName: String? = nil) throws {
        let clip = try clip.validated()
        var target = collectionID
        if let newName {
            let name = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !name.isEmpty, collections.count < 100 else { throw MediaError.message("请填写合集名称，最多保存 100 个合集。") }
            let collection = ClipCollection(name: name); collections.insert(collection, at: 0); target = collection.id
        }
        if let target, !collections.contains(where: { $0.id == target }) { throw MediaError.message("合集已删除，请重新选择。") }
        if let i = clips.firstIndex(where: { $0.id == clip.id }) { clips[i] = clip }
        else {
            guard clips.count < 1000 else { throw MediaError.message("最多保存 1000 个片段，请先整理已有内容。") }
            clips.insert(clip, at: 0)
        }
        if let i = collections.firstIndex(where: { $0.id == target }), !collections[i].clipIDs.contains(clip.id) {
            guard collections[i].clipIDs.count < 100 else { throw MediaError.message("每个合集最多 100 个片段。") }
            collections[i].clipIDs.append(clip.id)
        }
    }
    mutating func removeClip(_ id: UUID) {
        clips.removeAll { $0.id == id }
        for i in collections.indices {
            collections[i].clipIDs.removeAll { $0 == id }
            if collections[i].coverID == id { collections[i].coverID = nil }
            if collections[i].cursor?.clipID == id { collections[i].cursor = nil }
        }
    }
    mutating func update(_ collection: ClipCollection) throws {
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else { throw MediaError.message("合集已删除。") }
        var value = collection
        value.name = String(value.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let valid = Set(clips.map(\.id))
        guard !value.name.isEmpty, value.clipIDs.count <= 100, Set(value.clipIDs).count == value.clipIDs.count,
              value.clipIDs.allSatisfy({ valid.contains($0) }) else { throw MediaError.message("合集名称或片段列表无效。") }
        if let cover = value.coverID, !value.clipIDs.contains(cover) { value.coverID = nil }
        if let cursor = value.cursor, !value.clipIDs.contains(cursor.clipID) { value.cursor = nil }
        collections[index] = value
    }
    mutating func record(collectionID: UUID, clipID: UUID, position: Double, finished: Bool) {
        guard position.isFinite, let i = collections.firstIndex(where: { $0.id == collectionID }),
              collections[i].clipIDs.contains(clipID), let clip = clips.first(where: { $0.id == clipID }) else { return }
        collections[i].cursor = ClipCursor(clipID: clipID, position: max(clip.moment.position, min(position, clip.end)), finished: finished)
    }
}
