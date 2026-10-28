#if DEBUG
import SwiftUI

@MainActor enum ClipFixtures {
    static let collectionID = UUID(uuidString: "11400000-0000-0000-0000-000000000001")!
    static func clips(_ library: LibraryStore) async throws -> [MediaClip] {
        library.showDemo()
        var clips = [MediaClip]()
        for (number, demo, start, end) in [(1,0,1.0,3.0),(2,0,6.0,8.0),(3,1,2.0,4.0)] {
            guard var video = library.videos.first(where: { $0.demoIndex == demo }) else { throw MediaError.message("原创素材缺失。") }
            let resource = try await MediaClient.shared.playback(video: video, server: nil, quality: .original, tracks: TrackSelection())
            let reference = try await MomentResolver.reference(video: video, library: library, resource: resource)
            video = try MomentResolver.storedVideo(video, library: library)
            let moment = MediaMoment(video: video, reference: reference, position: start, duration: video.duration, name: "原创片段 \(number)")
            clips.append(try MediaClip(id: UUID(uuidString: "11400000-0000-0000-0000-00000000001\(number)")!, moment: moment, end: end).validated())
        }
        return clips
    }
}

struct ClipQAView: View {
    var library: LibraryStore
    @State private var ready = false
    @State private var error: String?
    @State private var playing = false
    var body: some View {
        Group {
            if let error { Text(error) }
            else if !ready { ProgressView("准备原创片段…") }
            else if ProcessInfo.processInfo.arguments.contains("--glide-clip-probe") { ClipQAProbe(library: library) }
            else {
                NavigationStack {
                    ClipLibraryView(library: library)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("原创视频") { playing = true }.accessibilityIdentifier("clips.demo") } }
                }.fullScreenCover(isPresented: $playing) {
                    PlayerView(library: library, queue: PlaybackQueue(videos: library.videos, mode: .sequential), returnLabel: "返回片段集")
                }
            }
        }.task {
            UIApplication.shared.isIdleTimerDisabled = true
            do {
                let clips = try await ClipFixtures.clips(library)
                if ProcessInfo.processInfo.arguments.contains("--glide-clip-reset") || ClipStore.shared.snapshot.collections.isEmpty {
                    try ClipStore.shared.change { $0 = ClipLibrarySnapshot(clips: clips, collections: [ClipCollection(id: ClipFixtures.collectionID, name: "原创精选", clipIDs: clips.map(\.id))]) }
                }
                ready = true
            } catch { self.error = error.localizedDescription }
        }.onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

