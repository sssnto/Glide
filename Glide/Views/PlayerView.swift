import SwiftUI
import AVKit
import UIKit
import UniformTypeIdentifiers

struct PlayerView: View {
    var library: LibraryStore
    @State var queue: PlaybackQueue
    var scopeName = "离线演示"
    var cinematic = false
    var initialTracks = TrackSelection()
    var initialResumeAt: Double?
    var loadFullQueue: (() async throws -> [Video])? = nil
    private var isCinema: Bool { cinematic || ["Movie", "Episode"].contains(current.mediaType ?? "") }
    private var isEpisode: Bool { current.mediaType == "Episode" }
    @AppStorage("playbackMode") private var preferredMode: PlaybackMode = .sequential
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var playback = PlaybackController()
    @State private var controls = true
    @State private var quickMenuHolding = false
    @State private var locked = false
    @State private var filled = false
    @State private var hud: String?
    @State private var hudTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?
    @State private var suppressTapUntil = Date.distantPast
    @State private var settingsOpen = false
    private enum SettingsAction { case diagnostic, videoInfo, subtitleImport }
    @State private var pendingSettingsAction: SettingsAction?
    @State private var diagnosticOpen = false
    @State private var videoInfoOpen = false
    @State private var pathCopied = false
    @State private var episodesOpen = false
    @State private var videoDetail: CatalogItem?
    @State private var importingSubtitle = false
    @State private var externalSubtitles: [SubtitleCue] = []
    @State private var subtitleDelay = 0.0
    @State private var subtitleMessage: String?
    @AppStorage("externalSubtitleBottom") private var subtitleBottom = 12.0
    @State private var initialOrientation: UIInterfaceOrientation?
    @State private var manuallyRotated = false
    @State private var queueLoading = false
    @State private var queueLoadError = false
    @State private var queueExpansionComplete = false
    @State private var queueReload = 0
    @State private var pendingAutomaticAdvance = false
    @State private var scrubTarget: Double?
    private var current: Video { queue.current! } // Presented only after collecting a nonempty queue.
    private var nextVideo: Video? { queue.canGoForward ? queue.ordered[queue.index + 1] : nil }
    private var warmupKey: String {
        current.id + ":" + (nextVideo?.id ?? "") + ":\(playback.frameReady):\(playback.loading):\(playback.isPlaying):\(playback.rate):\(scenePhase == .active)"
    }
    private var selectedMediaSource: CatalogItem.Source? {
        if let id = playback.resource?.mediaSourceID ?? playback.tracks.mediaSourceID { return videoDetail?.MediaSources?.first { $0.Id == id } }
        return videoDetail?.MediaSources?.first
    }
    private var filePath: String? {
        if let url = playback.resource?.url, url.isFileURL { return MediaFilePath.display(url.absoluteString) }
        if let path = MediaFilePath.display(playback.resource?.sourcePath) { return path }
        if let path = MediaFilePath.display(selectedMediaSource?.Path) { return path }
        // WebDAV has a file URL; a Jellyfin /stream URL is not the source path.
        if current.remoteID == nil { return MediaFilePath.display((playback.resource?.url ?? current.url)?.absoluteString) }
        return nil
    }
    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(presentation: playback.presentation, onLayer: { playback.attachLayer($0) }, identity: current.id, title: current.title,
                    frameReady: playback.frameReady, locked: locked, filled: filled,
                    onSwipe: { if !isCinema || isEpisode { move($0) } },
                    onToggle: { playback.toggle(); scheduleHideAfterInteraction() }, onSeek: {
                        // SpatialTapGesture can also complete when a long press is released.
                        suppressTapUntil = Date().addingTimeInterval(0.5)
                        playback.seek(playback.time + $0); scheduleHideAfterInteraction()
                    },
                    onSpeedPreset: { playback.setRate($0); scheduleHideAfterInteraction() }, onHUD: showHUD)
                    .ignoresSafeArea()
                if !playback.frameReady && playback.error == nil {
                    if let server = library.servers.first(where: { $0.id == current.sourceID }), server.kind == .jellyfin, let id = current.remoteID {
                        CatalogArtwork(item: CatalogItem(Id: id, Name: current.title, Type: current.mediaType), server: server, contentMode: .fit).opacity(0.45).allowsHitTesting(false)
                    } else { VideoArtwork(video: current, contentMode: .fit).opacity(0.45).allowsHitTesting(false) }
                }
                PlayerSubtitleOverlay(playback: playback, cues: externalSubtitles, delay: subtitleDelay,
                                      bottomInset: geometry.size.height * subtitleBottom / 100)
                if controls {
                    LinearGradient(stops: [.init(color: .black.opacity(0.65), location: 0), .init(color: .clear, location: 0.3), .init(color: .clear, location: 0.55), .init(color: .black.opacity(0.85), location: 1)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
                    VStack {
                        if locked { HStack { Spacer(); RoundControl(symbol: "lock.fill", label: "解锁触控") { locked = false; scheduleHideAfterInteraction() } } }
                        else { topBar }
                        Spacer()
                        if !locked { bottomControls(compact: landscape) }
                    }.padding(.horizontal, landscape ? 28 : 20).padding(.top, 4).padding(.bottom, 8)
                    .transition(.opacity)
                }
                if playback.loading && !playback.frameReady && playback.error == nil {
                    VStack(spacing: 12) { ProgressView().tint(GlideTheme.accent).scaleEffect(1.2); Text("正在准备画面…").font(.caption).foregroundStyle(.white.opacity(0.7)) }
                        .padding(22).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 20)).allowsHitTesting(false)
                }
                if let hud {
                    Text(hud).font(.system(size: 15, weight: .semibold, design: .rounded)).padding(.horizontal, 22).padding(.vertical, 15).background(.ultraThinMaterial, in: Capsule()).allowsHitTesting(false)
                }
                if let error = playback.error {
                    VStack(spacing: 18) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(GlideTheme.accent)
                        Text("暂时无法播放").font(.title3.bold())
                        Text(error).accessibilityIdentifier("player.error").font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        if playback.canSwitchEngine {
                            Button(playback.engineDescriptor.id == .avPlayer ? "尝试兼容播放" : "返回系统播放") {
                                suppressTapUntil = Date().addingTimeInterval(0.5)
                                controls = true
                                playback.switchEngine(to: playback.engineDescriptor.id == .avPlayer ? .vlc : .avPlayer)
                            }.buttonStyle(.bordered).accessibilityIdentifier("player.switchAfterFailure")
                        }
                        HStack {
                            Button("返回片库") { dismiss() }
                            Spacer()
                            Button("播放诊断") { diagnosticOpen = true }
                            Button("重试") { playback.open(current, library: library, recordsProgress: isCinema) }.buttonStyle(.borderedProminent).tint(GlideTheme.accent).foregroundStyle(.black)
                        }
                    }.padding(26).frame(maxWidth: 370).background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 24)).padding(24)
                }
            }
            .simultaneousGesture(SpatialTapGesture().onEnded { touch in
                // Keep the tap above the video renderer, including after the
                // controls fade away. Buttons retain their own touch targets.
                guard Date() >= suppressTapUntil else { return }
                if controls && (touch.location.y < 110 || touch.location.y > geometry.size.height - (landscape ? 150 : 230)) { return }
                toggleControls()
            })
        }
        .statusBarHidden(!controls)
        .persistentSystemOverlays(controls ? .visible : .hidden)
        .onAppear {
            initialOrientation = ScreenRotation.activeScene?.interfaceOrientation
            UIApplication.shared.isIdleTimerDisabled = true
            playback.tracks = initialTracks
            var autoplay = true
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--glide-format-fixtures") {
                autoplay = !UserDefaults.standard.bool(forKey: "glideQAStartPaused")
            }
