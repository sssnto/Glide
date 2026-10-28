import Foundation
import Observation
import UIKit
import BackgroundTasks
import AVFoundation

struct OfflineDownload: Codable, Identifiable {
    var id: String { video.id }
    var video: Video
    var serverID: UUID
    var filename: String
    var state: String = "下载中"
    var progress: Double = 0
    var message: String?
    var expectedBytes: Int64?
    var artworkData: Data? = nil
    var overview: String? = nil
    var source: CatalogItem.Source? = nil
    var accountBinding: String? = nil
    var subtitles: [OfflineSubtitleAsset]? = nil
    var resourceWarnings: [String]? = nil
    var playbackCheck: OfflinePlaybackCheck? = nil
    var companionBytes: Int64? = nil
    var maximumBytes: Int64? = nil
    var chapters: [NavigationChapter]? = nil
    var checkedIssues: [String]? = nil
    var originAccountID: String? = nil
    var providerIDs: [String: String]? = nil
    var productionYear: Int? = nil
}

@MainActor @Observable
final class DownloadStore: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadStore()
    static let sessionID = "com.songpeng.glide.downloads.v1"
    static let maintenanceID = "com.songpeng.glide.download-maintenance"
    private(set) var entries: [OfflineDownload] = []
    private(set) var storageError: String?
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var scheduling = false
    @ObservationIgnored private var validations: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var preparing = Set<String>()
    @ObservationIgnored private var canPersist = true
    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    nonisolated static var directory: URL {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--glide-clip-fixture") { return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineClipsQA", isDirectory: true) }
        if ProcessInfo.processInfo.arguments.contains("--glide-unified-fixture") {
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineUnifiedQA", isDirectory: true)
        }