struct ClipQAProbe: View {
    var library: LibraryStore
    @State private var playback = PlaybackController()
    @State private var status = "准备验证"
    @State private var checks: [String] = []
    @State private var failure: String?
    @State private var running = false
    @State private var measurements: [String: Double] = [:]
    var body: some View {
        VStack(spacing: 16) {
            Text(status).accessibilityIdentifier("clips.probe.status")
            VideoSurface(presentation: playback.presentation, onLayer: playback.attachLayer, identity: playback.current?.id ?? "clips", title: "原创片段验证", frameReady: playback.frameReady, locked: true, filled: false, onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in }, subtitleSession: playback.subtitles, secondarySubtitleSession: playback.secondarySubtitles, subtitleClock: { playback.subtitleRenderTime }).frame(height: 240)
            Text("通过 \(checks.count) 项").accessibilityIdentifier("clips.probe.count")
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).accessibilityIdentifier("clips.probe.failure") }
            Button("重新验证") { Task { await run() } }.disabled(running)
        }.padding().task { UIApplication.shared.isIdleTimerDisabled = true; await run() }
            .onDisappear { playback.close(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func check(_ result: Bool, _ name: String) throws {
        guard result else { throw MediaError.message("验证失败：" + name) }; checks.append(name)
    }
    private func wait(_ predicate: @MainActor () -> Bool, seconds: Double = 20) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < end { try await Task.sleep(for: .milliseconds(50)) }
        guard predicate() else { throw MediaError.message("等待超时：" + status + " " + (playback.error ?? "")) }
    }
    private func save(_ passed: Bool) {
        let result: [String: Any] = ["version": PlaybackPreferences.appVersion, "timestamp": ISO8601DateFormatter().string(from: Date()), "passed": passed, "checks": checks, "measurements": measurements, "failure": failure ?? "", "originalMaterialOnly": true]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipQA.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys,.prettyPrinted]) { try? data.write(to: url, options: .atomic) }
    }
    @MainActor private func run() async {
        guard !running else { return }; running = true; checks = []; failure = nil; measurements = [:]
        let oldEngine = UserDefaults.standard.string(forKey: "localPlaybackEngine")
        PlaybackPreferences.localEngine = .avPlayer; playback.close(); playback = PlaybackController()
        defer {
            playback.close(); running = false
            if let oldEngine { UserDefaults.standard.set(oldEngine, forKey: "localPlaybackEngine") } else { UserDefaults.standard.removeObject(forKey: "localPlaybackEngine") }
        }
        do {
            let clips = try await ClipFixtures.clips(library), first = clips[0]
            let history = library.positions, personal = library.personalVideos
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipsQA/contract-v1.json")
            let store = ClipStore(url: root)
            try store.change { $0 = ClipLibrarySnapshot() }
            try store.save(first, to: nil, newName: "验证合集")
            let collectionID = store.snapshot.collections[0].id
            for clip in clips.dropFirst() { try store.save(clip, to: collectionID) }
            try check(store.snapshot.clips.count == 3 && store.snapshot.collections[0].clipIDs.count == 3, "same-file-two-ranges-and-cross-file-collection")
            try store.record(collectionID: collectionID, clipID: clips[1].id, position: 7)
            let reopened = ClipStore(url: root)
            try check(reopened.snapshot.collections[0].cursor?.clipID == clips[1].id && reopened.snapshot.collections[0].cursor?.position == 7, "collection-cursor-restores-after-store-reopen")
            status = "验证系统内核片段边界"
            let video = try MomentResolver.resolve(first.moment, library: library)
            playback.clip = first; playback.open(video, library: library, resumeAt: 1, recordsProgress: true)
            try await wait { playback.frameReady && !playback.isSeeking }
            try check(playback.engineDescriptor.id == .avPlayer && (playback.navigationPosition ?? -1) >= 0.75 && (playback.navigationPosition ?? 99) < first.end, "native-actually-decodes-selected-range")
            let nativeCount = playback.clipCompletedCount
            try await wait { playback.clipCompletedCount > nativeCount }
            let actualEnd = playback.navigationPosition ?? -1; measurements["nativeEndActual"] = actualEnd
            try check(abs(actualEnd - first.end) <= 0.35 && !playback.isPlaybackRequested && playback.completedCount == 0, "native-stops-at-clip-end-without-full-video-completion")
            status = "验证区间定位与循环隔离"
            var long = first; long.end = 9
            playback.clip = long; playback.open(video, library: library, resumeAt: 2, recordsProgress: false)
            try await wait { playback.frameReady && !playback.isSeeking }; playback.pause()
            playback.seek(-100); try await wait { !playback.isSeeking }
            try check(abs((playback.navigationPosition ?? -10) - long.moment.position) <= 0.3, "backward-seek-clamped-to-start")
            playback.seek(999); try await wait { !playback.isSeeking }
            try check((playback.navigationPosition ?? -1) < long.end && (playback.navigationPosition ?? -1) >= long.end - 0.4, "forward-seek-clamped-to-end")
            try check(!playback.setLoop(start: 1, end: 4) && playback.activeSkip == nil, "clip-blocks-loop-and-intro-outro-skips")
            status = "验证同视频下一段"
            playback.clip = clips[1]; playback.open(try MomentResolver.resolve(clips[1].moment, library: library), library: library, resumeAt: 6, recordsProgress: false)
            try await wait { playback.frameReady && !playback.isSeeking }
            try check((playback.navigationPosition ?? -1) >= 5.75 && (playback.navigationPosition ?? 99) < 8, "same-file-second-range-decodes-at-own-start")
            status = "验证跨文件与倍速"
            playback.clip = clips[2]; playback.open(try MomentResolver.resolve(clips[2].moment, library: library), library: library, resumeAt: 2, recordsProgress: false)
            playback.setRate(2)
            try await wait { playback.frameReady && !playback.isSeeking }
            let crossCount = playback.clipCompletedCount
            try check(playback.current?.id == clips[2].moment.video.id, "cross-file-next-range-actually-decodes")
            try await wait { playback.clipCompletedCount > crossCount }
            try check(!playback.isPlaybackRequested && abs((playback.navigationPosition ?? -1) - 4) <= 0.4, "double-speed-keeps-range-boundary")
            status = "验证兼容内核"
            playback.close(); playback.clip = first
            playback.open(video, library: library, resumeAt: 1, recordsProgress: false)
            try await wait { playback.frameReady && !playback.isSeeking }
            playback.pause(); playback.setRate(1); playback.seek(first.moment.position)
            try await wait { !playback.isSeeking }
            playback.switchEngine(to: .vlc)
            playback.play()
            try await wait { playback.engineDescriptor.id == .vlc && playback.frameReady && !playback.isSeeking }
            let vlcCount = playback.clipCompletedCount
            try await wait { playback.clipCompletedCount > vlcCount }
            measurements["vlcEndActual"] = playback.navigationPosition ?? -1
            try check(!playback.isPlaybackRequested && abs((playback.navigationPosition ?? -1) - 3) <= 0.6, "compatibility-engine-stops-at-range-boundary")
            status = "验证离线片段"
            playback.close(); playback = PlaybackController(); PlaybackPreferences.localEngine = .avPlayer
            let offline = try DownloadStore.shared.installClipQAFile()
            let offlineResource = try DownloadStore.shared.offlineResource(offline)
            let offlineReference = try await MomentResolver.reference(video: offline, library: library, resource: offlineResource)
            let offlineClip = try MediaClip(moment: MediaMoment(video: offline, reference: offlineReference, position: 2, duration: 12, name: "离线"), end: 4).validated()
            playback.clip = offlineClip
            playback.open(try MomentResolver.resolve(offlineClip.moment, library: library), library: library, resumeAt: 2, recordsProgress: false)
            try await wait { playback.frameReady && !playback.isSeeking }
            try check(playback.current?.offlineOnly == true && playback.resource?.url.isFileURL == true && library.servers.isEmpty, "offline-clip-decodes-with-origin-server-absent")
            let offlineCount = playback.clipCompletedCount
            try await wait { playback.clipCompletedCount > offlineCount }
            try check(!playback.isPlaybackRequested && abs((playback.navigationPosition ?? -1) - 4) < 0.4, "offline-clip-keeps-range-boundary")
            status = "验证版本变化拦截"
            playback.close(); var changed = first; changed.moment.reference.revision = "replaced"
            playback.clip = changed; playback.open(video, library: library, resumeAt: 1, recordsProgress: false)
            try await wait { playback.error != nil }
            try check(!playback.frameReady && playback.error?.contains("版本已变化") == true, "changed-file-rejected-before-first-frame")
            playback.close()
            try check(library.positions == history && library.personalVideos == personal, "clip-playback-never-mutates-full-video-progress")
            try store.change { $0.removeClip(first.id) }
            try check(store.snapshot.clips.count == 2 && FileManager.default.fileExists(atPath: Bundle.main.url(forResource: "demo0", withExtension: "mp4")!.path), "deleting-clip-retains-original-video")
            try store.change { $0.collections.removeAll() }
            try check(store.snapshot.clips.count == 2, "deleting-collection-retains-clips")
            // Preserve one valid backup, then exercise actual RecoverableStore fallback.
            try store.save(clips[2], to: nil)
            try Data("invalid-json".utf8).write(to: root)
            let recovered = ClipStore(url: root)
            try check(recovered.message?.contains("备份") == true && !recovered.snapshot.clips.isEmpty, "corrupted-primary-recovers-previous-snapshot")
            try check(DownloadStore.directory.lastPathComponent == "OfflineClipsQA", "isolated-qa-storage-no-private-media")
            status = "验证通过"; save(true)
        } catch { failure = error.localizedDescription; status = "验证失败"; save(false) }
    }
}
#endif