#endif
            playback.open(current, library: library, resumeAt: initialResumeAt, autoplay: autoplay, recordsProgress: isCinema); scheduleHide()
        }
        .onDisappear {
            scrubTarget = nil
            playback.pictureInPicture.stop(); playback.close(); hudTask?.cancel(); hideTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
            if manuallyRotated, let initialOrientation { ScreenRotation.request(ScreenRotation.mask(for: initialOrientation)) { _ in } }
        }
        .task(id: queueReload) { await expandQueue() }
        .task(id: warmupKey) {
            guard playback.frameReady, !playback.loading, playback.isPlaying,
                  playback.rate == 1, scenePhase == .active, let nextVideo else { playback.cancelWarmup(); return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await playback.prepareNext(nextVideo, library: library)
        }
        .fileImporter(isPresented: $importingSubtitle, allowedContentTypes: [.plainText, UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard size <= 2_000_000 else { subtitleMessage = "字幕文件超过 2 MB，请使用较小的 SRT/VTT 文件。"; return }
                let cues = SubtitleCue.parse(try String(contentsOf: url, encoding: .utf8))
                guard !cues.isEmpty else { subtitleMessage = "没有识别到字幕，请使用 UTF-8 编码的 SRT/VTT 文件。"; return }
                externalSubtitles = cues; subtitleDelay = 0; playback.selectSubtitle(nil); subtitleMessage = "已导入字幕，仅用于当前视频。"
            } catch { subtitleMessage = "字幕导入未完成，请重试。" }
            controls = true; settingsOpen = true
        }
        .onChange(of: current.id) { _, _ in externalSubtitles = []; subtitleDelay = 0; subtitleMessage = nil }
        .onChange(of: current.id) { _, _ in scrubTarget = nil }
        .sheet(isPresented: $diagnosticOpen, onDismiss: { scheduleHide() }) {
            NavigationStack { DiagnosticView(diagnostic: playback.diagnostic).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { diagnosticOpen = false } } } }
        }
        .sheet(isPresented: $videoInfoOpen, onDismiss: { scheduleHide() }) { videoInfoPanel }
        .sheet(isPresented: $settingsOpen, onDismiss: {
            let action = pendingSettingsAction; pendingSettingsAction = nil
            switch action {
            case .diagnostic: diagnosticOpen = true
            case .videoInfo: videoInfoOpen = true
            case .subtitleImport: importingSubtitle = true
            case nil: scheduleHide()
            }
        }) { settingsPanel }
        .sheet(isPresented: $episodesOpen, onDismiss: { scheduleHide() }) {
            EpisodePickerView(videos: queue.source.filter { $0.mediaType == "Episode" }, currentID: current.id,
                              loading: queueLoading, failed: queueLoadError,
                              onRetry: { queueReload += 1 }, onSelect: selectEpisode)
        }
        .task(id: videoInfoOpen ? current.id : "") {
            pathCopied = false
            guard videoInfoOpen, let server = library.servers.first(where: { $0.id == current.sourceID }),
                  server.kind == .jellyfin, let id = current.remoteID else { videoDetail = nil; return }
            videoDetail = nil
            let detail = try? await MediaClient.shared.catalogDetail(server: server, id: id)
            guard !Task.isCancelled, current.remoteID == id else { return }
            videoDetail = detail
        }
        .onChange(of: settingsOpen) { _, open in if open { hideTask?.cancel() } else { scheduleHide() } }
        .onChange(of: episodesOpen) { _, open in if open { hideTask?.cancel() } else { scheduleHide() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background && !playback.pictureInPicture.active && !playback.externalPlaybackActive { playback.pause(); controls = true } }
        .onChange(of: playback.isPlaying) { _, playing in if playing { scheduleHide() } else if !playback.loading { controls = true } }
        .onChange(of: playback.completedCount) { _, _ in if scenePhase == .active { advance(1, automatic: true) } }
        .onChange(of: playback.playbackNotice) { _, notice in
            if notice != nil { controls = true; scheduleHide() }
        }
        .onChange(of: playback.error) { _, error in if error != nil { controls = true; hideTask?.cancel() } }
        .onChange(of: voiceOverEnabled) { _, enabled in
            if enabled { hideTask?.cancel(); controls = true } else { scheduleHide() }
        }
    }
    private var topBar: some View {
        HStack(spacing: 10) {
            RoundControl(symbol: "chevron.down", label: "返回片库") { dismiss() }
            VStack(alignment: .leading, spacing: 3) {
                Text(current.title).font(GlideTheme.Typography.itemTitle).lineLimit(1).foregroundStyle(.white)
                Text((isEpisode && !episodePosition.isEmpty ? episodePosition + " · " : "") + "\(queue.index + 1) / \(queue.ordered.count)" + (queueLoading ? (isEpisode ? " · 正在加载剧集" : " · 正在补全目录") : ""))
                    .font(.caption2).monospacedDigit().foregroundStyle(.white.opacity(0.58))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RoundControl(symbol: "lock.open", label: "锁定触控") { locked = true; showHUD("已锁定触控"); scheduleHideAfterInteraction() }
            RoundControl(symbol: "ellipsis", label: "播放设置") {
                quickMenuHolding = false; hideTask?.cancel(); settingsOpen = true
            }
        }
    }
    private var settingsPanel: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Button { pendingSettingsAction = .videoInfo; settingsOpen = false } label: {
                            Label("视频信息", systemImage: "info.circle")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        Divider()
                        Button { pendingSettingsAction = .diagnostic; settingsOpen = false } label: {
                            Label("播放诊断", systemImage: "waveform.path.ecg")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.accessibilityIdentifier("player.diagnostic")
                    }.font(.footnote.weight(.medium))
                }
                if playback.canPlayOnline || playback.showsOriginalTransport || playback.originalTransportActive {
                    Section("在线播放") {
                        if playback.canPlayOnline {
                            Button("在线播放", systemImage: "network") { playback.playOnline(); settingsOpen = false }
                                .accessibilityIdentifier("player.online")
                            Text("保留离线文件，使用服务器播放。").font(.caption).foregroundStyle(.secondary)
                        }
                        if playback.showsOriginalTransport {
                            Button(playback.originalTransportTitle, systemImage: "arrow.triangle.2.circlepath") { playback.tryOriginalTransport(); settingsOpen = false }
                                .accessibilityIdentifier("player.transport.original")
                                .disabled(!playback.canTryOriginalTransport)
                            Text(playback.originalTransportDetail).font(.caption).foregroundStyle(.secondary)
                        } else if playback.originalTransportActive {
                            Label("原画兼容已开启", systemImage: "checkmark.circle")
                                .foregroundStyle(GlideTheme.accent)
                                .accessibilityIdentifier("player.transport.active")
                        }
                    }
                }
                Section("播放调整") {
                    Menu { speedMenuItems } label: {
                        PlayerSettingsLabel(title: "播放速度", symbol: "speedometer", value: "\(playback.rate.formatted())×")
                    }.accessibilityIdentifier("player.speed.menu")
                    Menu { audioMenuItems } label: {
                        PlayerSettingsLabel(title: "音轨", symbol: "waveform", value: playback.audioOptions.isEmpty ? "无可切换音轨" : playback.selectedAudio?.displayName ?? "默认")
                    }.accessibilityIdentifier("player.audio.menu").disabled(playback.audioOptions.isEmpty)
                    Menu { subtitleMenuItems } label: {
                        PlayerSettingsLabel(title: "字幕", symbol: "captions.bubble", value: subtitleSelectionTitle)
                    }.accessibilityIdentifier("player.subtitle.menu")
                    if playback.engineDescriptor.capabilities.contains(.aspectFill) {
                        Button { filled.toggle() } label: {
                            PlayerSettingsLabel(title: filled ? "完整显示画面" : "填满屏幕", symbol: "arrow.up.left.and.arrow.down.right", value: filled ? "已填满" : "适应")
                        }
                    }
                    if !isCinema {
                        Menu {
                            ForEach(PlaybackMode.allCases) { mode in
                                Button { changeMode(mode) } label: {
                                    Label(mode.title + (queue.mode == mode ? " ✓" : ""), systemImage: mode.symbol)
                                }
                            }
                        } label: {
                            PlayerSettingsLabel(title: "播放顺序", symbol: queue.mode.symbol, value: queue.mode.title)
                        }
                    }
                }
                if playback.canSwitchEngine {
                    Section {
                        Button("系统播放" + (playback.engineDescriptor.id == .avPlayer ? " ✓" : "")) { playback.switchEngine(to: .avPlayer) }
                            .accessibilityIdentifier("player.engine.native")
                        Button("兼容播放" + (playback.engineDescriptor.id == .vlc ? " ✓" : "")) { playback.switchEngine(to: .vlc) }
                            .accessibilityIdentifier("player.engine.compatibility")
                    } header: { Text("本地播放器") } footer: {
                        Text("切换后保留当前位置，选择会用于接下来的本地视频。")
                    }
                }
                if playback.engineDescriptor.capabilities.contains(.pictureInPicture) || playback.engineDescriptor.capabilities.contains(.externalPlayback) {
                    Section("播放设备") {
                        if playback.engineDescriptor.capabilities.contains(.pictureInPicture) {
                            Button("画中画", systemImage: "pip") { playback.pictureInPicture.toggle(); if playback.pictureInPicture.possible { settingsOpen = false } }
                                .accessibilityIdentifier("player.pip")
                            if let message = playback.pictureInPicture.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        }
                        if playback.engineDescriptor.capabilities.contains(.externalPlayback) {
                            HStack {
                                Label("AirPlay 播放设备", systemImage: "airplay.video")
                                Spacer()
                                AirPlayControl().frame(width: 44, height: 44)
                            }
                        }
                    }
                }
                Section("外部字幕") {
                    Button("导入 SRT / VTT 字幕", systemImage: "doc.badge.plus") { pendingSettingsAction = .subtitleImport; settingsOpen = false }
                    if !externalSubtitles.isEmpty {
                        Stepper("字幕延迟：\(subtitleDelay, specifier: "%.1f") 秒", value: $subtitleDelay, in: -30...30, step: 0.5)
                        Stepper("字幕底部距离：\(Int(subtitleBottom))%", value: $subtitleBottom, in: 5...35, step: 2)
                        Button("移除外部字幕") { externalSubtitles = [] }
                        Text("外部字幕显示在本机画面中，画中画与 AirPlay 不包含此字幕。").font(.caption).foregroundStyle(.secondary)
                    }
                    if let subtitleMessage { Text(subtitleMessage).font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    Button(library.favorites.contains(current.id) ? "取消收藏" : "收藏视频", systemImage: library.favorites.contains(current.id) ? "heart.fill" : "heart") { library.toggleFavorite(current); settingsOpen = false }
                    if playback.syncError != nil { Button("重试同步进度") { playback.save(); playback.report("Progress") } }
                }
            }
            .font(GlideTheme.Typography.body)
            .buttonStyle(.plain)
            .tint(GlideTheme.accent)
            .accessibilityIdentifier("player.settings.list")
            .navigationTitle("播放设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { settingsOpen = false }.accessibilityIdentifier("player.settings.done")
            } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
    private var subtitleSelectionTitle: String {
        !externalSubtitles.isEmpty ? "外部字幕" : playback.selectedSubtitle?.displayName ?? "关闭"
    }
    @ViewBuilder private var speedMenuItems: some View {
        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
            Button("\(rate.formatted())×" + (playback.rate == Float(rate) ? " ✓" : "")) { playback.setRate(Float(rate)); scheduleHideAfterInteraction() }
        }
    }
    @ViewBuilder private var audioMenuItems: some View {
        ForEach(playback.audioOptions) { option in
            Button(option.displayName + (playback.selectedAudio == option ? " ✓" : "")) { playback.selectAudio(option); scheduleHideAfterInteraction() }
                .accessibilityIdentifier("player.audio." + option.id)
        }
        if playback.audioOptions.isEmpty { Text("当前流没有可选音轨") }
    }
    @ViewBuilder private var subtitleMenuItems: some View {
        Button("关闭字幕" + (playback.selectedSubtitle == nil && externalSubtitles.isEmpty ? " ✓" : "")) { externalSubtitles = []; playback.selectSubtitle(nil); scheduleHideAfterInteraction() }
        ForEach(playback.subtitleOptions) { option in
            Button(option.displayName + (playback.selectedSubtitle == option && externalSubtitles.isEmpty ? " ✓" : "")) { externalSubtitles = []; playback.selectSubtitle(option); scheduleHideAfterInteraction() }
                .accessibilityIdentifier("player.subtitle." + option.id)
        }
        if playback.subtitleOptions.isEmpty { Text("当前流没有可选字幕") }
        Divider()
        Button("导入 SRT / VTT 字幕") {
            quickMenuHolding = false; hideTask?.cancel()
            if settingsOpen { pendingSettingsAction = .subtitleImport; settingsOpen = false }
            else { importingSubtitle = true }
        }
    }
    private var sourceVideoStream: CatalogItem.Stream? {
        playback.resource?.videoStream ?? selectedMediaSource?.MediaStreams?.first { $0.Type == "Video" }
    }
    private var videoInfoPanel: some View {
        NavigationStack {
            Form {
                Section("媒体") {
                    Text(current.title).font(GlideTheme.Typography.itemTitle)
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent("时长", value: playback.duration.mediaTime)
                    if let source = library.servers.first(where: { $0.id == current.sourceID }) {
                        LabeledContent("来源", value: source.name)
                    }
                    if let type = current.mediaType {
                        LabeledContent("类型", value: type == "Movie" ? "电影" : type == "Episode" ? "剧集" : type == "MusicVideo" ? "音乐视频" : "视频")
                    }
                    if isEpisode, !episodePosition.isEmpty { LabeledContent("集数", value: episodePosition) }
                    if let year = videoDetail?.ProductionYear { LabeledContent("年份", value: String(year)) }
                    if let rating = videoDetail?.OfficialRating { LabeledContent("分级", value: rating) }
                    if let rating = videoDetail?.CommunityRating { LabeledContent("评分", value: String(format: "%.1f / 10", rating)) }
                    if let genres = videoDetail?.Genres, !genres.isEmpty { LabeledContent("分类", value: genres.joined(separator: "、")) }
                }
                Section("视频规格") {
                    if let codec = sourceVideoStream?.Codec ?? playback.diagnostic.videoCodec ?? playback.localInspection?.videoCodec {
                        LabeledContent("视频编码", value: codec.uppercased())
                    }
                    if let width = sourceVideoStream?.Width ?? playback.diagnostic.width,
                       let height = sourceVideoStream?.Height ?? playback.diagnostic.height {
                        LabeledContent("原始尺寸", value: "\(width) × \(height)")
                    }
                    if let frameRate = sourceVideoStream?.AverageFrameRate ?? sourceVideoStream?.RealFrameRate ?? playback.diagnostic.sourceFrameRate, frameRate > 0 {
                        LabeledContent("帧率", value: frameRate.formatted(.number.precision(.fractionLength(0...3))) + " fps")
                    }
                    if let profile = sourceVideoStream?.Profile ?? playback.diagnostic.profile { LabeledContent("编码规格", value: profile) }
                    if let range = sourceVideoStream?.VideoRangeType ?? playback.diagnostic.videoRangeType { LabeledContent("动态范围", value: range) }
                    if let bits = sourceVideoStream?.BitDepth ?? playback.diagnostic.bitDepth { LabeledContent("位深", value: "\(bits) bit") }
                    if let bitrate = playback.diagnostic.sourceBitrate ?? sourceVideoStream?.BitRate, bitrate > 0 {
                        LabeledContent(playback.diagnostic.sourceBitrate == nil ? "视频码率" : "来源总码率", value: MediaInfoFormatting.bitrate(Double(bitrate)))
                    }
                }
                PlayerPlaybackStatusSection(playback: playback)
                if let source = selectedMediaSource {
                    let streams = source.MediaStreams ?? []
                    if streams.contains(where: { $0.Type == "Audio" }) {
                        Section("声音") { ForEach(streams.filter { $0.Type == "Audio" }) { stream in PlayerStreamInfoRow(stream: stream) } }
                    }
                    if streams.contains(where: { $0.Type == "Subtitle" }) {
                        Section("字幕") { ForEach(streams.filter { $0.Type == "Subtitle" }) { stream in PlayerStreamInfoRow(stream: stream) } }
                    }
                }
                Section("文件") {
                    if let container = selectedMediaSource?.Container {
                        LabeledContent("封装", value: container.uppercased()).accessibilityIdentifier("player.info.container")
                    } else if let report = playback.localInspection {
                        LabeledContent("封装", value: report.container.title).accessibilityIdentifier("player.info.container")
                    }
                    if let size = selectedMediaSource?.Size { LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    if let path = filePath {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(playback.resource?.url.isFileURL == true ? "本机文件路径" : "文件路径")
                                Spacer()
                                Button(pathCopied ? "已复制" : "复制路径", systemImage: pathCopied ? "checkmark" : "doc.on.doc") {
                                    UIPasteboard.general.string = path; pathCopied = true
                                }
                                .font(.caption)
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("player.info.copyPath")
                            }
                            Text(path)
                                .font(GlideTheme.Typography.technical)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("player.info.path")
                        }
                    } else { LabeledContent("文件路径", value: "服务器未提供") }
                }
                if let report = playback.localInspection {
                    Section("本机格式检查") {
                        if !report.audioCodecs.isEmpty { LabeledContent("音频编码", value: report.audioCodecs.joined(separator: " / ")) }
                        if let count = report.videoTracks { LabeledContent("视频轨道", value: String(count)) }
                        if let count = report.audioTracks { LabeledContent("音频轨道", value: String(count)) }
                        if let count = report.subtitleTracks { LabeledContent("字幕轨道", value: String(count)) }
                        Text(playback.engineDescriptor.id == .avPlayer ? report.summary : "以实际播放结果为准")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("player.info.formatCheck")
                    }
                }
            }
            .font(GlideTheme.Typography.secondary)
            .environment(\.defaultMinListRowHeight, 32)
            .accessibilityIdentifier("player.info.list")
            .navigationTitle("视频信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { videoInfoOpen = false } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
    private func bottomControls(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 8) {
            PlayerTimeline(playback: playback, identity: current.id, scrubTarget: $scrubTarget,
                           onScrubStart: { quickMenuHolding = false; hideTask?.cancel() }, onScrubEnd: scheduleHideAfterInteraction)
            if compact && !dynamicTypeSize.isAccessibilitySize {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        transportControls(compact: true)
                        playbackActions(compact: true)
                    }
                    VStack(spacing: 0) {
                        transportControls(compact: true).frame(maxWidth: .infinity)
                        playbackActions(compact: true)
                    }
                }
            } else {
                transportControls(compact: compact).frame(maxWidth: .infinity)
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView(.horizontal) { playbackActions(compact: compact).fixedSize(horizontal: true, vertical: false) }
                } else { playbackActions(compact: false) }
            }
            if let notice = playback.playbackNotice { Text(notice).font(.caption2).foregroundStyle(GlideTheme.accent).lineLimit(2) }
            if let warning = playback.syncError { Text(warning).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
            if queueLoadError {
                Button(isEpisode ? "剧集列表加载失败，重试" : "剩余视频加载失败，重试") { queueReload += 1 }
                    .font(.caption2).foregroundStyle(.orange).frame(minHeight: 44)
            }
        }
    }
    private func expandQueue() async {
        guard !queueExpansionComplete else { return }
        let expandsEpisodes = isEpisode && queue.source.count == 1 && loadFullQueue == nil
        guard loadFullQueue != nil || expandsEpisodes else { return }
        queueLoading = true; queueLoadError = false
        defer { queueLoading = false }
        // Directory enumeration must not compete with the media request for the first frame.
        while playback.diagnostic.firstFrameSeconds == nil {
            guard !Task.isCancelled else { return }
            guard playback.error == nil else { queueLoadError = true; return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        do {
            let complete: [Video]
            if let loadFullQueue { complete = try await loadFullQueue() }
            else {
                guard let server = library.servers.first(where: { $0.id == current.sourceID }),
                      server.kind == .jellyfin, let id = current.remoteID else {
                    throw MediaError.message("无法读取此剧集的选集列表。")
                }
                var seriesID = current.seriesID
                if seriesID == nil { seriesID = try await MediaClient.shared.catalogDetail(server: server, id: id).SeriesId }
                guard let seriesID else { throw MediaError.message("服务器没有提供此剧集所属节目的信息。") }
                let episodes = try await MediaClient.shared.catalogItems(server: server, parentID: seriesID, type: "Episode")
                complete = episodes.map { $0.video(server: server) }
            }
            try Task.checkCancellation()
            if isEpisode { library.rememberEpisodes(complete) }
            let regular = isEpisode ? complete.filter { current.seasonNumber == 0 ? $0.seasonNumber == 0 : $0.seasonNumber != 0 } : complete
            queue.replaceVideos(regular)
            library.remember(complete)
            queueExpansionComplete = true
            if pendingAutomaticAdvance {
                pendingAutomaticAdvance = false
                advance(1, automatic: true)
            }
        } catch is CancellationError { }
        catch { queueLoadError = true }
    }
    private func transportControls(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 12) {
            RoundControl(symbol: "backward.end.fill", label: isEpisode ? "上一集" : "上一个视频") { move(-1) }
                .disabled(!queue.canGoBack).opacity(queue.canGoBack ? 1 : 0.3)
            RoundControl(symbol: "gobackward.10", label: "快退 \(Int(PlaybackPreferences.seekInterval)) 秒") { playback.seek(playback.time - PlaybackPreferences.seekInterval); scheduleHideAfterInteraction() }
            RoundControl(symbol: playback.isPlaybackRequested ? "pause.fill" : "play.fill", label: playback.isPlaybackRequested ? "暂停" : "播放", prominent: true, compact: compact) { playback.toggle(); scheduleHideAfterInteraction() }
            RoundControl(symbol: "goforward.10", label: "快进 \(Int(PlaybackPreferences.seekInterval)) 秒") { playback.seek(playback.time + PlaybackPreferences.seekInterval); scheduleHideAfterInteraction() }
            RoundControl(symbol: "forward.end.fill", label: isEpisode ? "下一集" : "下一个视频") { move(1) }
                .disabled(!queue.canGoForward).opacity(queue.canGoForward ? 1 : 0.3)
        }
    }
    private func playbackActions(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 8) {
            if isEpisode {
                Button { quickMenuHolding = false; hideTask?.cancel(); episodesOpen = true } label: {
                    PlayerQuickActionLabel(title: "选集", symbol: "list.bullet.rectangle")
                }.accessibilityIdentifier("player.episodes")
            } else if !isCinema {
                Button { changeMode(queue.mode == .sequential ? .random : .sequential) } label: {
                    PlayerQuickActionLabel(title: queue.mode == .random ? "随机" : "顺序", symbol: queue.mode.symbol)
                }.accessibilityLabel(queue.mode.title).accessibilityIdentifier("player.mode")
            }
            Menu { speedMenuItems } label: {
                PlayerQuickActionLabel(title: "\(playback.rate.formatted())×", symbol: "speedometer")
            }.accessibilityLabel("播放速度").accessibilityIdentifier("player.quick.speed")
                .simultaneousGesture(TapGesture().onEnded { holdControlsForQuickMenu() })
            Menu { audioMenuItems } label: {
                PlayerQuickActionLabel(title: "音轨", symbol: "waveform")
            }.accessibilityLabel("音轨").accessibilityValue(playback.audioOptions.isEmpty ? "无可切换音轨" : playback.selectedAudio?.displayName ?? "默认")
                .accessibilityIdentifier("player.quick.audio")
                .simultaneousGesture(TapGesture().onEnded { if !playback.audioOptions.isEmpty { holdControlsForQuickMenu() } })
                .disabled(playback.audioOptions.isEmpty).opacity(playback.audioOptions.isEmpty ? 0.45 : 1)
            Menu { subtitleMenuItems } label: {
                PlayerQuickActionLabel(title: "字幕", symbol: "captions.bubble", active: !externalSubtitles.isEmpty || playback.selectedSubtitle != nil)
            }.accessibilityLabel("字幕").accessibilityValue(subtitleSelectionTitle)
                .accessibilityIdentifier("player.quick.subtitle")
                .simultaneousGesture(TapGesture().onEnded { holdControlsForQuickMenu() })
            Button {
                manuallyRotated = true
                ScreenRotation.request(compact ? .portrait : .landscapeRight, onError: showHUD)
                scheduleHideAfterInteraction()
            } label: {
                PlayerQuickActionLabel(title: compact ? "竖屏" : "横屏", symbol: "rotate.right")
            }.accessibilityLabel(compact ? "切换竖屏" : "切换横屏").accessibilityIdentifier("player.rotate")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.82))
    }
    private func changeMode(_ mode: PlaybackMode) {
        queue.setMode(mode); preferredMode = mode
        showHUD(mode.title); scheduleHideAfterInteraction()
    }
    private func move(_ delta: Int) { quickMenuHolding = false; advance(delta, automatic: false) }
    private var episodePosition: String {
        [current.seasonNumber.map { $0 == 0 ? "特别篇" : "第 \($0) 季" }, current.episodeNumber.map { "第 \($0) 集" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
    private func selectEpisode(_ id: String) {
        guard !locked, id != current.id, queue.select(id) else { return }
        pendingAutomaticAdvance = false
        playCurrent(automatic: false)
    }
    private func advance(_ delta: Int, automatic: Bool) {
        guard automatic || !locked else { return }
        if !automatic { pendingAutomaticAdvance = false }
        guard queue.move(delta) else {
            if delta > 0 && !queueExpansionComplete && (loadFullQueue != nil || isEpisode && queue.source.count == 1) {
                if automatic { pendingAutomaticAdvance = true }
                showHUD(isEpisode ? "正在加载下一集…" : "正在加载下一部…")
                return
            }
            if automatic { controls = true }
            showHUD(delta > 0 ? (isEpisode ? "已经是最后一集" : isCinema ? "已播放完毕" : "本目录已刷完") : (isEpisode ? "已经是第一集" : "已经是第一部"))
            return
        }
        playCurrent(automatic: automatic)
    }
    private func playCurrent(automatic: Bool) {
        // Stream indices and source IDs belong to one file, never reuse them for another episode.
        playback.tracks = TrackSelection()
        playback.open(current, library: library, recordsProgress: isCinema)
        if !automatic { UISelectionFeedbackGenerator().selectionChanged() }
        showHUD((isEpisode && !episodePosition.isEmpty ? episodePosition : "\(queue.index + 1) / \(queue.ordered.count)") + " · \(current.title)"); scheduleHide()
    }
    private func showHUD(_ text: String) {
        hudTask?.cancel(); hud = text
        hudTask = Task { try? await Task.sleep(for: .seconds(1.2)); if !Task.isCancelled { hud = nil } }
    }
    private func toggleControls() {
        if quickMenuHolding {
            // Dismissing an iPad menu can also deliver its outside tap to the canvas.
            // Keep the shortcuts available for the next choice.
            quickMenuHolding = false
            controls = true
            scheduleHide()
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { controls.toggle() }
        scheduleHide()
    }
    private func holdControlsForQuickMenu() {
        // Native Menu has no dismissal callback. Keep its owner visible until
        // a selection or the next explicit player interaction, even if the
        // network resumes playback while the menu is still on screen.
        quickMenuHolding = true
        hideTask?.cancel()
    }
    private func scheduleHideAfterInteraction() {
        quickMenuHolding = false
        scheduleHide()
    }
    private func scheduleHide() {
        hideTask?.cancel()
        guard !voiceOverEnabled, !quickMenuHolding, controls, scrubTarget == nil, !settingsOpen, !diagnosticOpen, !episodesOpen, !videoInfoOpen else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(PlaybackPreferences.controlsDelay))
            guard !Task.isCancelled, !voiceOverEnabled, !quickMenuHolding, scrubTarget == nil, !settingsOpen, !diagnosticOpen, !episodesOpen, !videoInfoOpen, playback.error == nil, playback.isPlaying else { return }
            withAnimation { controls = false }
        }
    }
}

private struct PlayerQuickActionLabel: View {
    var title: String
    var symbol: String
    var active = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.subheadline.weight(.medium))
            Text(title).font(.caption2.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(active ? GlideTheme.accent : .white.opacity(0.8))
        .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? 76 : 44, maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct PlayerSettingsLabel: View {
    var title: String
    var symbol: String
    var value: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.subheadline).foregroundStyle(GlideTheme.accent).frame(width: 24)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.primary)
                    Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(title).foregroundStyle(.primary).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 10)
                Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 170, alignment: .trailing)
            }
            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }.frame(minHeight: 44)
    }
}