#endif
        let name = ProcessInfo.processInfo.arguments.contains("--glide-trip-fixture") ? "OfflineTravelQA" : "OfflineMedia"
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
    }
    private nonisolated static var files: OfflineMediaFiles { OfflineMediaFiles(directory: directory) }
    private static var manifest: URL { directory.appendingPathComponent("manifest.json") }
    private static var snapshot: RecoverableStore<[OfflineDownload]> { RecoverableStore(file: directory.appendingPathComponent("downloads-v2.json")) }
    override private init() {
        super.init()
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var folder = Self.directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? folder.setResourceValues(values)
        do {
            if let saved = try Self.snapshot.load() { entries = saved.value }
            else if FileManager.default.fileExists(atPath: Self.manifest.path) {
                entries = try JSONDecoder().decode([OfflineDownload].self, from: Data(contentsOf: Self.manifest))
                try Self.snapshot.save(entries)
            }
            guard entries.allSatisfy({ OfflineMediaFiles.validFilename($0.filename) && ($0.expectedBytes ?? 0) >= 0 }) else { throw MediaError.message("离线记录存在无效文件位置。") }
        } catch { entries = []; canPersist = false; storageError = "离线记录暂时无法读取，已保留原文件：" + error.localizedDescription }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        Task { await reconcile() }
    }
    func enqueue(item: CatalogItem, server: MediaServer, sourceID: String?, maximumBytes: Int64? = nil) async throws {
        guard storageError == nil else { throw MediaError.message(storageError!) }
        let video = item.video(server: server)
        let binding = try SubtitleSource.key(video: video, server: server)
        if let saved = entries.first(where: { $0.id == video.id && ["准备资料", "等待下载", "下载中", "已暂停", "校验中", "已完成"].contains($0.state) }) {
            guard saved.accountBinding == nil || saved.accountBinding == binding else { throw MediaError.message("下载属于原账号，请清理旧副本或切回原账号。") }
            return
        }
        guard let source = item.MediaSources?.first, sourceID == nil || sourceID == source.Id else { throw MediaError.message("离线下载暂支持默认媒体版本。") }
        let ext = source.Container?.lowercased() ?? ""
        guard ["mp4", "mov", "m4v", "mkv"].contains(ext) else { throw MediaError.message("离线下载支持 MP4 / MOV / M4V / MKV 原文件。") }
        guard let size = source.Size, size > 0 else { throw MediaError.message("服务器未提供可靠文件大小，暂不能纳入离线容量预算。") }
        if let maximumBytes, size > maximumBytes { throw MediaError.message("此文件超过行程包剩余容量。") }
        guard let token = Credentials.read(server.id), let remoteID = video.remoteID else { throw MediaError.message("请重新登录。") }
        guard size <= PlaybackPreferences.downloadLimit - allocatedBytes else { throw MediaError.message("超过离线容量预算，请清理下载或在设置中调整。") }
        guard physicalSpaceAllows(size, excluding: video.id) else { throw MediaError.message("设备剩余空间不足，已为待完成下载预留空间，请先清理存储。") }
        var request = URLRequest(url: ServerURL.endpoint(server.address, "Items/\(remoteID)/Download"))
        request.setValue(MediaClient.shared.authorization(token, server: server), forHTTPHeaderField: "Authorization")
        request.allowsCellularAccess = !PlaybackPreferences.downloadWiFiOnly
        request.allowsExpensiveNetworkAccess = !PlaybackPreferences.downloadWiFiOnly
        let filename = UUID().uuidString + "." + ext
        if let previous = entries.first(where: { $0.id == video.id }) {
            validations[previous.filename]?.cancel()
            Self.files.remove(previous.filename)
        }
        entries.removeAll { $0.id == video.id }
        var safeSource = source; safeSource.Path = nil
        entries.append(OfflineDownload(video: PersonalVideo(video: video).video, serverID: server.id, filename: filename, state: "准备资料", expectedBytes: size, overview: item.Overview, source: safeSource, accountBinding: binding, maximumBytes: maximumBytes))
        persist()
        preparing.insert(filename)
        defer { preparing.remove(filename) }
        let companions = await prepareCompanions(item: item, server: server, filename: filename)
        let metadata = try? await MediaClient.shared.navigationMetadata(video: video, server: server)
        guard let index = entries.firstIndex(where: { $0.filename == filename }) else { OfflineCompanions.remove(filename); return }
        entries[index].subtitles = companions.assets; entries[index].resourceWarnings = companions.warnings
        entries[index].chapters = metadata?.chapters(sourceID: source.Id, duration: video.duration) ?? []
        entries[index].originAccountID = server.userID ?? server.username
        entries[index].providerIDs = item.ProviderIds; entries[index].productionYear = item.ProductionYear
        entries[index].companionBytes = OfflineCompanions.bytes(filename)
        guard !Task.isCancelled else { entries[index].state = "已中断"; entries[index].message = "资料准备已停止，请重新准备后重试。"; persist(); return }
        guard resourcesFit(entries[index]), maximumBytes.map({ size <= $0 - (entries[index].companionBytes ?? 0) }) ?? true else {
            OfflineCompanions.remove(filename); entries[index].companionBytes = 0; entries[index].subtitles = nil
            entries[index].state = "下载失败"; entries[index].message = "配套资料超过离线容量预算，请清理后重试。"; persist(); return
        }
        entries[index].state = "等待下载"; persist()
        let task = session.downloadTask(with: request); task.taskDescription = filename
        await advanceQueue()
        Task {
            if let url = video.artwork, let image = try? await ArtworkCache.shared.image(server: server, url: url, pixels: 320),
               let data = image.jpegData(compressionQuality: 0.8), data.count < 1_000_000,
               let index = self.entries.firstIndex(where: { $0.filename == filename }) {
                self.entries[index].artworkData = data; self.persist()
            }
        }
        scheduleMaintenance()
    }
    func localURL(videoID: String) -> URL? {
        guard let item = entries.first(where: { $0.id == videoID && $0.state == "已完成" }) else { return nil }
        let url = Self.directory.appendingPathComponent(item.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func canReuse(videoID: String, sourceID: String?) -> Bool {
        guard let entry = entries.first(where: { $0.id == videoID }) else { return false }
        return UnifiedLibraryGrouping.canReuseDownload(savedSourceID: entry.source?.Id, requestedSourceID: sourceID)
    }
    func pause(_ id: String) async {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let tasks = await session.allTasks
        guard let index = entries.firstIndex(where: { $0.filename == entry.filename && ["等待下载", "下载中"].contains($0.state) }) else { return }
        for task in tasks where task.taskDescription == entry.filename { task.suspend() }
        entries[index].state = "已暂停"; persist(); await advanceQueue()
    }
    func resume(_ id: String, library: LibraryStore) async {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let tasks = await session.allTasks
        guard let index = entries.firstIndex(where: { $0.filename == entry.filename }) else { return }
        guard ["已暂停", "下载失败", "已中断", "文件已移除"].contains(entries[index].state) else { return }
        if validations[entry.filename] != nil { return }
        if FileManager.default.fileExists(atPath: Self.files.pendingURL(entry.filename).path) {
            beginValidation(entry.filename); return
        }
        guard physicalSpaceAllows(entry.expectedBytes ?? 0, excluding: entry.id) else {
            entries[index].message = "设备剩余空间不足，已为其他待完成下载预留空间。"; persist(); return
        }
        if let task = tasks.first(where: { $0.taskDescription == entry.filename && ($0.state == .suspended || $0.state == .running) }) {
            entries[index].state = "等待下载"; entries[index].message = nil; task.suspend(); entries.append(entries.remove(at: index)); persist(); await advanceQueue(); return
        }
        guard let server = library.servers.first(where: { $0.id == entry.serverID }), let remoteID = entry.video.remoteID, let token = Credentials.read(server.id) else {
            entries[index].state = "下载失败"; entries[index].message = "请先重新登录此媒体来源。"; persist(); return
        }
        do {
            let binding = try SubtitleSource.key(video: entry.video, server: server)
            guard entry.accountBinding == nil || entry.accountBinding == binding else { throw MediaError.message("来源账号或地址已变化，请清理旧副本后重新下载。") }
            let detail = try await MediaClient.shared.catalogDetail(server: server, id: remoteID, refresh: true)
            if let saved = entry.source {
                guard let source = detail.MediaSources?.first, source.Id == saved.Id, source.Size == entry.expectedBytes, source.Container?.lowercased() == saved.Container?.lowercased() else { throw MediaError.message("源文件版本已变化，请重新创建下载。") }
            }
            guard entries.contains(where: { $0.filename == entry.filename }) else { return }
        } catch {
            if let current = entries.firstIndex(where: { $0.filename == entry.filename }) { entries[current].message = error.localizedDescription; persist() }
            return
        }
        if entry.subtitles == nil {
            do { try await refreshCompanions(entry.id, library: library) }
            catch {
                if let current = entries.firstIndex(where: { $0.filename == entry.filename }) { entries[current].message = error.localizedDescription; persist() }
                return
            }
        }
        guard let index = entries.firstIndex(where: { $0.filename == entry.filename }) else { return }
        var request = URLRequest(url: ServerURL.endpoint(server.address, "Items/\(remoteID)/Download"))
        request.setValue(MediaClient.shared.authorization(token, server: server), forHTTPHeaderField: "Authorization")
        request.allowsCellularAccess = !PlaybackPreferences.downloadWiFiOnly
        request.allowsExpensiveNetworkAccess = !PlaybackPreferences.downloadWiFiOnly
        // Give retries a new identity so late callbacks cannot overwrite the new transfer.
        let filename = UUID().uuidString + "." + (entry.filename as NSString).pathExtension
        Self.files.remove(entry.filename)
        let oldAssets = OfflineCompanions.directory(entry.filename), newAssets = OfflineCompanions.directory(filename)
        if FileManager.default.fileExists(atPath: oldAssets.path) { try? FileManager.default.moveItem(at: oldAssets, to: newAssets) }
        entries[index].filename = filename; entries[index].playbackCheck = nil
        entries[index].state = "等待下载"; entries[index].progress = 0; entries[index].message = "正在重新下载。"
        entries.append(entries.remove(at: index))
        let task = session.downloadTask(with: request); task.taskDescription = filename; persist(); await advanceQueue()
    }
    func remove(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }; persist()
        validations[entry.filename]?.cancel()
        Self.files.remove(entry.filename)
        OfflineCompanions.remove(entry.filename)
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == entry.filename }.forEach { $0.cancel() }
            Task { @MainActor in await self.advanceQueue() }
        }
    }
    func removeServer(_ id: UUID, includingCompleted: Bool = false) {
        entries.filter { $0.serverID == id && (includingCompleted || $0.state != "已完成") }.map(\.id).forEach(remove)
    }
    var allocatedBytes: Int64 { entries.reduce(0) { $0 + ($1.expectedBytes ?? 0) + ($1.companionBytes ?? 0) } }
    private func advanceQueue() async {
        guard !scheduling else { return }; scheduling = true
        defer { scheduling = false }
        let tasks = await session.allTasks
        let active = Set(entries.filter { $0.state == "下载中" }.map(\.filename))
        var queued = entries.filter { $0.state == "等待下载" }.map(\.filename)
        while let next = OfflineQueuePolicy.next(queued: queued, active: active),
              let index = entries.firstIndex(where: { $0.filename == next && $0.state == "等待下载" }) {
            guard let task = tasks.first(where: { $0.taskDescription == next && $0.state == .suspended }) else {
                entries[index].state = "已中断"; entries[index].message = "下载任务已失效，请重新登录来源后重试。"; persist()
                queued.removeFirst(); continue
            }
            entries[index].state = "下载中"; task.resume(); persist(); return
        }
    }
    func persist() {
        guard canPersist else { return }
        do { try Self.snapshot.save(entries); storageError = nil }
        catch { storageError = "离线记录未能保存：" + error.localizedDescription }
    }
    func reconcile() async {
        let knownFiles = Set(entries.map(\.filename))
        let tasks = await session.allTasks
        let active = Set(tasks.compactMap(\.taskDescription))
        for index in entries.indices {
            let filename = entries[index].filename
            if preparing.contains(filename) { continue }
            if entries[index].state == "准备资料", !preparing.contains(filename) { entries[index].state = "已中断"; entries[index].message = "资料准备已中断，请重新准备后重试。" }
            guard knownFiles.contains(filename) else { continue }
            if validations[filename] != nil { continue }
            if FileManager.default.fileExists(atPath: Self.files.pendingURL(filename).path) ||
                (entries[index].state != "已完成" && FileManager.default.fileExists(atPath: Self.files.fileURL(filename).path)) {
                // Recover a transfer whose process ended during validation or publication.
                beginValidation(filename); continue
            }
            if ["等待下载", "下载中", "已暂停", "校验中"].contains(entries[index].state) && !active.contains(entries[index].filename) {
                entries[index].state = "已中断"; entries[index].message = "下载任务已结束，可在此处重试下载。"
            }
            if entries[index].state == "已完成" && localURL(videoID: entries[index].id) == nil { entries[index].state = "文件已移除" }
        }
        persist(); await advanceQueue()
    }
    private func scheduleMaintenance() {
        let request = BGProcessingTaskRequest(identifier: Self.maintenanceID)
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 900)
        try? BGTaskScheduler.shared.submit(request)
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskDescription
        Task { @MainActor in
            guard let index = self.entries.firstIndex(where: { $0.filename == id && $0.state == "下载中" }) else { return }
            if let expected = self.entries[index].expectedBytes, totalBytesWritten > expected {
                downloadTask.cancel(); self.entries[index].state = "下载失败"; self.entries[index].message = "下载大小超过已确认的原文件，已停止以保护容量预算。"; self.persist(); await self.advanceQueue(); return
            }
            self.entries[index].progress = totalBytesExpectedToWrite > 0 ? min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))) : 0
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let filename = downloadTask.taskDescription else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw MediaError.message("服务器未返回有效的下载响应。") }
            try OfflineMediaFiles.validateResponse(status: response.statusCode, mimeType: response.mimeType)
            // URLSession removes location when this delegate returns. Preserve both
            // the file and its extension before scheduling asynchronous validation.
            try Self.files.stage(location, filename: filename)
            Task { @MainActor in
                guard self.entries.contains(where: { $0.filename == filename }) else { Self.files.remove(filename); return }
                self.beginValidation(filename)
                await self.advanceQueue()
            }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in
                guard self.validations[filename] == nil,
                      let index = self.entries.firstIndex(where: { $0.filename == filename && !["校验中", "已完成"].contains($0.state) }) else { return }
                self.entries[index].state = "下载失败"; self.entries[index].message = message; self.persist(); await self.advanceQueue()
            }
        }
    }
    private func beginValidation(_ filename: String) {
        guard validations[filename] == nil, let index = entries.firstIndex(where: { $0.filename == filename }) else { return }
        let entry = entries[index], files = Self.files
        let pending = files.pendingURL(filename)
        let staged = FileManager.default.fileExists(atPath: pending.path)
        let url = staged ? pending : files.fileURL(filename)
        if entry.state == "已完成", FileManager.default.fileExists(atPath: files.fileURL(filename).path) {
            if staged { try? FileManager.default.removeItem(at: pending) }
            return
        }
        // Reconciliation may already have validated (or rejected) this transfer
        // before the delegate's main-actor task runs. Do not process it again.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        entries[index].state = "校验中"; entries[index].progress = 1; entries[index].message = nil; persist()
        validations[filename] = Task {
            defer { self.validations[filename] = nil }
            var verified = false
            do {
                try OfflineMediaFiles.validateSize(url, expectedBytes: entry.expectedBytes)
                if url.pathExtension.lowercased() != "mkv" {
                    let asset = AVURLAsset(url: url)
                    let playable = try await asset.load(.isPlayable)
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    try Task.checkCancellation()
                    guard playable, !tracks.isEmpty else { throw MediaError.message("文件校验完成，但系统无法识别，请重新下载或使用已支持的原文件。") }
                }
                guard self.entries.contains(where: { $0.filename == filename }) else { return }
                verified = true
                if staged { try files.commit(filename) }
                if let current = self.entries.firstIndex(where: { $0.filename == filename }) {
                    self.entries[current].state = "已完成"; self.entries[current].progress = 1; self.entries[current].message = nil; self.entries[current].playbackCheck = nil
                }
            } catch {
                guard !Task.isCancelled, let current = self.entries.firstIndex(where: { $0.filename == filename }) else { return }
                self.entries[current].state = "下载失败"
                self.entries[current].message = (error as NSError).domain == AVFoundationErrorDomain
                    ? "文件已下载，但系统无法识别此视频，请使用在线兼容播放。" : error.localizedDescription
                // A valid transfer can be retried locally if only publication failed.
                if !verified { files.remove(filename) }
            }
            self.persist(); await self.advanceQueue()
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }; let id = task.taskDescription
        Task { @MainActor in
            guard let index = self.entries.firstIndex(where: { $0.filename == id && $0.state == "下载中" }) else { return }
            self.entries[index].state = "下载失败"; self.entries[index].message = error.localizedDescription; self.persist(); await self.advanceQueue()
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            // Finish durable file validation before returning the background event to iOS.
            for entry in self.entries where FileManager.default.fileExists(atPath: Self.files.pendingURL(entry.filename).path) { self.beginValidation(entry.filename) }
            let pending = Array(self.validations.values)
            for work in pending { await work.value }
            self.backgroundCompletion?(); self.backgroundCompletion = nil
        }
    }
}

