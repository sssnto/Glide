#if DEBUG
import SwiftUI

/// Authored assets and isolated stores only. This is not a synthetic display/pose override.
struct DuoQAView: View {
    var library: LibraryStore
    @State private var ready = false
    @State private var error: String?
    @State private var playing = false
    private static let sourceID = UUID(uuidString: "11500000-0000-0000-0000-000000000001")!
    var body: some View {
        Group {
            if let error { Text(error) }
            else if ready {
                AdaptiveLibraryRoot(library: library)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Button("播放长样例") { playing = true }
                            .accessibilityIdentifier("duo.play")
                            .buttonStyle(.bordered).frame(maxWidth: .infinity).background(.bar)
                    }
            } else { ProgressView("准备原创 Duo 样例…") }
        }.fullScreenCover(isPresented: $playing) {
            PlayerView(library: library, queue: PlaybackQueue(videos: library.videos.filter { $0.title.contains("连续播放") }, mode: .sequential), scopeName: "原创 Duo 验证", returnLabel: "返回 Duo 验证")
        }.task {
            UIApplication.shared.isIdleTimerDisabled = true
            guard !ready else { return }
            do {
                let zoomQA = ProcessInfo.processInfo.arguments.contains("--glide-zoom-4k")
                let root = zoomQA ? LocalMediaStore.managedDirectory(Self.sourceID).appendingPathComponent("Zoom4KQA") : LocalMediaStore.managedDirectory(Self.sourceID)
                try FileManager.default.createDirectory(at: root.appendingPathComponent("原创目录"), withIntermediateDirectories: true)
                for index in 1...16 {
                    let name = index <= 2 ? "连续播放 \(index).mp4" : "原创海岸 \(index).mp4"
                    let target = root.appendingPathComponent(name)
                    let resource = index <= 2 ? "duo-continuity" : "demo\(index % 3)"
                    let source: URL
                    if zoomQA, index <= 2 {
                        source = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ZoomQA4K.mp4")
                        guard FileManager.default.fileExists(atPath: source.path) else { throw MediaError.message("请先安装原创 4K 缩放验证素材。") }
                    } else if let bundled = Bundle.main.url(forResource: resource, withExtension: "mp4") { source = bundled }
                    else { throw MediaError.message("原创素材缺失。") }
                    if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: source, to: target) }
                }
                let nested = root.appendingPathComponent("原创目录/目录片段.mp4")
                if !FileManager.default.fileExists(atPath: nested.path), let source = Bundle.main.url(forResource: "demo1", withExtension: "mp4") { try FileManager.default.copyItem(at: source, to: nested) }
                library.servers = [MediaServer(id: Self.sourceID, name: "Duo 验证片库", kind: .local, address: root, username: "")]
                await library.select(Self.sourceID)
                ready = true
                if ProcessInfo.processInfo.arguments.contains("--glide-duo-continuity") || ProcessInfo.processInfo.arguments.contains("--glide-zoom-inapp-probe") { playing = true }
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor enum DuoPlaybackEvidence {
    static func event(_ name: String, session: UUID) {
        guard ProcessInfo.processInfo.arguments.contains("--glide-duo-fixture") else { return }
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DuoUIEvents.json")
        var events = (try? Data(contentsOf: path)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: String]] } ?? []
        events.append(["session": session.uuidString, "event": name, "at": ISO8601DateFormatter().string(from: Date())])
        if let data = try? JSONSerialization.data(withJSONObject: Array(events.suffix(100)), options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: path, options: .atomic) }
    }
    static func save(_ playback: PlaybackController, session: UUID, size: CGSize, expanded: Bool, interaction: VideoInteractionState) {
        guard ProcessInfo.processInfo.arguments.contains("--glide-duo-fixture") else { return }
        let evidence: [String: Any] = ["session": session.uuidString, "openAttempts": playback.openAttemptCount,
            "video": playback.current?.title ?? "", "time": playback.time, "rate": playback.rate,
            "requested": playback.isPlaybackRequested, "frameReady": playback.frameReady,
            "engine": playback.engineDescriptor.title, "audio": playback.selectedAudio?.id ?? "",
            "subtitle": playback.selectedSubtitle?.id ?? "", "width": size.width, "height": size.height,
            "expanded": expanded, "zoom": interaction.zoom, "timestamp": ISO8601DateFormatter().string(from: Date()),
            "error": playback.error ?? "", "originalMaterialOnly": true]
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]) {
            let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DuoPlaybackQA.json")
            try? data.write(to: path, options: .atomic)
        }
    }
}
#endif