/// Playback time and buffered ranges invalidate this subtree, not the player menus.
private struct PlayerTimeline: View {
    var playback: PlaybackController
    var identity: String
    @Binding var scrubTarget: Double?
    var onScrubStart: () -> Void
    var onScrubEnd: () -> Void
    private var deliveryTitle: String {
        guard let resource = playback.resource else { return "连接中" }
        if resource.url.isFileURL { return "离线播放" }
        return playback.loading ? "正在缓冲" : resource.delivery.title
    }
    var body: some View {
        VStack(spacing: 0) {
            BufferedSeekBar(value: scrubTarget ?? playback.time,
                            duration: playback.duration, ranges: playback.bufferedRanges,
                            onScrubStart: { onScrubStart(); scrubTarget = playback.time },
                            onScrubChange: { scrubTarget = $0 },
                            onScrubEnd: { target in scrubTarget = nil; playback.seek(target); onScrubEnd() })
            HStack(spacing: 12) {
                Text((scrubTarget ?? playback.time).mediaTime).accessibilityIdentifier("player.elapsed")
                Spacer(minLength: 8)
                Text(deliveryTitle).font(.caption2).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.65))
                    .accessibilityIdentifier("player.delivery")
                    .accessibilityValue(playback.resource?.delivery.title ?? "连接中")
                Spacer(minLength: 8)
                Text(playback.duration.mediaTime).accessibilityLabel("总时长，" + playback.duration.mediaTime)
            }
            .font(.system(.caption2, design: .monospaced)).monospacedDigit()
            .foregroundStyle(.white.opacity(0.68))
            .padding(.horizontal, 2)
        }
        .overlay(alignment: .top) {
            if let target = scrubTarget, playback.canPreview {
                TimelinePreview(identity: identity, time: target, provider: playback.previewFrame)
                    .frame(maxWidth: .infinity).offset(y: -132).allowsHitTesting(false)
            }
        }
    }
}

