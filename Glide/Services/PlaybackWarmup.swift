import AVFoundation
import Network

/// One short-lived asset, never a second running player or a speculative transcode.
@MainActor final class PlaybackWarmup {
    struct Prepared {
        let key: String
        let resource: PlaybackResource
        let asset: AVURLAsset
        let loader: AuthenticatedAsset?
        let expires: Date
    }
    private let monitor = NWPathMonitor()
    private var wifi = false
    private var prepared: Prepared?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var asset: AVURLAsset?
    private var token = UUID()
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.wifi = path.status == .satisfied && path.usesInterfaceType(.wifi)
                if self?.wifi == false { self?.cancel() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "Glide.playback.warmup.path"))
    }
    private func key(_ video: Video, _ server: MediaServer?) -> String {
        // Account/token changes invalidate an in-memory resource; never persist this key.
        video.id + ":" + (server?.address.absoluteString ?? "local") + ":" + (server?.userID ?? "") + ":" + (server.map { Credentials.read($0.id) ?? "" } ?? "")
    }
    func take(_ video: Video, server: MediaServer?) -> Prepared? {
        guard let ready = prepared, ready.key == key(video, server), ready.expires > Date() else { return nil }
        prepared = nil; asset = nil
        return ready
    }
    func prepare(_ video: Video, server: MediaServer?) async {
        let local = DownloadStore.shared.localURL(videoID: video.id) ?? (video.url?.isFileURL == true ? video.url : nil)
        guard (wifi || local != nil), !ProcessInfo.processInfo.isLowPowerModeEnabled,
              !PlaybackRouteMemory().prefersVideoConversion(for: video.id),
              PlaybackPreferences.audioLanguage.isEmpty, PlaybackPreferences.subtitleLanguage.isEmpty,
              !PlaybackPreferences.subtitlesOff, !PlaybackPreferences.forcedOnly else { cancel(); return }
        let identity = key(video, server)
        if prepared?.key == identity, prepared!.expires > Date() { return }
        cancel()
        let request = UUID(); token = request
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let resource: PlaybackResource
                if let local { resource = PlaybackResource(url: local, delivery: .local) }
                else { resource = try await MediaClient.shared.playback(video: video, server: server, directOnly: true) }
                try Task.checkCancellation()
                guard token == request, !resource.isTranscoding else { return }
                let loader = resource.headers.isEmpty ? nil : AuthenticatedAsset(url: resource.url, headers: resource.headers, allowsCellular: false)
                let candidate = loader?.asset ?? AVURLAsset(url: resource.url, options: [AVURLAssetAllowsCellularAccessKey: false])
                asset = candidate
                let playable = try await candidate.load(.isPlayable)
                try Task.checkCancellation()
                guard token == request, playable else { return }
                prepared = Prepared(key: identity, resource: resource, asset: candidate, loader: loader, expires: Date().addingTimeInterval(30))
                deadline?.cancel(); deadline = nil
            } catch { if token == request { asset?.cancelLoading(); asset = nil; prepared = nil } }
        }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, token == request else { return }
            cancel()
        }
        await withTaskCancellationHandler { await work?.value } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(request: request) }
        }
    }
    private func cancel(request: UUID) { if token == request { cancel() } }
    func cancel() {
        token = UUID(); work?.cancel(); work = nil; deadline?.cancel(); deadline = nil
        asset?.cancelLoading(); asset = nil; prepared?.loader?.cancel(); prepared = nil
    }
    deinit { monitor.cancel(); work?.cancel(); deadline?.cancel() }
}
