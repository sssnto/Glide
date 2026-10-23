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
}

@MainActor @Observable
final class DownloadStore: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadStore()
    static let sessionID = "com.songpeng.glide.downloads.v1"
    static let maintenanceID = "com.songpeng.glide.download-maintenance"
    private(set) var entries: [OfflineDownload] = []
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var scheduling = false
    @ObservationIgnored private var validations: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    private nonisolated static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineMedia", isDirectory: true) }
    private nonisolated static var files: OfflineMediaFiles { OfflineMediaFiles(directory: directory) }
    private static var manifest: URL { directory.appendingPathComponent("manifest.json") }
    override private init() {
        super.init()
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var folder = Self.directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? folder.setResourceValues(values)
        if let data = try? Data(contentsOf: Self.manifest) { entries = (try? JSONDecoder().decode([OfflineDownload].self, from: data)) ?? [] }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        Task { await reconcile() }
    }
    func enqueue(item: CatalogItem, server: MediaServer, sourceID: String?) async throws {
        let video = item.video(server: server)
        guard !entries.contains(where: { $0.id == video.id && ["等待下载", "下载中", "已暂停", "校验中", "已完成"].contains($0.state) }) else { return }
        guard let source = item.MediaSources?.first, sourceID == nil || sourceID == source.Id else { throw MediaError.message("离线下载暂支持默认媒体版本。") }
        let ext = source.Container?.lowercased() ?? ""
        guard ["mp4", "mov", "m4v"].contains(ext) else { throw MediaError.message("离线播放暂支持 MP4 / MOV / M4V 原文件。请在线使用媒体服务器转码。") }
        guard let token = Credentials.read(server.id), let remoteID = video.remoteID else { throw MediaError.message("请重新登录。") }
        let available = (try? FileManager.default.attributesOfFileSystem(forPath: Self.directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? Int64.max
        let allocated = entries.filter { $0.id != video.id }.reduce(Int64(0)) { $0 + ($1.expectedBytes ?? 0) }
        guard allocated + (source.Size ?? 0) <= PlaybackPreferences.downloadLimit else { throw MediaError.message("超过离线容量预算，请清理下载或在设置中调整。") }
        guard available > (source.Size ?? 0) + 200 * 1024 * 1024 else { throw MediaError.message("设备剩余空间不足，请先清理存储。") }
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
        entries.append(OfflineDownload(video: PersonalVideo(video: video).video, serverID: server.id, filename: filename, state: "等待下载", expectedBytes: source.Size))
        persist()
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
        if let task = tasks.first(where: { $0.taskDescription == entry.filename && ($0.state == .suspended || $0.state == .running) }) {
            entries[index].state = "等待下载"; entries[index].message = nil; task.suspend(); entries.append(entries.remove(at: index)); persist(); await advanceQueue(); return
        }
        guard let server = library.servers.first(where: { $0.id == entry.serverID }), let remoteID = entry.video.remoteID, let token = Credentials.read(server.id) else {
            entries[index].state = "下载失败"; entries[index].message = "请先重新登录此媒体来源。"; persist(); return
        }
        var request = URLRequest(url: ServerURL.endpoint(server.address, "Items/\(remoteID)/Download"))
        request.setValue(MediaClient.shared.authorization(token, server: server), forHTTPHeaderField: "Authorization")
        request.allowsCellularAccess = !PlaybackPreferences.downloadWiFiOnly
        request.allowsExpensiveNetworkAccess = !PlaybackPreferences.downloadWiFiOnly
        // Give retries a new identity so late callbacks cannot overwrite the new transfer.
        let filename = UUID().uuidString + "." + (entry.filename as NSString).pathExtension
        Self.files.remove(entry.filename)
        entries[index].filename = filename
        entries[index].state = "等待下载"; entries[index].progress = 0; entries[index].message = "正在重新下载。"
        entries.append(entries.remove(at: index))
        let task = session.downloadTask(with: request); task.taskDescription = filename; persist(); await advanceQueue()
    }
    func remove(_ id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }; persist()
        validations[entry.filename]?.cancel()
        Self.files.remove(entry.filename)
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == entry.filename }.forEach { $0.cancel() }
            Task { @MainActor in await self.advanceQueue() }
        }
    }
    func removeServer(_ id: UUID, includingCompleted: Bool = false) {
        entries.filter { $0.serverID == id && (includingCompleted || $0.state != "已完成") }.map(\.id).forEach(remove)
    }
    var allocatedBytes: Int64 { entries.reduce(0) { $0 + ($1.expectedBytes ?? 0) } }
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
    private func persist() { if let data = try? JSONEncoder().encode(entries) { try? data.write(to: Self.manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) } }
    func reconcile() async {
        let knownFiles = Set(entries.map(\.filename))
        let tasks = await session.allTasks
        let active = Set(tasks.compactMap(\.taskDescription))
        for index in entries.indices {
            let filename = entries[index].filename
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
                let asset = AVURLAsset(url: url)
                let playable = try await asset.load(.isPlayable)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                try Task.checkCancellation()
                guard playable, !tracks.isEmpty else { throw MediaError.message("此文件无法在本机离线播放，请使用在线兼容播放。") }
                guard self.entries.contains(where: { $0.filename == filename }) else { return }
                verified = true
                if staged { try files.commit(filename) }
                if let current = self.entries.firstIndex(where: { $0.filename == filename }) {
                    self.entries[current].state = "已完成"; self.entries[current].progress = 1; self.entries[current].message = nil
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
