import AVFoundation
import Network
import UIKit

/// Startup bytes for neighbours and at most one paused, copy-only original HLS player.
@MainActor final class PlaybackWarmup {
    struct Target { let video: Video; let server: MediaServer? }
    struct Prepared: PlaybackPreload {
        var engineID: PlaybackEngineID { .avPlayer }
        let key: String
        let resource: PlaybackResource
        let asset: AVURLAsset
        let loader: AuthenticatedAsset?
        let expires: Date
        var lease: WarmPlayerLease? = nil
        var originalResource: PlaybackResource? = nil
        var quality: PlaybackQuality { lease == nil ? .automatic : .compatible }
        var byteCount: Int { loader?.startupByteCount ?? 0 }
        func accepts(_ tracks: TrackSelection) -> Bool {
            if let source = tracks.mediaSourceID, source != resource.mediaSourceID { return false }
            if let audio = tracks.audioIndex, audio != resource.serverAudioIndex { return false }
            if let subtitle = tracks.subtitleIndex {
                return subtitle == -1 && resource.serverSubtitleStreams.isEmpty
            }
            return true
        }
    }
    private let monitor = NWPathMonitor()
    private var networkAllowed = false
    private var desired: [Target] = []
    private var prepared: [String: Prepared] = [:]
    private var attempted = Set<String>()
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var workingKey: String?
    private var token = UUID()
    private var suspended = false
    private var primaryKey: String?
    private var memoryObserver: NSObjectProtocol?
    private var powerObserver: NSObjectProtocol?
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.networkAllowed = PlaybackWarmupPolicy.allowsNetwork(satisfied: path.status == .satisfied,
                    wifi: path.usesInterfaceType(.wifi), expensive: path.isExpensive, constrained: path.isConstrained,
                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
                if !self.networkAllowed { self.discardRemote() } else { self.startNext() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "Glide.playback.warmup.path"))
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if ProcessInfo.processInfo.isLowPowerModeEnabled { self?.cancel() } }
        }
    }
    private func key(_ video: Video, _ server: MediaServer?) -> String {
        // Memory only. Authentication or preference changes cannot reuse a former account's stream.
        [video.id, server?.address.absoluteString ?? "local", server?.userID ?? "",
         server.map { Credentials.read($0.id) ?? "" } ?? "", PlaybackPreferences.audioLanguage,
         PlaybackPreferences.subtitleLanguage, String(PlaybackPreferences.forcedOnly), String(PlaybackPreferences.cellularPlayback)].joined(separator: "\u{1f}")
    }
    func take(_ video: Video, server: MediaServer?) -> Prepared? {
        let identity = key(video, server)
        guard let ready = prepared.removeValue(forKey: identity) else { return nil }
        guard ready.expires > Date(), ready.lease?.failed != true else { ready.loader?.cancel(); ready.lease?.dispose(); return nil }
        ready.lease?.claimed = true
        if workingKey == identity { cancelWork() }
        return ready
    }
    func prepare(_ video: Video, server: MediaServer?) async { update([Target(video: video, server: server)]) }
    func update(_ targets: [Target]) {
        let targets = Array(targets.prefix(PlaybackWarmupPolicy.maximumItems))
        let keys = Set(targets.map { key($0.video, $0.server) })
        let primary = targets.first.map { key($0.video, $0.server) }
        if primary != primaryKey, let primary { attempted.remove(primary) }
        primaryKey = primary
        if let workingKey, workingKey != primary { cancelWork() }
        for (identity, entry) in prepared where identity != primary {
            entry.loader?.trimStartupHead(to: PlaybackWarmupPolicy.secondaryHeadBytes)
            if let lease = entry.lease {
                lease.dispose()
                if let direct = entry.originalResource {
                    prepared[identity] = Prepared(key: identity, resource: direct, asset: AVURLAsset(url: direct.url), loader: nil, expires: entry.expires)
                } else { prepared.removeValue(forKey: identity); attempted.remove(identity) }
            }
        }
        if let primary, prepared[primary]?.resource.prefersSegmentedTransport == true { attempted.remove(primary) }
        for (identity, entry) in prepared where !keys.contains(identity) || entry.expires <= Date() {
            entry.loader?.cancel(); entry.lease?.dispose(); prepared.removeValue(forKey: identity); attempted.remove(identity)
        }
        if let workingKey, !keys.contains(workingKey) { cancelWork() }
        desired = targets; attempted.formIntersection(keys); suspended = false
        startNext(); scheduleExpiry()
    }
    private func scheduleExpiry() {
        expiryTask?.cancel(); expiryTask = nil
        guard !suspended, let expiry = prepared.values.map(\.expires).min() else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.1, expiry.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            update(desired)
        }
    }
    /// Buffering the current video takes precedence; retain completed neighbour bytes.
    func suspend() {
        suspended = true
        if let workingKey { attempted.remove(workingKey) }
        cancelWork(); expiryTask?.cancel(); expiryTask = nil
        for (identity, entry) in prepared {
            guard let lease = entry.lease else { continue }
            lease.dispose()
            if let direct = entry.originalResource {
                prepared[identity] = Prepared(key: identity, resource: direct, asset: AVURLAsset(url: direct.url), loader: nil, expires: entry.expires)
            } else { prepared.removeValue(forKey: identity) }
            attempted.remove(identity)
        }
    }
    private func localURL(_ target: Target) -> URL? {
        DownloadStore.shared.localURL(videoID: target.video.id) ?? (target.video.url?.isFileURL == true ? target.video.url : nil)
    }
    private func eligible(_ target: Target) -> Bool {
        target.video.offlineOnly != true && target.server?.kind != .smb &&
            !ProcessInfo.processInfo.isLowPowerModeEnabled &&
            !PlaybackRouteMemory().prefersVideoConversion(for: target.video.id) &&
            (networkPermits(target) || localURL(target) != nil || target.server?.kind == .local)
    }
    private func networkPermits(_ target: Target) -> Bool {
#if DEBUG
        if (ProcessInfo.processInfo.arguments.contains("--glide-feed-warmup-probe") || ProcessInfo.processInfo.arguments.contains("--glide-feed-warmup-ui")),
           target.server?.address.host == "127.0.0.1", target.server?.address.port == 8797 { return true }
#endif
        return networkAllowed
    }