@MainActor extension DownloadStore {
    func offlineVideo(_ id: String) throws -> Video {
        guard let entry = entries.first(where: { $0.id == id }), let local = localURL(videoID: id) else { throw MediaError.message("视频尚未下载完成或本机副本已移除。") }
        var video = entry.video
        video.url = local; video.artwork = nil; video.offlineOnly = true
        return video
    }
    func offlineResource(_ video: Video) throws -> PlaybackResource {
        guard video.offlineOnly == true, let entry = entries.first(where: { $0.id == video.id }), let local = localURL(videoID: video.id) else { throw MediaError.message("找不到离线文件，请先完成下载。") }
        return PlaybackResource(url: local, delivery: .local, videoStream: entry.source?.MediaStreams?.first { $0.Type == "Video" }, sourceContainer: local.pathExtension)
    }
    func checked(_ entry: OfflineDownload) -> Bool {
        guard let stamp = entry.playbackCheck, let url = localURL(videoID: entry.id),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return false }
        return stamp.matches(size: Int64(size), modified: modified) && stamp.resourcesFingerprint == (try? OfflineCompanions.fingerprint(entry.subtitles ?? [], filename: entry.filename))
    }
    @discardableResult func recordPlaybackCheck(_ id: String, engine: PlaybackEngineID) async throws -> [String] {
        guard let index = entries.firstIndex(where: { $0.id == id }), let local = localURL(videoID: id) else { throw MediaError.message("离线文件已移除。") }
        let entry = entries[index]
        try OfflineMediaFiles.validateSize(local, expectedBytes: entries[index].expectedBytes)
        let values = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, let modified = values.contentModificationDate else { throw MediaError.message("无法确认离线文件版本。") }
        let issues = await companionIssues(entry)
        try Task.checkCancellation()
        guard let index = entries.firstIndex(where: { $0.id == id && $0.filename == entry.filename }) else { throw MediaError.message("检查期间离线文件已变化。") }
        entries[index].playbackCheck = OfflinePlaybackCheck(size: Int64(size), modified: modified, engine: engine, checkedAt: Date(), resourcesFingerprint: try OfflineCompanions.fingerprint(entries[index].subtitles ?? [], filename: entries[index].filename))
        entries[index].checkedIssues = issues
        persist()
        if let storageError { throw MediaError.message(storageError) }
        return issues
    }
    func companionIssues(_ entry: OfflineDownload) async -> [String] {
        await Task.detached(priority: .utility) {
        var issues = (entry.resourceWarnings ?? []).filter { !$0.hasPrefix("缺少原字体：") }
        if entry.subtitles == nil { issues.append("旧版下载尚未检查配套字幕，请联网重新准备资料。") }
        for asset in entry.subtitles ?? [] {
            do {
                if let file = asset.file {
                    let data = try OfflineCompanions.read(file, filename: entry.filename, limit: file.hasSuffix(".sup") ? PGSSubtitle.maximumBytes : SubtitleDocument.maximumBytes)
                    if file.hasSuffix(".sup") { _ = try PGSSubtitle.parse(data) }
                    else if ASSDocument.recognizes(data) {
                        let script = try ASSDocument.parse(data)
                        let fonts = try asset.fonts.map { try OfflineCompanions.read($0, filename: entry.filename, limit: ASSFontStore.maximumBytes) }
                        issues += ASSFontStore.missingFonts(script.requestedFonts, fonts: fonts + (try ASSFontStore.fonts())).map { "缺少原字体：\($0)" }
                    } else { _ = try SubtitleDocument.parse(data) }
                }
            } catch { issues.append(asset.name + "：" + error.localizedDescription) }
        }
        return Array(Set(issues)).sorted()
        }.value
    }
    func installOfflineSubtitles(video: Video, primary: SubtitleSession, secondary: SubtitleSession) async throws {
        guard let entry = entries.first(where: { $0.id == video.id }) else { return }
        for session in [primary, secondary] {
            if let asset = entry.subtitles?.first(where: { $0.lane == session.lane.rawValue }) {
                try await session.installOffline(asset, filename: entry.filename, videoID: video.id)
            }
        }
    }
    func refreshCompanions(_ id: String, library: LibraryStore) async throws {
        guard let entry = entries.first(where: { $0.id == id }), let server = library.servers.first(where: { $0.id == entry.serverID }),
              let remoteID = entry.video.remoteID, server.kind.isCatalogSource else { throw MediaError.message("请连接原媒体服务器后再准备资料。") }
        let binding = try SubtitleSource.key(video: entry.video, server: server)
        guard entry.accountBinding == nil || entry.accountBinding == binding else { throw MediaError.message("来源账号已变化，请切回原账号。") }
        let item = try await MediaClient.shared.catalogDetail(server: server, id: remoteID, refresh: true)
        guard let source = item.MediaSources?.first, entry.source == nil || (source.Id == entry.source?.Id && source.Size == entry.expectedBytes) else { throw MediaError.message("源文件版本已变化，请重新下载。") }
        let value = await prepareCompanions(item: item, server: server, filename: entry.filename)
        guard let index = entries.firstIndex(where: { $0.filename == entry.filename }) else { return }
        entries[index].subtitles = value.assets; entries[index].resourceWarnings = value.warnings; entries[index].playbackCheck = nil
        entries[index].companionBytes = OfflineCompanions.bytes(entry.filename)
        guard resourcesFit(entries[index]) else {
            OfflineCompanions.remove(entry.filename); entries[index].companionBytes = 0; entries[index].subtitles = nil
            entries[index].resourceWarnings = ["配套资料超过容量预算，请清理空间后重新准备。"]
            persist(); throw MediaError.message("配套资料超过容量预算。")
        }
        entries[index].overview = item.Overview
        entries[index].providerIDs = item.ProviderIds; entries[index].productionYear = item.ProductionYear
        if let url = entry.video.artwork ?? item.video(server: server).artwork,
           let image = try? await ArtworkCache.shared.image(server: server, url: url, pixels: 320),
           let data = image.jpegData(compressionQuality: 0.8), data.count < 1_000_000,
           let current = entries.firstIndex(where: { $0.filename == entry.filename }) { entries[current].artworkData = data }
        persist()
    }
    /// Local videos are copied once into owned durable storage. Never remove the original.
    func keepLocal(_ video: Video, server: MediaServer?, expectedBytes: Int64? = nil, maximumBytes: Int64? = nil) async throws {
        if localURL(videoID: video.id) != nil { return }
        guard !entries.contains(where: { $0.id == video.id && ["校验中", "准备资料"].contains($0.state) }) else { return }
        guard canPersist else { throw MediaError.message(storageError ?? "离线记录无法读取。") }
        let resource: PlaybackResource
        if let server, server.kind == .local { resource = try LocalMediaStore.playback(video, server: server) }
        else if video.demoIndex != nil, let url = video.url { resource = PlaybackResource(url: url, delivery: .local) }
        else { throw MediaError.message("首批行程包支持本地视频、Jellyfin 与 Emby。") }
        let url = resource.url, ext = url.pathExtension.lowercased()
        guard ["mp4", "mov", "m4v", "mkv"].contains(ext) else { throw MediaError.message("此本地封装尚不支持加入离线包。") }
        let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard expectedBytes == nil || expectedBytes == size else { throw MediaError.message("本地文件大小已变化，请重新生成行程候选。") }
        if let maximumBytes, size > maximumBytes { throw MediaError.message("此文件超过行程包剩余容量。") }
        guard size > 0, size <= PlaybackPreferences.downloadLimit - allocatedBytes else { throw MediaError.message("文件大小无效或超过离线容量预算。") }
        guard physicalSpaceAllows(size, excluding: video.id) else { throw MediaError.message("设备剩余空间不足，已为待完成下载预留空间。") }
        let filename = UUID().uuidString + "." + ext
        preparing.insert(filename)
        defer { preparing.remove(filename) }
        entries.removeAll { $0.id == video.id }
        entries.append(OfflineDownload(video: PersonalVideo(video: video).video, serverID: video.sourceID ?? UUID(), filename: filename, state: "校验中", expectedBytes: size, maximumBytes: maximumBytes))
        persist()
        let files = Self.files, access = resource.localAccess
        let task = Task.detached {
            defer { withExtendedLifetime(access) {} }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: files.pendingURL(filename).deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: files.pendingURL(filename))
            try OfflineMediaFiles.validateSize(files.pendingURL(filename), expectedBytes: size)
            try Task.checkCancellation(); try files.commit(filename)
        }
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch { files.remove(filename); entries.removeAll { $0.filename == filename }; persist(); throw error }
        let companions = if let server { await prepareLocalCompanions(video: video, server: server, filename: filename) } else { (assets: [OfflineSubtitleAsset](), warnings: [String]()) }
        guard let index = entries.firstIndex(where: { $0.filename == filename }) else { files.remove(filename); OfflineCompanions.remove(filename); return }
        entries[index].subtitles = companions.assets; entries[index].resourceWarnings = companions.warnings
        entries[index].companionBytes = OfflineCompanions.bytes(filename)
        if !resourcesFit(entries[index]) {
            OfflineCompanions.remove(filename); entries[index].subtitles = nil; entries[index].companionBytes = 0
            entries[index].resourceWarnings = ["配套资料超过容量预算，请清理空间后重新准备。"]
        }
        entries[index].state = "已完成"; entries[index].progress = 1
        persist()
        if let storageError { throw MediaError.message(storageError) }
    }
    private func physicalSpaceAllows(_ bytes: Int64, excluding id: String) -> Bool {
        let available = (try? FileManager.default.attributesOfFileSystem(forPath: Self.directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let reservations = entries.filter {
            $0.id != id && $0.state != "已完成" &&
            !FileManager.default.fileExists(atPath: Self.files.fileURL($0.filename).path) &&
            !FileManager.default.fileExists(atPath: Self.files.pendingURL($0.filename).path)
        }.map { $0.expectedBytes ?? 0 }
        return OfflineMediaFiles.canReserve(bytes: bytes, availableBytes: available, reservations: reservations)
    }
    private func resourcesFit(_ entry: OfflineDownload) -> Bool {
        guard allocatedBytes <= PlaybackPreferences.downloadLimit else { return false }
        if let maximum = entry.maximumBytes, (entry.expectedBytes ?? 0) > maximum - (entry.companionBytes ?? 0) { return false }
        for trip in OfflineTripStore.shared.trips where trip.videoIDs.contains(entry.id) {
            let total = entries.filter { trip.videoIDs.contains($0.id) }.reduce(Int64(0)) { $0 + ($1.expectedBytes ?? 0) + ($1.companionBytes ?? 0) }
            if total > trip.maximumBytes { return false }
        }
        return true
    }
}

final class GlideAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = DownloadStore.shared
        BGTaskScheduler.shared.register(forTaskWithIdentifier: DownloadStore.maintenanceID, using: .main) { task in
            let work = Task { @MainActor in await DownloadStore.shared.reconcile(); task.setTaskCompleted(success: !Task.isCancelled) }
            task.expirationHandler = { work.cancel() }
        }
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == DownloadStore.sessionID { DownloadStore.shared.backgroundCompletion = completionHandler }
        else { completionHandler() }
    }
}

#if DEBUG
@MainActor extension DownloadStore {
    /// Original bundle material only, restricted to the isolated clip QA directory.
    func installClipQAFile() throws -> Video {
        guard ProcessInfo.processInfo.arguments.contains("--glide-clip-fixture"), Self.directory.lastPathComponent == "OfflineClipsQA",
              let original = Bundle.main.url(forResource: "demo0", withExtension: "mp4") else { throw MediaError.message("验证素材不可用。") }
        let filename = "clip-original.mp4", target = Self.directory.appendingPathComponent("clip-original.mp4")
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: original, to: target) }
        let sourceID = UUID(uuidString: "11400000-0000-0000-0000-000000000099")!
        let video = Video(id: "clip-qa-offline", title: "原创离线片段", subtitle: "原创", sourceID: sourceID, remoteID: "clip-qa-offline", duration: 12)
        entries.removeAll { $0.id == video.id }
        entries.append(OfflineDownload(video: video, serverID: sourceID, filename: filename, state: "已完成", progress: 1, originAccountID: "clip-qa"))
        try Self.snapshot.save(entries)
        return try offlineVideo(video.id)
    }
}
#endif
