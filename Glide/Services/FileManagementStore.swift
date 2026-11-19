import Foundation
import Observation

struct FileManagementClient {
    private struct Failure: Decodable { let errorCode: String }
    let server: MediaServer
    func request<T: Decodable>(_ path: String, query: [String: String] = [:], method: String = "GET", body: Data? = nil) async throws -> T {
        guard server.kind == .jellyfin, let token = Credentials.read(server.id) else { throw FileManagementFailure("permission_denied") }
        let url = ServerURL.endpoint(server.address, "GlideToolkit/FileManagement/" + path, query: query)
        var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = 30
        request.setValue(MediaClient.shared.authorization(token, server: server), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await MediaClient.shared.session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count < 2_000_000 else { throw FileManagementFailure("invalid_response") }
        if !(200..<300).contains(http.statusCode) {
            throw FileManagementFailure((try? JSONDecoder().decode(Failure.self, from: data))?.errorCode ?? ([404, 405].contains(http.statusCode) ? "plugin_missing" : "permission_denied"))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func capability() async throws -> FileManagementCapability {
        let capability: FileManagementCapability = try await request("Capabilities")
        guard capability.protocolVersion == 1, capability.softDelete else { throw FileManagementFailure("protocol_unsupported") }
        guard capability.available else { throw FileManagementFailure("file_management_disabled") }
        guard capability.ready else { throw FileManagementFailure("server_preparing") }
        return capability
    }
    func inspect(_ videos: [Video]) async throws -> [FileActionInspection] {
        guard !videos.isEmpty, videos.count <= 500 else { throw FileManagementFailure("invalid_batch") }
        struct Body: Encodable { let itemIds: [String] }
        return try await request("Inspect", method: "POST", body: JSONEncoder().encode(Body(itemIds: videos.compactMap(\.remoteID))))
    }
    func folders(_ parent: String? = nil, start: Int = 0) async throws -> FileFolderPage {
        var query = ["start": String(start)]; query["parent"] = parent
        return try await request("Folders", query: query)
    }
}

@MainActor @Observable final class FileManagementStore {
    struct Pending: Codable { let sourceID: UUID; let userID: String; let request: FileActionRequest }
    struct Journal: Codable { var pending: [Pending] = [] }
    private let journal: RecoverableStore<Journal>
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        journal = RecoverableStore(file: root.appendingPathComponent("FileManagement/pending-v1.json"))
    }
    func pending(_ server: MediaServer) throws -> Pending? {
        try journal.load()?.value.pending.first { $0.sourceID == server.id && $0.userID == server.userID }
    }
    func submit(_ request: FileActionRequest, server: MediaServer) async throws -> FileActionBatch {
        try request.validate()
        _ = try await FileManagementClient(server: server).capability()
        var state = try journal.load()?.value ?? Journal()
        if let old = try pending(server), old.request != request { throw FileManagementFailure("pending_submission") }
        state.pending.removeAll { $0.sourceID == server.id && $0.userID == server.userID }
        state.pending.append(Pending(sourceID: server.id, userID: server.userID ?? "", request: request))
        try journal.save(state)
        do {
            let result: FileActionBatch = try await FileManagementClient(server: server).request("Batches", method: "POST", body: JSONEncoder().encode(request))
            try clearPending(server); return result
        } catch let error as FileManagementFailure {
            // These errors are rejected before the server persists a new batch.
            // Transport failures and storage errors retain the exact request for reconciliation.
            if ["invalid_batch", "file_management_disabled", "permission_denied", "file_changed", "same_library_required", "same_directory", "queue_full", "version_selection_required", "home_video_only", "restore_conflict", "shared_sidecar", "invalid_item", "item_missing", "file_missing", "outside_library", "invalid_folder", "destination_not_writable", "file_busy", "unsupported_format", "symbolic_link", "reserved_path", "too_many_sidecars", "directory_too_large"].contains(error.code) { try clearPending(server) }
            throw error
        }
    }
    private func clearPending(_ server: MediaServer) throws {
        var state = try journal.load()?.value ?? Journal()
        state.pending.removeAll { $0.sourceID == server.id && $0.userID == server.userID }; try journal.save(state)
    }
    func list(_ server: MediaServer) async throws -> [FileActionBatch] { try await FileManagementClient(server: server).request("Batches") }
    func detail(_ id: UUID, server: MediaServer) async throws -> FileActionBatch { try await FileManagementClient(server: server).request("Batches/\(id.uuidString)") }
    func change(_ command: String, batch: UUID, server: MediaServer) async throws -> FileActionBatch {
        try await FileManagementClient(server: server).request("Batches/\(batch.uuidString)/\(command)", method: "POST")
    }
}