#if DEBUG
    func evidence(_ video: Video, server: MediaServer?) -> (bytes: Int, copyPrimed: Bool, paused: Bool, players: Int) {
        let entry = prepared[key(video, server)]
        return (entry?.byteCount ?? 0, entry?.lease?.primed == true,
            entry?.lease.map { $0.player.rate == 0 } ?? true, prepared.values.filter { $0.lease != nil }.count)
    }
#endif
    private func startNext() {
        guard !suspended, work == nil, let target = desired.first(where: {
            let identity = key($0.video, $0.server)
            let isPrimary = identity == desired.first.map { key($0.video, $0.server) }
            let growth = prepared[identity]?.loader?.startupInfo.map { $0.headBytes < min(PlaybackWarmupPolicy.headBytes, Int(clamping: $0.length)) } ?? false
            let needsBuffer = isPrimary && (prepared[identity]?.resource.prefersSegmentedTransport == true || growth)
            return eligible($0) && (prepared[identity] == nil || needsBuffer) && !attempted.contains(identity)
        }) else { return }
        let identity = key(target.video, target.server), request = UUID()
        let primary = desired.first.map { key($0.video, $0.server) } == identity
        let seed = prepared[identity]
        token = request; workingKey = identity; attempted.insert(identity)
        work = Task { [weak self] in
            guard let self else { return }
            defer { if token == request { work = nil; workingKey = nil; deadline?.cancel(); deadline = nil; startNext(); scheduleExpiry() } }
            do {
                let resource: PlaybackResource
                if let seed { resource = seed.resource }
                else if let server = target.server, server.kind == .local { resource = try LocalMediaStore.playback(target.video, server: server) }
                else if let local = localURL(target) { resource = PlaybackResource(url: local, delivery: .local) }
                else { resource = try await resolve(target, primary: primary) }
                let resolvedLease = resource.isTranscoding ? target.server.map { WarmPlayerLease(resource: resource, server: $0) } : nil
                try Task.checkCancellation()
                guard token == request, !(resource.webDAV && WebDAVPlaybackPolicy.prefersCompatibility(resource.url)) else { return }
                // Ordinary home videos can still warm with global language preferences.
                // Multi-track/subtitle choices keep the full foreground negotiation.
                guard (PlaybackPreferences.audioLanguage.isEmpty || resource.serverAudioStreams.count <= 1),
                      ((PlaybackPreferences.subtitleLanguage.isEmpty && !PlaybackPreferences.forcedOnly) || resource.serverSubtitleStreams.isEmpty) else { return }
                if resource.prefersSegmentedTransport || resolvedLease != nil {
                    guard primary, let server = target.server, server.kind == .jellyfin else {
                        prepared[identity] = Prepared(key: identity, resource: resource, asset: AVURLAsset(url: resource.url), loader: nil, expires: Date().addingTimeInterval(PlaybackWarmupPolicy.lifetime))
                        return
                    }
                    let copy: PlaybackResource
                    if let resolvedLease { copy = resolvedLease.resource }
                    else { copy = try await MediaClient.shared.playback(video: target.video, server: server, quality: .compatible, tracks: TrackSelection(mediaSourceID: resource.mediaSourceID)) }
                    let lease = resolvedLease ?? WarmPlayerLease(resource: copy, server: server)
                    guard token == request, !Task.isCancelled else { lease.dispose(); return }
                    let asset = AVURLAsset(url: copy.url, options: [AVURLAssetAllowsCellularAccessKey: PlaybackPreferences.cellularPlayback])
                    let item = AVPlayerItem(asset: asset)
                    item.preferredForwardBufferDuration = PlaybackWarmupPolicy.segmentedSeconds(bitrate: copy.sourceBitrate)
                    lease.player.replaceCurrentItem(with: item)
                    prepared[identity] = Prepared(key: identity, resource: copy, asset: item.asset as? AVURLAsset ?? asset, loader: nil,
                        expires: Date().addingTimeInterval(PlaybackWarmupPolicy.lifetime), lease: lease, originalResource: resource.isTranscoding ? nil : resource)
                    try await withTaskCancellationHandler {
                        while lease.player.status == .unknown && item.status != .failed {
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        guard !Task.isCancelled, self.token == request, lease.player.status == .readyToPlay else { return }
                        let finished = await lease.player.preroll(atRate: 1)
                        if self.token == request, !lease.claimed { lease.primed = finished }
                    } onCancel: { Task { @MainActor in lease.player.cancelPendingPrerolls() } }
                    if token == request, !lease.claimed { lease.player.pause() }
                } else if resource.url.isFileURL {
                    let asset = AVURLAsset(url: resource.url)
                    guard try await asset.load(.isPlayable), !Task.isCancelled, token == request else { return }
                    prepared[identity] = Prepared(key: identity, resource: resource, asset: asset, loader: nil, expires: Date().addingTimeInterval(PlaybackWarmupPolicy.lifetime))
                } else if let seed, let loader = seed.loader, let info = loader.startupInfo {
                    let budget = primary ? PlaybackWarmupPolicy.headBytes : PlaybackWarmupPolicy.secondaryHeadBytes
                    var offset = Int64(info.headBytes)
                    while offset < min(info.length, Int64(budget)) {
                        let count = Int(min(Int64(PlaybackWarmupPolicy.initialHeadBytes), min(info.length, Int64(budget)) - offset))
                        let chunk = try await StartupRangeRead.fetch(url: resource.url, headers: resource.headers, offset: offset, count: count, validator: info.validator)
                        try Task.checkCancellation()
                        guard token == request, chunk.length == info.length, chunk.validator == info.validator else { return }
                        loader.appendStartupHead(chunk.data, offset: offset, length: chunk.length, validator: chunk.validator)
                        offset += Int64(chunk.data.count)
                    }
                } else {
                    // Require a bounded 206 response. A server ignoring Range is never downloaded.
                    let head = try await StartupRangeRead.fetch(url: resource.url, headers: resource.headers, offset: 0, count: PlaybackWarmupPolicy.initialHeadBytes)
                    try Task.checkCancellation()
                    guard token == request, let bytes = PlaybackStartupBytes(head: head.data, length: head.length, validator: head.validator, mimeType: head.mimeType) else { return }
                    let loader = AuthenticatedAsset(url: resource.url, headers: resource.headers, allowsCellular: false, startup: bytes)
                    prepared[identity] = Prepared(key: identity, resource: resource, asset: loader.asset, loader: loader, expires: Date().addingTimeInterval(PlaybackWarmupPolicy.lifetime))
                    let offset = max(Int64(head.data.count), head.length - Int64(PlaybackWarmupPolicy.tailBytes))
                    if offset < head.length {
                        let tail = try await StartupRangeRead.fetch(url: resource.url, headers: resource.headers, offset: offset, count: Int(head.length - offset), validator: head.validator)
                        try Task.checkCancellation()
                        guard token == request else { return }
                        loader.appendStartupTail(tail.data, offset: offset, length: tail.length, validator: tail.validator)
                    }
                    let budget = primary ? PlaybackWarmupPolicy.headBytes : PlaybackWarmupPolicy.secondaryHeadBytes
                    var headEnd = Int64(head.data.count)
                    while headEnd < min(head.length, Int64(budget)) {
                        let count = Int(min(Int64(PlaybackWarmupPolicy.initialHeadBytes), min(head.length, Int64(budget)) - headEnd))
                        let chunk = try await StartupRangeRead.fetch(url: resource.url, headers: resource.headers, offset: headEnd, count: count, validator: head.validator)
                        try Task.checkCancellation()
                        guard token == request, chunk.length == head.length, chunk.validator == head.validator else { return }
                        loader.appendStartupHead(chunk.data, offset: headEnd, length: chunk.length, validator: chunk.validator)
                        headEnd += Int64(chunk.data.count)
                    }
                }
            } catch { /* Optional work never interrupts the selected video. A completed head remains reusable. */ }
        }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PlaybackWarmupPolicy.requestDeadline))
            guard !Task.isCancelled, let self, token == request else { return }
            cancelWork(); startNext()
        }
    }
    private func resolve(_ target: Target, primary: Bool) async throws -> PlaybackResource {
        do { return try await MediaClient.shared.playback(video: target.video, server: target.server, directOnly: true) }
        catch {
            try Task.checkCancellation()
            guard primary, let server = target.server, server.kind == .jellyfin,
                  let itemID = target.video.remoteID else { throw error }
            // HEVC/container mismatches can require original remux even when direct play is unavailable.
            // Inspect metadata first, and never extract or override an unselected subtitle in the background.
            let detail = try await MediaClient.shared.catalogDetail(server: server, id: itemID)
            guard let source = detail.MediaSources?.first,
                  !(source.MediaStreams ?? []).contains(where: { $0.Type == "Subtitle" }) else { throw error }
            let selection = TrackSelection(mediaSourceID: source.Id, subtitleIndex: -1)
            return try await MediaClient.shared.playback(video: target.video, server: server, quality: .compatible, tracks: selection)
        }
    }
    private func cancelWork() {
        token = UUID(); work?.cancel(); work = nil; workingKey = nil; deadline?.cancel(); deadline = nil
    }
    private func discardRemote() {
        for target in desired where !networkPermits(target) && localURL(target) == nil && target.server?.kind != .local {
            attempted.remove(key(target.video, target.server))
        }
        if let workingKey, desired.contains(where: { key($0.video, $0.server) == workingKey && localURL($0) == nil && $0.server?.kind != .local && !networkPermits($0) }) { cancelWork() }
        for (identity, value) in prepared where !value.resource.url.isFileURL && !desired.contains(where: { key($0.video, $0.server) == identity && networkPermits($0) }) {
            value.loader?.cancel(); value.lease?.dispose(); prepared.removeValue(forKey: identity); attempted.remove(identity)
        }
    }
    func cancel() {
        cancelWork(); expiryTask?.cancel(); expiryTask = nil; desired = []; attempted = []; primaryKey = nil
        prepared.values.forEach { $0.loader?.cancel(); $0.lease?.dispose() }; prepared = [:]
    }
    deinit {
        monitor.cancel(); work?.cancel(); deadline?.cancel(); expiryTask?.cancel()
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
    }
}

/// Owns exactly one unselected copy-only HLS player/session. Ownership transfers at engine load.
@MainActor final class WarmPlayerLease {
    let player = AVPlayer()
    let resource: PlaybackResource
    let server: MediaServer
    var claimed = false
    var primed = false
    var failed: Bool { player.status == .failed || player.currentItem?.status == .failed }
    private var adopted = false
    private var disposed = false
    init(resource: PlaybackResource, server: MediaServer) {
        self.resource = resource; self.server = server
        player.isMuted = true; player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
    }
    func adopt() { adopted = true; claimed = true; player.cancelPendingPrerolls() }
    func dispose() {
        guard !claimed, !adopted, !disposed else { return }; disposed = true
        player.cancelPendingPrerolls(); player.pause(); player.replaceCurrentItem(with: nil)
        let server = server, resource = resource
        Task { try? await MediaClient.shared.stopTranscoding(server: server, resource: resource) }
    }
    deinit {
        if adopted { return }
        if disposed { return }
        do {
            let player = player, server = server, resource = resource
            Task { @MainActor in
                player.cancelPendingPrerolls(); player.pause(); player.replaceCurrentItem(with: nil)
                try? await MediaClient.shared.stopTranscoding(server: server, resource: resource)
            }
        }
    }
}
