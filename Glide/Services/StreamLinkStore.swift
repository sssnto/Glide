import Foundation
import Observation

@MainActor @Observable final class StreamLinkStore {
    static let shared = StreamLinkStore()
    private(set) var links: [SavedStreamLink] = []
    private(set) var message: String?
    private var snapshot: RecoverableStore<[SavedStreamLink]> {
        RecoverableStore(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StreamLinks/links-v1.json"))
    }
    init() { reload() }
    func reload() {
        do {
            let saved = try snapshot.load()
            links = saved?.value ?? []
            message = saved?.recovered == true ? "链接列表已从备份恢复。" : nil
        } catch { message = "链接列表无法读取，已保留原文件，请勿卸载应用。" }
    }
    func payload(_ id: UUID) throws -> StreamLinkPayload {
        guard links.contains(where: { $0.id == id }), let secret = Credentials.read(id),
              let data = secret.data(using: .utf8), let value = try? JSONDecoder().decode(StreamLinkPayload.self, from: data) else {
            throw MediaError.message("链接已删除或钥匙串记录不可用，请编辑并重新保存。")
        }
        return try value.validated()
    }
    @discardableResult func save(name: String, payload: StreamLinkPayload, replacing: UUID? = nil, keepIdentity: Bool = false) throws -> SavedStreamLink {
        let payload = try payload.validated()
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count <= 200 else { throw MediaError.message("名称请保持在 200 个字符以内。") }
        var values = try snapshot.load()?.value ?? []
        if let replacing, !values.contains(where: { $0.id == replacing }) { throw MediaError.message("原链接已移除，请重新添加。") }
        let id = replacing ?? UUID(), previous = Credentials.read(id)
        let existing = values.first { $0.id == id }
        let previousPayload = previous?.data(using: .utf8).flatMap { try? JSONDecoder().decode(StreamLinkPayload.self, from: $0) }
        let sameMedia = previousPayload == payload || (keepIdentity && existing != nil)
        let record = SavedStreamLink(id: id, name: title.isEmpty ? "视频链接" : title, host: payload.url.host ?? "", createdAt: existing?.createdAt ?? Date(), revision: sameMedia ? existing?.revision : UUID())
        let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        try Credentials.save(encoded, for: id)
        values.removeAll { $0.id == id }; values.insert(record, at: 0)
        do { try snapshot.save(values) }
        catch {
            if let previous { try Credentials.save(previous, for: id) } else { Credentials.delete(id) }
            throw error
        }
        links = values; message = nil
        return record
    }
    func remove(_ record: SavedStreamLink, library: LibraryStore) throws {
        var values = try snapshot.load()?.value ?? []
        values.removeAll { $0.id == record.id }
        try snapshot.save(values)
        links = values; Credentials.delete(record.id)
        library.removeStreamLinkRecords(record.video.id)
        do {
            try SubtitleSource.store.remove(videoID: record.video.id)
            try PlaybackSkipSession.remove(videoID: record.video.id)
        } catch { message = "链接已删除，部分本机字幕或跳过偏好暂未清理。" }
    }
    static func playback(_ video: Video) throws -> PlaybackResource {
        guard let id = video.streamLinkID else { throw MediaError.message("找不到链接标识。") }
        guard shared.links.first(where: { $0.id == id })?.video.id == video.id else { throw MediaError.message("链接内容已更换，请从链接列表重新打开。") }
        let payload = try shared.payload(id)
        return PlaybackResource(url: payload.url, headers: payload.headers, sourcePath: MediaFilePath.display(payload.url.absoluteString))
    }
    static func readSTRM(_ file: URL) async throws -> StreamLinkPayload {
        let task = Task.detached {
            let access = LocalFileAccess(root: file); defer { withExtendedLifetime(access) {} }
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 65_536 else { throw MediaError.message("请选择 64 KB 以内的 STRM 文件。") }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            var data = Data()
            while data.count <= 65_536 {
                try Task.checkCancellation()
                let bytes = try handle.read(upToCount: min(8192, 65_537 - data.count)) ?? Data()
                if bytes.isEmpty { break }
                data.append(bytes)
            }
            return try StreamLinkPayload.strm(data)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