private struct PlayerSubtitleOverlay: View {
    var playback: PlaybackController
    var cues: [SubtitleCue]
    var delay: Double
    var bottomInset: CGFloat
    var body: some View {
        if !cues.isEmpty, let text = SubtitleCue.visible(cues, time: playback.time, delay: delay) {
            VStack {
                Spacer()
                Text(text).font(.system(size: 20 * PlaybackPreferences.subtitleScale / 100, weight: .medium))
                    .multilineTextAlignment(.center).foregroundStyle(.white)
                    .padding(6).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    .padding(.horizontal, 24).padding(.bottom, bottomInset)
            }.allowsHitTesting(false)
        }
    }
}

private struct PlayerPlaybackStatusSection: View {
    var playback: PlaybackController
    var body: some View {
        Section("当前播放") {
            LabeledContent("内核", value: playback.engineDescriptor.title)
            LabeledContent("传输", value: playback.resource?.delivery.title ?? "连接中")
            if let width = playback.diagnostic.outputWidth, let height = playback.diagnostic.outputHeight {
                LabeledContent("播放尺寸", value: "\(width) × \(height)")
            }
            if let codec = playback.diagnostic.outputVideoCodec { LabeledContent("输出编码", value: codec.uppercased()) }
            if let transfer = playback.diagnostic.outputColorTransfer { LabeledContent("输出色彩传递", value: transfer) }
            if playback.resource?.url.isFileURL == false {
                if let bitrate = playback.diagnostic.observedBitrate {
                    LabeledContent("测得下载速率", value: String(format: "%.1f Mb/s", Double(bitrate) / 1_000_000))
                }
                if let ahead = playback.diagnostic.bufferedAheadSeconds {
                    LabeledContent("已缓冲", value: String(format: "%.1f 秒", ahead))
                        .accessibilityIdentifier("player.info.bufferedAhead")
                }
            }
        }
    }
}

