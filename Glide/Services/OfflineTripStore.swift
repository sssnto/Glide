import Foundation
import Observation

@MainActor @Observable final class OfflineTripStore {
    static let shared = OfflineTripStore()
    private(set) var trips: [OfflineTrip] = []
    private(set) var message: String?
    private(set) var preparing = Set<UUID>()
    private(set) var preparationMessages: [UUID: [String]] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    private let store: RecoverableStore<[OfflineTrip]>
    init(file: URL? = nil) {
        store = RecoverableStore(file: file ?? DownloadStore.directory.appendingPathComponent("trips-v1.json"))
        do { trips = try store.load()?.value ?? [] }
        catch { message = "行程包暂时无法读取，已保留原文件。" }
    }
    func save(_ trip: OfflineTrip) throws {
        let trip = try trip.validated()
        var values = try store.load()?.value ?? []
        if let index = values.firstIndex(where: { $0.id == trip.id }) { values[index] = trip }
        else {
            guard values.count < 30 else { throw MediaError.message("最多保存 30 个行程包。") }
            values.append(trip)
        }
        try store.save(values); trips = values; message = nil
    }
    func remove(_ id: UUID, includingFiles: Bool) throws {
        guard !preparing.contains(id) else { throw MediaError.message("请先停止准备，再清理行程包。") }
        guard let trip = trips.first(where: { $0.id == id }) else { return }
        let values = trips.filter { $0.id != id }
        try store.save(values); trips = values
        if includingFiles {
            let shared = Set(values.flatMap(\.videoIDs))
            trip.videoIDs.filter { !shared.contains($0) }.forEach { DownloadStore.shared.remove($0) }
        }
    }
    func start(_ trip: OfflineTrip, library: LibraryStore) {
        guard !preparing.contains(trip.id) else { return }
        preparing.insert(trip.id)
        tasks[trip.id] = Task {
            let errors = await queue(trip, library: library)
            preparationMessages[trip.id] = errors; preparing.remove(trip.id); tasks[trip.id] = nil
        }
    }
    func stop(_ id: UUID) { tasks[id]?.cancel() }
    func queue(_ trip: OfflineTrip, library: LibraryStore) async -> [String] {
        var errors = [String]()
        for video in trip.videos {
            if Task.isCancelled { errors.append("准备已停止，已加入的下载保留在队列中。"); break }
            if let entry = DownloadStore.shared.entries.first(where: { $0.id == video.id }), DownloadStore.shared.localURL(videoID: video.id) != nil {
                if let binding = entry.accountBinding, trip.accountBindings[video.id] != binding { errors.append(video.title + "：本机副本属于其他账号，请重新生成候选。") }
                continue
            }
            do {
                let used = DownloadStore.shared.entries.filter { trip.videoIDs.contains($0.id) && $0.id != video.id }.reduce(Int64(0)) { $0 + ($1.expectedBytes ?? 0) + ($1.companionBytes ?? 0) }
                let available = trip.maximumBytes - used
                if video.demoIndex != nil {
                    var local = video; local.url = Bundle.main.url(forResource: "demo\(video.demoIndex!)", withExtension: "mp4")
                    try await DownloadStore.shared.keepLocal(local, server: nil, expectedBytes: trip.expectedSizes[video.id], maximumBytes: available)
                    continue
                }
                guard let server = library.servers.first(where: { $0.id == video.sourceID }) else { throw MediaError.message("请重新连接原来源。") }
                guard trip.accountBindings[video.id] == (try SubtitleSource.key(video: video, server: server)) else { throw MediaError.message("来源账号已变化，请重新生成候选。") }
                if server.kind == .local { try await DownloadStore.shared.keepLocal(video, server: server, expectedBytes: trip.expectedSizes[video.id], maximumBytes: available) }
                else {
                    guard server.kind.isCatalogSource, let remoteID = video.remoteID else { throw MediaError.message("此来源暂不支持行程下载。") }
                    let item = try await MediaClient.shared.catalogDetail(server: server, id: remoteID, refresh: true)
                    guard item.MediaSources?.first?.Size == trip.expectedSizes[video.id] else { throw MediaError.message("原文件大小已变化，请重新生成候选。") }
                    if let expected = trip.sourceVersions[video.id], item.MediaSources?.first?.Id != expected { throw MediaError.message("原文件版本已变化，请重新生成候选。") }
                    try await DownloadStore.shared.enqueue(item: item, server: server, sourceID: item.MediaSources?.first?.Id, maximumBytes: available)
                }
            } catch { errors.append(video.title + "：" + error.localizedDescription) }
        }
        return errors
    }
}

