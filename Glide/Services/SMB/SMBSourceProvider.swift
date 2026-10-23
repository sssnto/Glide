import Foundation
import CryptoKit

struct SMBVerification {
    let server: MediaServer
    let entries: [DAVEntry]
    let fingerprint: Data
    let date = Date()
    func matches(_ candidate: MediaServer, password: String) -> Bool {
        Date().timeIntervalSince(date) < 30 && server.address == candidate.address && server.username == candidate.username
            && server.smb == candidate.smb && fingerprint == Data(SHA256.hash(data: Data(password.utf8)))
    }
}

private actor SMBReadLimiter {
    static let shared = SMBReadLimiter()
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if active < 4 { active += 1; return }
            try await withCheckedThrowingContinuation { waiting.append((id, $0)) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().1.resume() }
    }
}

/// A cancelled operation cannot poison another source's credentials or connection.
final class SMBAccess: @unchecked Sendable {
    let session: GlideSMBSession
    private let lock = NSLock()
    init(server: MediaServer, password: String) throws {
        let location = try SMBLocation(server.address)
        let options = server.smb ?? SMBOptions()
        session = GlideSMBSession(host: location.host, share: location.share,
            user: options.guest ? "Guest" : server.username, password: options.guest ? nil : password,
            domain: options.domain, encrypted: options.encrypted)
    }
    func perform<T: Sendable>(_ work: @escaping @Sendable (GlideSMBSession) throws -> T) async throws -> T {
        try await SMBReadLimiter.shared.acquire()
        defer { Task { await SMBReadLimiter.shared.release() } }
        let operation = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            do {
                let value = try lock.withLock { try Task.checkCancellation(); return try work(session) }
                try Task.checkCancellation(); return value
            }
            catch {
                if error is MediaError { throw error }
                let code = (error as NSError).code
                if code == Int(ECANCELED) || Task.isCancelled { throw CancellationError() }
                throw MediaError.message(SMBFailure.message(code: code))
            }
        }
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { [self] in
            session.cancel(); operation.cancel()
        }
    }
}

@MainActor struct SMBSourceProvider: DirectorySourceProvider {
    private static var initialEntries: [UUID: (URL, [DAVEntry])] = [:]
    static func seed(server: MediaServer, entries: [DAVEntry]) { initialEntries[server.id] = (server.address, entries) }
    static func verify(server: MediaServer, password: String) async throws -> SMBVerification {
        let entries = try await Self.entries(server: server, directory: nil, password: password)
        return SMBVerification(server: server, entries: entries, fingerprint: Data(SHA256.hash(data: Data(password.utf8))))
    }
    private static var browsing: [UUID: (UUID, SMBAccess)] = [:]
    static func cancelBrowsing(sourceID: UUID? = nil) {
        for (_, value) in browsing where sourceID == nil || value.0 == sourceID { value.1.session.cancel() }
    }
    func entries(server: MediaServer, directory: URL?) async throws -> [DAVEntry] {
        if (directory == nil || directory == server.address), let seeded = Self.initialEntries.removeValue(forKey: server.id), seeded.0 == server.address {
            return seeded.1
        }
        return try await Self.entries(server: server, directory: directory, password: Credentials.read(server.id) ?? "", registerBrowse: true)
    }
    static func entries(server: MediaServer, directory: URL?, password: String, registerBrowse: Bool = false) async throws -> [DAVEntry] {
        let root = try SMBLocation(server.address)
        let target = directory ?? server.address
        let path = try root.relativePath(target)
        let location = try SMBLocation(target)
        let access = try SMBAccess(server: server, password: password)
        let id = UUID()
        if registerBrowse { browsing[id] = (server.id, access) }
        defer { browsing[id] = nil }
        return try await access.perform { session in
            let entries = try session.list(path).compactMap { entry -> DAVEntry? in
                guard !entry.name.hasPrefix("."), SMBLocation.validName(entry.name) else { return nil }
                return DAVEntry(url: try location.child(entry.name, directory: entry.directory), name: entry.name,
                    isDirectory: entry.directory, createdAt: entry.created, modifiedAt: entry.modified)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let images = Dictionary(grouping: entries.filter { !$0.isDirectory && ["jpg", "jpeg", "png"].contains($0.url.pathExtension.lowercased()) }, by: { $0.url.deletingPathExtension().lastPathComponent })
            return entries.map { entry in
                var value = entry
                if !entry.isDirectory, DirectoryScope.isVideo(entry.url) {
                    value.artwork = images[entry.url.deletingPathExtension().lastPathComponent]?.first?.url
                }
                return value
            }
        }
    }
    static func playback(video: Video, server: MediaServer) async throws -> PlaybackResource {
        guard let url = video.url else { throw MediaError.message("SMB 视频位置无效。") }
        let path = try SMBLocation(server.address).relativePath(url)
        let password = Credentials.read(server.id) ?? ""
        let access = try SMBAccess(server: server, password: password)
        _ = try await access.perform { try $0.size(path).uint64Value }
        let options = server.smb ?? SMBOptions()
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        // Fixed libsmb2 URL options; never user input or credentials.
        parts.query = options.encrypted ? "timeout=12&seal" : "timeout=12"
        return PlaybackResource(url: parts.url!, smb: SMBPlaybackAccess(username: server.username, password: password, options: options))
    }
    static func image(server: MediaServer, url: URL) async throws -> Data {
        let path = try SMBLocation(server.address).relativePath(url)
        let access = try SMBAccess(server: server, password: Credentials.read(server.id) ?? "")
        return try await access.perform { session in
            let size = try session.size(path).uint64Value
            guard size > 0, size <= 8 * 1024 * 1024 else { throw MediaError.message("预览图片过大或为空。") }
            var result = Data()
            while result.count < size {
                try Task.checkCancellation()
                let bytes = try session.read(path, offset: UInt64(result.count), length: UInt(min(256 * 1024, Int(size) - result.count)))
                guard !bytes.isEmpty else { throw MediaError.message("预览图片读取不完整。") }
                result.append(bytes)
            }
            return result
        }
    }
}

