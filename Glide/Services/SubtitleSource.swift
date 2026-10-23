import Foundation
import CryptoKit

struct SubtitleCatalog: Sendable {
    var revision: SubtitleRevision?
    var candidates: [SidecarSubtitle]
}

@MainActor enum SubtitleSource {
    static var store: SubtitleMemoryStore {
        SubtitleMemoryStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Subtitles", isDirectory: true))
    }
    static func key(video: Video, server: MediaServer?) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(SubtitleIdentity(video: video, server: server)))
    }
    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func supportsDiscovery(_ server: MediaServer?) -> Bool { server?.kind == .local || server?.kind == .smb }

    static func catalog(video: Video, server: MediaServer?) async throws -> SubtitleCatalog {
        guard let server else { return SubtitleCatalog(revision: nil, candidates: []) }
        if server.kind == .local {
            let resource = try LocalMediaStore.playback(video, server: server)
            let file = resource.url
            guard let access = resource.localAccess else { throw MediaError.message("本地目录授权无效。") }
            let operation = Task.detached {
                defer { withExtendedLifetime(access) {} }
                try Task.checkCancellation()
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let entries = try LocalDirectoryIndex.entries(root: access.root, directory: file.deletingLastPathComponent())
                let candidates = entries.filter { !$0.isDirectory }.compactMap { SidecarSubtitleMatch.candidate(videoName: file.lastPathComponent, url: $0.url) }
                return SubtitleCatalog(revision: SubtitleRevision(size: UInt64(max(0, values.fileSize ?? 0)), modified: values.contentModificationDate), candidates: candidates)
            }
            return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
        }
        if server.kind == .smb {
            guard let file = video.url else { throw MediaError.message("找不到视频位置。") }
            let root = try SMBLocation(server.address), parent = try SMBLocation(file.deletingLastPathComponent())
            let path = try root.relativePath(file.deletingLastPathComponent())
            let access = try SMBAccess(server: server, password: Credentials.read(server.id) ?? "")
            return try await access.perform { session in
                let entries = try session.list(path)
                guard let media = entries.first(where: { !$0.directory && $0.name == file.lastPathComponent }) else { throw MediaError.message("视频文件已移动或删除，无法恢复字幕记忆。") }
                let candidates = try entries.filter { !$0.directory && SMBLocation.validName($0.name) }.compactMap { entry in
                    SidecarSubtitleMatch.candidate(videoName: file.lastPathComponent, url: try parent.child(entry.name, directory: false))
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return SubtitleCatalog(revision: SubtitleRevision(size: media.size, modified: media.modified), candidates: candidates)
            }
        }
        return SubtitleCatalog(revision: nil, candidates: [])
    }

    static func read(_ candidate: SidecarSubtitle, video: Video, server: MediaServer) async throws -> Data {
        guard !candidate.name.contains("/"), ["srt", "vtt", "ass", "ssa"].contains((candidate.name as NSString).pathExtension.lowercased()) else {
            throw MediaError.message("字幕文件位置无效。")
        }
        if server.kind == .local {
            let resource = try LocalMediaStore.playback(video, server: server)
            guard let access = resource.localAccess else { throw MediaError.message("本地目录授权无效。") }
            let parent = resource.url.deletingLastPathComponent()
            let file = try LocalMediaIdentity.fileURL(root: parent, relativePath: candidate.name)
            let operation = Task.detached {
                defer { withExtendedLifetime(access) {} }
                try Task.checkCancellation()
                return try readFile(file)
            }
            return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
        }
        guard server.kind == .smb, let media = video.url, candidate.url.deletingLastPathComponent() == media.deletingLastPathComponent() else {
            throw MediaError.message("字幕超出了当前视频目录。")
        }
        let path = try SMBLocation(server.address).relativePath(candidate.url)
        let access = try SMBAccess(server: server, password: Credentials.read(server.id) ?? "")
        return try await access.perform { session in
            let size = try session.size(path).uint64Value
            guard size <= SubtitleDocument.maximumBytes else { throw MediaError.message("字幕文件超过 2 MB，请使用较小的 SRT／VTT／ASS／SSA 文件。") }
            var data = Data()
            while data.count <= SubtitleDocument.maximumBytes {
                try Task.checkCancellation()
                let bytes = try session.read(path, offset: UInt64(data.count), length: UInt(min(64 * 1024, SubtitleDocument.maximumBytes + 1 - data.count)))
                if bytes.isEmpty { break }
                data.append(bytes)
            }
            guard data.count <= SubtitleDocument.maximumBytes else { throw MediaError.message("字幕文件超过 2 MB，请使用较小的 SRT／VTT／ASS／SSA 文件。") }
            return data
        }
    }

    nonisolated static func readFile(_ file: URL) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw MediaError.message("请选择原始字幕文件。") }
        guard (values.fileSize ?? 0) <= SubtitleDocument.maximumBytes else { throw MediaError.message("字幕文件超过 2 MB，请使用较小的 SRT／VTT／ASS／SSA 文件。") }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var data = Data()
        while data.count <= SubtitleDocument.maximumBytes {
            try Task.checkCancellation()
            let bytes = try handle.read(upToCount: min(64 * 1024, SubtitleDocument.maximumBytes + 1 - data.count)) ?? Data()
            if bytes.isEmpty { break }
            data.append(bytes)
        }
        guard data.count <= SubtitleDocument.maximumBytes else { throw MediaError.message("字幕文件超过 2 MB，请使用较小的 SRT／VTT／ASS／SSA 文件。") }
        return data
    }
    nonisolated static func document(_ data: Data, assText: Bool = false) async throws -> (cues: [SubtitleCue], digest: String, ass: ASSSubtitle?) {
        let operation = Task.detached {
            try Task.checkCancellation()
            if ASSDocument.recognizes(data) {
                let document = try ASSDocument.parse(data)
                return (document.cues, digest(data), Optional(ASSSubtitle(document: document)))
            }
            return (try SubtitleDocument.parse(data, assText: assText), digest(data), Optional<ASSSubtitle>.none)
        }
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
}
