import Foundation
import Observation

@MainActor @Observable final class RotationItemRecord {
    var value: RotationItemState?
}

@MainActor @Observable final class RotationQueueStore {
    struct Pending: Codable {
        let scope: String
        let request: RotationBatchRequest
    }
    struct Saved: Codable {
        var states: [String: [String: RotationItemState]] = [:]
        var pending: [Pending] = []
    }
    private(set) var batches: [RotationBatch] = []
    private(set) var available = false
    private(set) var error: String?
    private(set) var busy = false
    @ObservationIgnored private var records: [String: RotationItemRecord] = [:]
    @ObservationIgnored private var saved = Saved()
    @ObservationIgnored private var journalValid = true
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var queueScope: String?
    @ObservationIgnored private var stateFlight: [String: Task<[RotationItemState], Error>] = [:]
    private var journal: RecoverableStore<Saved> {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RecoverableStore(file: root.appendingPathComponent("JellyfinRotation/queue-v1.json"))
    }
    private func hydrate() {
        guard !loaded else { return }; loaded = true
        do { saved = try journal.load()?.value ?? Saved() }
        catch { journalValid = false; self.error = "旋转任务的本地记录无法读取，请先保留应用数据并检查服务器任务。" }
    }
    private func scope(_ server: MediaServer) -> String { MediaCache.scope(server) }
    private func key(_ item: String) -> String { item.replacingOccurrences(of: "-", with: "").lowercased() }
    func record(server: MediaServer, itemID: String) -> RotationItemRecord {
        hydrate()
        let scope = scope(server), item = key(itemID), id = scope + ":" + item
        if let record = records[id] { return record }
        let record = RotationItemRecord(); record.value = saved.states[scope]?[item]; records[id] = record
        return record
    }
    func capability(_ server: MediaServer) async throws {
        let value: JellyfinRotationCapability = try await JellyfinRotationClient.request(server: server, path: "Capabilities")
        guard value.available else { throw JellyfinRotationFailure.code(value.reason ?? "permission_denied") }
        guard value.protocolVersion == 1, value.supportsBatchRotation else { throw JellyfinRotationFailure.code("batch_update_required") }
    }
    func refresh(_ server: MediaServer) async {
        guard server.kind == .jellyfin else { return }
        let owner = scope(server)
        if queueScope != owner { queueScope = owner; batches = []; available = false; error = nil }
        do {
            try await capability(server)
            let result: [RotationBatch] = try await JellyfinRotationClient.request(server: server, path: "Batches")
            guard queueScope == owner else { return }
            if batches != result { batches = result }; available = true; error = nil
        } catch { if queueScope == owner { available = false; self.error = error.localizedDescription } }
    }
    func refreshItems(_ server: MediaServer, ids: [String]) async {
        guard server.kind == .jellyfin, !ids.isEmpty else { return }
        let owner = scope(server)
        let unique = Array(Set(ids)).sorted()
        do {
            var result: [RotationItemState] = []
            for start in stride(from: 0, to: unique.count, by: 500) {
                let page = Array(unique[start..<min(start + 500, unique.count)])
                let identity = owner + page.joined(separator: ",")
                let flight: Task<[RotationItemState], Error>
                if let existing = stateFlight[identity] { flight = existing }
                else {
                    flight = Task { try await JellyfinRotationClient.request(server: server, path: "Items/RotationStates", method: "POST", body: JSONEncoder().encode(["itemIds": page])) }
                    stateFlight[identity] = flight
                }
                do { result += try await flight.value; stateFlight[identity] = nil }
                catch { stateFlight[identity] = nil; throw error }
            }
            hydrate()
            var map = saved.states[owner] ?? [:]
            let returned = Dictionary(result.map { (key($0.itemId), $0) }, uniquingKeysWith: { _, last in last })
            var changed = false
            for id in unique {
                let item = key(id), state = returned[item]
                if map[item] != state { map[item] = state; changed = true }
                let record = record(server: server, itemID: id)
                if record.value != state { record.value = state }
            }
            if changed, journalValid { saved.states[owner] = map; try journal.save(saved) }
        } catch { /* Browsing stays usable if an older plugin has no batch API. */ }
    }
    func submit(_ server: MediaServer, videos: [Video], turns: Int, requestID: UUID) async throws -> RotationBatch {
        guard !busy else { throw JellyfinRotationFailure.code("file_busy") }
        busy = true; defer { busy = false }
        hydrate(); guard journalValid else { throw JellyfinRotationFailure.code("journal_unavailable") }; try await capability(server)
        let items = videos.compactMap { video -> RotationBatchItem? in
            guard video.sourceID == server.id, let id = video.remoteID, video.offlineOnly != true, video.streamLinkID == nil else { return nil }
            return RotationBatchItem(itemId: id, title: String(video.title.prefix(512)))
        }
        guard items.count == videos.count, (1...1000).contains(items.count), (1...3).contains(turns) else { throw JellyfinRotationFailure.code("invalid_batch") }
        let owner = scope(server)
        let prior = saved.pending.first { $0.scope == owner }
        let body = prior?.request ?? RotationBatchRequest(requestId: requestID, quarterTurns: turns, items: items)
        // An uncertain POST may only be retried with its original body and identity.
        guard body.quarterTurns == turns, body.items == items else { throw JellyfinRotationFailure.code("batch_pending") }
        if prior == nil { saved.pending.append(Pending(scope: owner, request: body)) }
        // Even a prior in-memory attempt may have failed its first disk write.
        try journal.save(saved)
        let batch: RotationBatch
        do { batch = try await JellyfinRotationClient.request(server: server, path: "Batches", method: "POST", body: JSONEncoder().encode(body)) }
        catch {
            if case JellyfinRotationFailure.code(let code) = error,
               ["invalid_batch", "permission_denied", "file_busy", "queue_full", "request_conflict"].contains(code) {
                try clearPending(owner)
            }
            throw error
        }
        try clearPending(owner)
        await refresh(server); await refreshItems(server, ids: items.map(\.itemId))
        return batch
    }
    private func clearPending(_ owner: String) throws {
        var next = saved
        next.pending.removeAll { $0.scope == owner }
        try journal.save(next)
        saved = next
    }
    func reconcilePending(_ server: MediaServer) async throws {
        hydrate(); guard journalValid else { throw JellyfinRotationFailure.code("journal_unavailable") }; let owner = scope(server)
        guard let pending = saved.pending.first(where: { $0.scope == owner }) else { return }
        try journal.save(saved)
        try await capability(server)
        do {
            let _: RotationBatch = try await JellyfinRotationClient.request(server: server, path: "Batches", method: "POST", body: JSONEncoder().encode(pending.request))
        } catch {
            if case JellyfinRotationFailure.code(let code) = error,
               ["invalid_batch", "permission_denied", "file_busy", "queue_full", "request_conflict"].contains(code) {
                try clearPending(owner)
            }
            throw error
        }
        try clearPending(owner)
        await refresh(server)
    }
    func detail(_ server: MediaServer, id: UUID, includeItems: Bool = true) async throws -> RotationBatch {
        try await JellyfinRotationClient.request(server: server, path: "Batches/\(id.uuidString)", query: ["includeItems": String(includeItems)])
    }
    func change(_ server: MediaServer, batch: UUID, action: String) async throws -> RotationBatch {
        let result: RotationBatch = try await JellyfinRotationClient.request(server: server, path: "Batches/\(batch.uuidString)/\(action)", method: "POST")
        await refresh(server); return result
    }
    func previewURL(server: MediaServer, itemID: String, state: RotationItemState?) -> URL? {
        guard let state, let revision = state.revision, !revision.isEmpty,
              key(state.previewMediaSourceId ?? state.mediaSourceId) == key(itemID) else { return nil }
        return ServerURL.endpoint(server.address, "GlideToolkit/Items/\(itemID)/RotationPreview", query: ["revision": revision])
    }
}