@MainActor enum OfflineTripResolver {
    struct Result {
        var candidates: [OfflineTripCandidate]
        var bindings: [String: String]
        var notices: [String]
    }
    static func candidates(scopes: [DiscoveryScope], channel: PrivateChannel?, library: LibraryStore, progress: (Int) -> Void) async throws -> Result {
        for scope in scopes where scope.kind != .demo {
            let server = try DiscoveryResolver.server(scope, library: library)
            guard server.kind.isCatalogSource || server.kind == .local else { throw MediaError.message("本版支持本地、Jellyfin 和 Emby 行程包，请调整内容范围。") }
        }
        let batches = try await DiscoveryResolver.batches(scopes, library: library, readDurations: true, progress: progress)
        let channel = channel ?? PrivateChannel(name: "行程", scopes: scopes, unwatchedOnly: true, avoidRecent: false)
        let queue = ChannelPlanner.queue(batches, channel: channel, positions: library.positions)
        var result = Result(candidates: [], bindings: [:], notices: [])
        if queue.count > 200 { result.notices.append("本次只检查前 200 个候选；可缩小范围选择其他内容。") }
        for video in queue.prefix(200) {
            try Task.checkCancellation(); progress(result.candidates.count)
            do {
                var video = video
                video.resume = library.resumePosition(video)
                let size: Int64
                var fileBytes: Int64?, version: String?
                if let saved = DownloadStore.shared.entries.first(where: { $0.id == video.id && $0.state == "已完成" }),
                   DownloadStore.shared.localURL(videoID: video.id) != nil {
                    if let server = library.servers.first(where: { $0.id == video.sourceID }), let binding = saved.accountBinding,
                       binding != (try SubtitleSource.key(video: video, server: server)) { throw MediaError.message("本机副本属于原账号，请切回原账号或清理旧副本。") }
                    size = (saved.expectedBytes ?? 0) + (saved.companionBytes ?? 0)
                    fileBytes = saved.expectedBytes; version = saved.source?.Id
                }
                else if video.demoIndex != nil, let url = video.url { size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
                else {
                    guard let server = library.servers.first(where: { $0.id == video.sourceID }) else { throw MediaError.message("原来源已移除。") }
                    if server.kind == .local {
                        let resource = try LocalMediaStore.playback(video, server: server)
                        size = Int64(try resource.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                        withExtendedLifetime(resource.localAccess) {}
                    } else {
                        guard let id = video.remoteID else { throw MediaError.message("缺少远程视频标识。") }
                        let detail = try await MediaClient.shared.catalogDetail(server: server, id: id)
                        guard let source = detail.MediaSources?.first, ["mp4", "mov", "m4v", "mkv"].contains(source.Container?.lowercased() ?? ""), let bytes = source.Size, bytes > 0 else {
                            throw MediaError.message("封装尚不支持或缺少可靠大小。")
                        }
                        size = bytes
                        fileBytes = bytes; version = source.Id
                        if video.duration <= 0 { video.duration = detail.video(server: server).duration }
                    }
                }
                if let server = library.servers.first(where: { $0.id == video.sourceID }) { result.bindings[video.id] = try SubtitleSource.key(video: video, server: server) }
                guard size > 0, video.duration.isFinite, video.duration > 0 else { throw MediaError.message("缺少可靠片长或文件大小。") }
                result.candidates.append(.init(video: video, bytes: size, alreadySaved: DownloadStore.shared.localURL(videoID: video.id) != nil, fileBytes: fileBytes, sourceVersionID: version))
            } catch {
                if Task.isCancelled { throw CancellationError() }
                result.notices.append(video.title + "：" + error.localizedDescription)
                // Keep an unavailable episode as a barrier so later episodes
                // cannot silently leapfrog it in either planning mode.
                result.candidates.append(.init(video: video, bytes: 0))
            }
        }
        return result
    }
}
