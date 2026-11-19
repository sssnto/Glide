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
            PlayerView(library: library, queue: PlaybackQueue(videos: playbackVideos, mode: .sequential), scopeName: "原创 Duo 验证", loadFullQueue: { playbackVideos }, returnLabel: "返回 Duo 验证")
        }.task {
            UIApplication.shared.isIdleTimerDisabled = true
            guard !ready else { return }
            do {
                let zoomQA = ProcessInfo.processInfo.arguments.contains("--glide-zoom-4k")
                let landscapeQA = ProcessInfo.processInfo.arguments.contains("--glide-duo-landscape")
                let root = LocalMediaStore.managedDirectory(Self.sourceID).appendingPathComponent(landscapeQA ? "LandscapeQA" : zoomQA ? "Zoom4KQA" : "")
                try FileManager.default.createDirectory(at: root.appendingPathComponent("原创目录"), withIntermediateDirectories: true)
                for index in 1...16 {
                    let name = index <= 2 ? "连续播放 \(index).mp4" : "原创海岸 \(index).mp4"
                    let target = root.appendingPathComponent(name)
                    let resource = index <= 2 ? (landscapeQA ? "ass-style-qa" : "duo-continuity") : "demo\(index % 3)"
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
    private var playbackVideos: [Video] {
        library.videos.filter { video in
            guard video.title.contains("连续播放") else { return false }
            let path = video.localRelativePath ?? video.url?.path ?? ""
            if ProcessInfo.processInfo.arguments.contains("--glide-duo-landscape") { return path.contains("LandscapeQA/") }
            if ProcessInfo.processInfo.arguments.contains("--glide-zoom-4k") { return path.contains("Zoom4KQA/") }
            return !path.contains("LandscapeQA/") && !path.contains("Zoom4KQA/")
        }.map { original in
            guard ProcessInfo.processInfo.arguments.contains("--glide-duo-player-metadata") else { return original }
            var video = original
            video.title = "向着山野出发，寻找藏在四季里的风景"
            video.seriesTitle = "原创风景：走过山川与海岸的四季"
            video.mediaType = "Episode"; video.seasonNumber = 1; video.episodeNumber = 2
            return video
        }
    }
}

/// Exercises the production grid with changing proposals and native tab/toolbar chrome.
/// The optional trailing panel is a controlled resize test, not a simulated Duo pose.
@available(iOS 18, *)
struct GridLayoutQAView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var section = 1
    @State private var reserved = false
    @State private var query = ""
    @State private var selected = Set<Int>()
    @State private var viewport = CGRect.zero
    @State private var grid = CGRect.zero
    @State private var foregrounds = 0
    var body: some View {
        TabView(selection: $section) {
            Tab("观看", systemImage: "play.rectangle.fill", value: 0) { Text("原创观看页") }
            Tab("片库", systemImage: "square.stack.fill", value: 1) { catalog }
            Tab("收藏", systemImage: "heart.fill", value: 2) { Text("原创收藏页") }
            Tab("任务", systemImage: "arrow.down.circle", value: 3) { Text("原创任务页") }
        }.tabViewStyle(.sidebarAdaptable)
            .onChange(of: scenePhase) { _, phase in if phase == .active { foregrounds += 1 } }
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
    private var catalog: some View {
        NavigationStack {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("原创节目").font(.headline)
                            AdaptiveMediaGrid(minimum: 110) {
                                ForEach(0..<30, id: \.self) { index in
                                    Button {
                                        if !selected.insert(index).inserted { selected.remove(index) }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            RoundedRectangle(cornerRadius: 10).fill(selected.contains(index) ? Color.accentColor : Color.indigo.opacity(0.5))
                                                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                                .overlay { Image(systemName: "film").font(.title) }
                                            Text("原创海岸 \(index + 1)").font(.subheadline)
                                        }
                                    }.buttonStyle(.plain).accessibilityIdentifier("grid.qa.cell.\(index)")
                                        .accessibilityValue(selected.contains(index) ? "已选择" : "未选择")
                                }
                            }.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { grid = $0 }
                        }.padding(16)
                    }.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { viewport = $0 }
                    if reserved {
                        Color.orange.opacity(0.2).overlay { Text("预留区域").rotationEffect(.degrees(90)) }
                            .frame(width: geometry.size.width * 0.3)
                            .accessibilityIdentifier("grid.qa.reserved")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("已选择 \(selected.count) 个 · 前台恢复 \(foregrounds) 次").font(.caption)
                    .frame(maxWidth: .infinity, minHeight: 28).background(.bar)
                    .accessibilityIdentifier("grid.qa.metrics").accessibilityValue(metrics)
            }
            .navigationTitle("片库布局验证").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索节目")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("切换预留区域", systemImage: "sidebar.trailing") { reserved.toggle() }
                        .accessibilityIdentifier("grid.qa.toggleReserve")
                }
            }
        }
    }
    private var metrics: String {
        let values: [String: Double] = ["viewportMinX": viewport.minX, "viewportMaxX": viewport.maxX,
            "viewportWidth": viewport.width, "gridWidth": grid.width, "foregrounds": Double(foregrounds),
            "selected": Double(selected.count), "reserved": reserved ? 1 : 0]
        return (try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
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
            "expanded": expanded, "zoom": interaction.zoom, "layer": String(describing: ObjectIdentifier(interaction.videoLayer)),
            "pipActive": playback.pictureInPicture.active, "pipStarting": playback.pictureInPicture.starting,
            "pipDiagnostics": playback.pictureInPicture.diagnostics,
            "isPlaying": playback.isPlaying, "timestamp": ISO8601DateFormatter().string(from: Date()),
            "error": playback.error ?? "", "originalMaterialOnly": true]
        if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]) {
            let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DuoPlaybackQA.json")
            try? data.write(to: path, options: .atomic)
        }
    }
}
#endif