private struct PlayerStreamInfoRow: View {
    var stream: CatalogItem.Stream
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stream.label).font(.footnote.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let codec = stream.Codec { Text(codec.uppercased()) }
                if let language = stream.Language { Text(Locale.current.localizedString(forLanguageCode: language) ?? language) }
                if stream.IsDefault == true { Text("默认").foregroundStyle(GlideTheme.accent) }
                if stream.IsForced == true { Text("强制字幕") }
                if let bitrate = stream.BitRate, bitrate > 0 { Text("\(bitrate / 1_000) kb/s").monospacedDigit() }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }
}

private struct BufferedSeekBar: UIViewRepresentable {
    var value: Double
    var duration: Double
    var ranges: [BufferedRange]
    var onScrubStart: () -> Void
    var onScrubChange: (Double) -> Void
    var onScrubEnd: (Double) -> Void
    func makeUIView(context: Context) -> BufferedSeekControl { BufferedSeekControl() }
    func updateUIView(_ view: BufferedSeekControl, context: Context) {
        view.configure(value: value, duration: duration, ranges: ranges)
        view.onStart = onScrubStart
        view.onChange = onScrubChange
        view.onEnd = onScrubEnd
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BufferedSeekControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: 44)
    }
}

private final class BufferedSeekControl: UIControl {
    var onStart: (() -> Void)?
    var onChange: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?
    private var value: Double = 0
    private var duration: Double = 0
    private var ranges: [BufferedRange] = []
    private var scrubbing = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = "播放进度"
        accessibilityIdentifier = "player.seekBar"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(value: Double, duration: Double, ranges: [BufferedRange]) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.ranges = ranges
        isEnabled = self.duration > 0
        if !scrubbing { self.value = value.isFinite ? max(0, min(value, self.duration)) : 0 }
        updateAccessibility(); setNeedsDisplay()
    }
    private func updateAccessibility() {
        let buffered = ranges.isEmpty ? "暂无" : ranges.map { "\($0.start.mediaTime) 至 \($0.end.mediaTime)" }.joined(separator: "，")
        accessibilityValue = "\(value.mediaTime) / \(duration.mediaTime)；已缓冲 " + buffered
        accessibilityHint = "上下轻扫调整播放位置；已缓冲 " + buffered
    }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        scrubbing = true; onStart?()
        update(touch)
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        update(touch); return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { update(touch) }
        finishTracking()
    }
    override func cancelTracking(with event: UIEvent?) { finishTracking() }
    private func update(_ touch: UITouch) {
        value = min(1, max(0, (touch.location(in: self).x - 15) / max(1, bounds.width - 30))) * duration
        onChange?(value)
        updateAccessibility(); setNeedsDisplay()
    }
    private func finishTracking() {
        guard scrubbing else { return }
        scrubbing = false; onEnd?(value)
        updateAccessibility(); setNeedsDisplay()
    }
    override func accessibilityIncrement() { adjust(by: 5) }
    override func accessibilityDecrement() { adjust(by: -5) }
    private func adjust(by delta: Double) {
        guard isEnabled else { return }
        scrubbing = true; onStart?()
        value = max(0, min(duration, value + delta)); onChange?(value)
        finishTracking()
    }
    override func draw(_ rect: CGRect) {
        let width = max(1, bounds.width - 30), y = bounds.midY
        let track = CGRect(x: 15, y: y - 2, width: width, height: 4)
        UIColor.white.withAlphaComponent(0.18).setFill()
        UIBezierPath(roundedRect: track, cornerRadius: 2).fill()
        if duration > 0 {
            UIColor.white.withAlphaComponent(0.5).setFill()
            for range in ranges {
                let start = min(1, max(0, range.start / duration))
                let end = min(1, max(start, range.end / duration))
                let segment = CGRect(x: 15 + width * CGFloat(start), y: y - 2, width: width * CGFloat(end - start), height: 4)
                UIBezierPath(roundedRect: segment, cornerRadius: 2).fill()
            }
            UIColor(red: 0.773, green: 0.871, blue: 0.773, alpha: 1).setFill()
            let fraction = min(1, max(0, value / duration))
            UIBezierPath(roundedRect: CGRect(x: 15, y: y - 2, width: width * CGFloat(fraction), height: 4), cornerRadius: 2).fill()
        }
        let fraction = duration > 0 ? min(1, max(0, value / duration)) : 0
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: 15 + width * CGFloat(fraction) - 10, y: y - 10, width: 20, height: 20)).fill()
    }
}
