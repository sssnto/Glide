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
    @State private var playback = PlaybackController()
    @State private var controls = true
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
    private var current: Video { queue.current! } // Presented only after collecting a nonempty queue.
    private var nextVideo: Video? { queue.canGoForward ? queue.ordered[queue.index + 1] : nil }
    private var warmupKey: String {
        current.id + ":" + (nextVideo?.id ?? "") + ":\(playback.frameReady):\(playback.loading):\(playback.isPlaying):\(playback.rate):\(scenePhase == .active)"
    }
    private var selectedMediaSource: CatalogItem.Source? {
        videoDetail?.MediaSources?.first(where: { $0.Id == playback.resource?.mediaSourceID }) ?? videoDetail?.MediaSources?.first
    }
    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                VideoSurface(player: playback.player, onLayer: { playback.attachLayer($0) }, identity: current.id, title: current.title,
                    frameReady: playback.frameReady, locked: locked, filled: filled,
                    onSwipe: { if !isCinema || isEpisode { move($0) } },
                    onToggle: { playback.toggle(); scheduleHide() }, onSeek: {
                        // SpatialTapGesture can also complete when a long press is released.
                        suppressTapUntil = Date().addingTimeInterval(0.5)
                        playback.seek(playback.time + $0); scheduleHide()
                    },
                    onSpeedPreset: { playback.setRate($0); scheduleHide() }, onHUD: showHUD)
                    .ignoresSafeArea()
                if !playback.frameReady && playback.error == nil {
                    if let server = library.servers.first(where: { $0.id == current.sourceID }), server.kind == .jellyfin, let id = current.remoteID {
                        CatalogArtwork(item: CatalogItem(Id: id, Name: current.title, Type: current.mediaType), server: server, contentMode: .fit).opacity(0.45).allowsHitTesting(false)
                    } else { VideoArtwork(video: current, contentMode: .fit).opacity(0.45).allowsHitTesting(false) }
                }
                if let text = SubtitleCue.visible(externalSubtitles, time: playback.time, delay: subtitleDelay) {
                    VStack { Spacer(); Text(text).font(.system(size: 20 * PlaybackPreferences.subtitleScale / 100, weight: .medium)).multilineTextAlignment(.center)
                        .foregroundStyle(.white).padding(6).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                        .padding(.horizontal, 24).padding(.bottom, geometry.size.height * subtitleBottom / 100) }.allowsHitTesting(false)
                }
                if controls {
                    LinearGradient(stops: [.init(color: .black.opacity(0.65), location: 0), .init(color: .clear, location: 0.3), .init(color: .clear, location: 0.55), .init(color: .black.opacity(0.85), location: 1)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
                    VStack {
                        if locked { HStack { Spacer(); RoundControl(symbol: "lock.fill", label: "解锁触控") { locked = false; scheduleHide() } } }
                        else { topBar }
                        Spacer()
                        if !locked { bottomControls(compact: landscape) }
                    }.padding(.horizontal, landscape ? 32 : 24).padding(.top, 4).padding(.bottom, 6)
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
                        Text(error).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
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
                if controls && (touch.location.y < 110 || touch.location.y > geometry.size.height - (landscape ? 130 : 180)) { return }
                toggleControls()
            })
        }
        .statusBarHidden(!controls)
        .persistentSystemOverlays(controls ? .visible : .hidden)
        .onAppear {
            initialOrientation = ScreenRotation.activeScene?.interfaceOrientation
            UIApplication.shared.isIdleTimerDisabled = true
            playback.tracks = initialTracks
            playback.open(current, library: library, resumeAt: initialResumeAt, recordsProgress: isCinema); scheduleHide()
        }
        .onDisappear {
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
            guard videoInfoOpen, let server = library.servers.first(where: { $0.id == current.sourceID }),
                  server.kind == .jellyfin, let id = current.remoteID else { videoDetail = nil; return }
            videoDetail = nil
            videoDetail = try? await MediaClient.shared.catalogDetail(server: server, id: id)
        }
        .onChange(of: settingsOpen) { _, open in if open { hideTask?.cancel() } else { scheduleHide() } }
        .onChange(of: episodesOpen) { _, open in if open { hideTask?.cancel() } else { scheduleHide() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background && !playback.pictureInPicture.active && !playback.player.isExternalPlaybackActive { playback.pause(); controls = true } }
        .onChange(of: playback.isPlaying) { _, playing in if playing { scheduleHide() } else if !playback.loading { controls = true } }
        .onChange(of: playback.completedCount) { _, _ in if scenePhase == .active { advance(1, automatic: true) } }
        .onChange(of: playback.playbackNotice) { _, notice in
            if notice != nil { controls = true; scheduleHide() }
        }
        .onChange(of: playback.error) { _, error in if error != nil { controls = true; hideTask?.cancel() } }
    }
    private var topBar: some View {
        HStack(spacing: 10) {
            RoundControl(symbol: "chevron.down", label: "返回片库") { dismiss() }
            VStack(alignment: .leading, spacing: 5) {
                Text(current.title).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.white)
                Text((isEpisode && !episodePosition.isEmpty ? episodePosition + " · " : "") + "\(queue.index + 1) / \(queue.ordered.count)" + (queueLoading ? (isEpisode ? " · 正在加载剧集" : " · 正在补全目录") : ""))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            RoundControl(symbol: "lock.open", label: "锁定触控") { locked = true; showHUD("已锁定触控"); scheduleHide() }
            Button {
                hideTask?.cancel()
                settingsOpen = true
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20))
                    .frame(width: 46, height: 46).background(.white.opacity(0.09), in: Circle())
            }
            .accessibilityLabel("播放设置")
        }
    }
    private var settingsPanel: some View {
        NavigationStack {
            Form {
                Section("播放设备与诊断") {
                    Button("画中画", systemImage: "pip") { playback.pictureInPicture.toggle(); if playback.pictureInPicture.possible { settingsOpen = false } }.accessibilityIdentifier("player.pip")
                    if let message = playback.pictureInPicture.message { Text(message).font(.caption) }
                    AirPlayControl().frame(height: 44)
                    Button("视频信息", systemImage: "info.circle") { pendingSettingsAction = .videoInfo; settingsOpen = false }
                    Button("播放诊断", systemImage: "waveform.path.ecg") { pendingSettingsAction = .diagnostic; settingsOpen = false }.accessibilityIdentifier("player.diagnostic")
                    if playback.syncError != nil { Button("重试同步进度") { playback.save(); playback.report("Progress") } }
                }
                Button(library.favorites.contains(current.id) ? "取消收藏" : "收藏视频", systemImage: "heart") { library.toggleFavorite(current); settingsOpen = false }
                if !isCinema { Section("播放顺序") {
                    ForEach(PlaybackMode.allCases) { mode in
                        Button { changeMode(mode) } label: {
                            Label(mode.title + (queue.mode == mode ? " ✓" : ""), systemImage: mode.symbol)
                        }
                    }
                }
                }
                Section("播放速度") { ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in Button("\(rate.formatted())×" + (playback.rate == Float(rate) ? " ✓" : "")) { playback.setRate(Float(rate)); scheduleHide() } } }
                Section("画面") { Button(filled ? "完整显示画面" : "填满屏幕") { filled.toggle() } }
                Section("外部字幕") {
                    Button("导入 SRT / VTT 字幕") { pendingSettingsAction = .subtitleImport; settingsOpen = false }
                    if !externalSubtitles.isEmpty {
                        Stepper("字幕延迟：\(subtitleDelay, specifier: "%.1f") 秒", value: $subtitleDelay, in: -30...30, step: 0.5)
                        Stepper("字幕底部距离：\(Int(subtitleBottom))%", value: $subtitleBottom, in: 5...35, step: 2)
                        Button("移除外部字幕") { externalSubtitles = [] }
                        Text("外部字幕显示在本机画面中，画中画与 AirPlay 不包含此字幕。").font(.caption)
                    }
                    if let subtitleMessage { Text(subtitleMessage).font(.caption) }
                }
                Section("字幕") {
                    Button("关闭字幕" + (playback.selectedSubtitle == nil ? " ✓" : "")) { externalSubtitles = []; playback.selectSubtitle(nil) }
                    ForEach(playback.subtitleOptions, id: \.self) { option in Button(option.displayName + (playback.selectedSubtitle == option ? " ✓" : "")) { externalSubtitles = []; playback.selectSubtitle(option) } }
                    if playback.subtitleOptions.isEmpty { Text("当前流没有可选字幕") }
                }
                Section("音轨") {
                    ForEach(playback.audioOptions, id: \.self) { option in Button(option.displayName + (playback.selectedAudio == option ? " ✓" : "")) { playback.selectAudio(option) } }
                    if playback.audioOptions.isEmpty { Text("当前流没有可选音轨") }
                }
            }
            .buttonStyle(.plain)
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
    private var videoInfoPanel: some View {
        NavigationStack {
            Form {
                Section("媒体") {
                    LabeledContent("名称", value: current.title)
                    LabeledContent("时长", value: playback.duration.mediaTime)
                    if let type = current.mediaType { LabeledContent("类型", value: type) }
                    if let source = library.servers.first(where: { $0.id == current.sourceID }) {
                        LabeledContent("来源", value: source.name)
                    }
                }
                Section("当前播放") {
                    LabeledContent("内核", value: "AVPlayer · 系统播放器")
                    LabeledContent("传输", value: playback.resource?.delivery.title ?? "连接中")
                    if let codec = playback.diagnostic.videoCodec { LabeledContent("视频编码", value: codec.uppercased()) }
                    if let width = playback.diagnostic.width, let height = playback.diagnostic.height {
                        LabeledContent("原始尺寸", value: "\(width) × \(height)")
                    }
                    if let bits = playback.diagnostic.bitDepth { LabeledContent("位深", value: "\(bits) bit") }
                    if let width = playback.diagnostic.outputWidth, let height = playback.diagnostic.outputHeight {
                        LabeledContent("播放尺寸", value: "\(width) × \(height)")
                    }
                    if let bitrate = playback.diagnostic.observedBitrate {
                        LabeledContent("当前码率", value: String(format: "%.1f Mb/s", Double(bitrate) / 1_000_000))
                    }
                }
                if let source = selectedMediaSource {
                    Section("文件") {
                        if let container = source.Container { LabeledContent("封装", value: container.uppercased()) }
                        if let size = source.Size { LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    }
                    let streams = source.MediaStreams ?? []
                    if !streams.filter({ $0.Type == "Audio" }).isEmpty {
                        Section("声音") { ForEach(streams.filter { $0.Type == "Audio" }) { stream in Text(stream.label) } }
                    }
                    if !streams.filter({ $0.Type == "Subtitle" }).isEmpty {
                        Section("字幕") { ForEach(streams.filter { $0.Type == "Subtitle" }) { stream in Text(stream.label) } }
                    }
                }
            }
            .navigationTitle("视频信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { videoInfoOpen = false } } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
    private func bottomControls(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(spacing: 4) {
                BufferedSeekBar(value: playback.time,
                                duration: playback.duration, ranges: playback.bufferedRanges,
                                onScrubStart: { hideTask?.cancel() },
                                onScrubEnd: { target in playback.seek(target); scheduleHide() })
                HStack {
                    Text(playback.time.mediaTime).accessibilityIdentifier("player.elapsed")
                    Spacer()
                    Text(playback.resource == nil ? "连接中" : playback.resource?.url.isFileURL == true ? "离线播放" : playback.loading ? "正在缓冲" : "自动适配")
                        .font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                        .accessibilityIdentifier("player.delivery")
                        .accessibilityValue(playback.resource?.delivery.title ?? "连接中")
                    Spacer()
                    Text(playback.duration.mediaTime)
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    transportControls
                    Spacer(minLength: 8)
                    playbackActions(compact: compact)
                }
                VStack(spacing: 0) {
                    transportControls.frame(maxWidth: .infinity)
                    playbackActions(compact: compact)
                }
            }
            if let notice = playback.playbackNotice { Text(notice).font(.caption2).foregroundStyle(GlideTheme.accent) }
            if let warning = playback.syncError { Text(warning).font(.caption2).foregroundStyle(.orange) }
            if queueLoadError {
                Button(isEpisode ? "剧集列表加载失败，重试" : "剩余视频加载失败，重试") { queueReload += 1 }
                    .font(.caption2).foregroundStyle(.orange)
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
    private var transportControls: some View {
            HStack(spacing: 6) {
                RoundControl(symbol: "backward.end.fill", label: isEpisode ? "上一集" : "上一个视频") { move(-1) }.disabled(!queue.canGoBack).opacity(queue.canGoBack ? 1 : 0.35)
                RoundControl(symbol: "gobackward.10", label: "快退 \(Int(PlaybackPreferences.seekInterval)) 秒") { playback.seek(playback.time - PlaybackPreferences.seekInterval); scheduleHide() }
                RoundControl(symbol: playback.isPlaying ? "pause.fill" : "play.fill", label: playback.isPlaying ? "暂停" : "播放", prominent: true, compact: true) { playback.toggle(); scheduleHide() }
                RoundControl(symbol: "goforward.10", label: "快进 \(Int(PlaybackPreferences.seekInterval)) 秒") { playback.seek(playback.time + PlaybackPreferences.seekInterval); scheduleHide() }
                RoundControl(symbol: "forward.end.fill", label: isEpisode ? "下一集" : "下一个视频") { move(1) }.disabled(!queue.canGoForward).opacity(queue.canGoForward ? 1 : 0.35)
            }
    }
    private func playbackActions(compact: Bool) -> some View {
            HStack {
                if isEpisode {
                    Button { hideTask?.cancel(); episodesOpen = true } label: {
                        Label("选集", systemImage: "list.bullet.rectangle").font(.caption)
                    }.frame(minHeight: 44).accessibilityIdentifier("player.episodes")
                }
                if !isCinema { Button { changeMode(queue.mode == .sequential ? .random : .sequential) } label: {
                    Label(queue.mode.title, systemImage: queue.mode.symbol).font(.caption)
                }.frame(minHeight: 44).accessibilityIdentifier("player.mode") }
                Spacer(minLength: 8)
                Button {
                    manuallyRotated = true
                    ScreenRotation.request(compact ? .portrait : .landscapeRight, onError: showHUD)
                    scheduleHide()
                } label: { Label(compact ? "竖屏" : "横屏", systemImage: "rotate.right").font(.caption) }
                    .frame(minHeight: 44).accessibilityLabel(compact ? "切换竖屏" : "切换横屏").accessibilityIdentifier("player.rotate")
            }
    }
    private func changeMode(_ mode: PlaybackMode) {
        queue.setMode(mode); preferredMode = mode
        showHUD(mode.title); scheduleHide()
    }
    private func move(_ delta: Int) { advance(delta, automatic: false) }
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
        withAnimation(.easeInOut(duration: 0.2)) { controls.toggle() }
        scheduleHide()
    }
    private func scheduleHide() {
        hideTask?.cancel()
        guard controls, !settingsOpen, !diagnosticOpen, !episodesOpen, !videoInfoOpen else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(PlaybackPreferences.controlsDelay))
            guard !Task.isCancelled, !settingsOpen, !diagnosticOpen, !episodesOpen, !videoInfoOpen, playback.error == nil, playback.isPlaying else { return }
            withAnimation { controls = false }
        }
    }
}

private struct BufferedSeekBar: UIViewRepresentable {
    var value: Double
    var duration: Double
    var ranges: [BufferedRange]
    var onScrubStart: () -> Void
    var onScrubEnd: (Double) -> Void
    func makeUIView(context: Context) -> BufferedSeekControl { BufferedSeekControl() }
    func updateUIView(_ view: BufferedSeekControl, context: Context) {
        view.configure(value: value, duration: duration, ranges: ranges)
        view.onStart = onScrubStart
        view.onEnd = onScrubEnd
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: BufferedSeekControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: 44)
    }
}

private final class BufferedSeekControl: UIView {
    var onStart: (() -> Void)?
    var onChange: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?
    private let slider = UISlider()
    private var duration: Double = 0
    private var ranges: [BufferedRange] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        slider.minimumTrackTintColor = .clear
        slider.maximumTrackTintColor = .clear
        slider.thumbTintColor = .white
        slider.accessibilityLabel = "播放进度"
        slider.accessibilityIdentifier = "player.seekBar"
        addSubview(slider)
        slider.addTarget(self, action: #selector(startTracking), for: .touchDown)
        slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(endTracking), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        slider.frame = bounds
    }
    func configure(value: Double, duration: Double, ranges: [BufferedRange]) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.ranges = ranges
        slider.maximumValue = Float(max(1, self.duration))
        slider.isEnabled = self.duration > 0
        if !slider.isTracking { slider.value = Float(value.isFinite ? max(0, min(value, self.duration)) : 0) }
        updateAccessibility()
        setNeedsDisplay()
    }
    private func updateAccessibility() {
        let buffered = ranges.isEmpty ? "暂无" : ranges.map { "\($0.start.mediaTime) 至 \($0.end.mediaTime)" }.joined(separator: "，")
        slider.accessibilityValue = "\(Double(slider.value).mediaTime) / \(duration.mediaTime)；已缓冲 " + buffered
        slider.accessibilityHint = "已缓冲 " + buffered
    }
    @objc private func startTracking() { onStart?() }
    @objc private func valueChanged() {
        onChange?(Double(slider.value))
        updateAccessibility(); setNeedsDisplay()
    }
    @objc private func endTracking() {
        let target = Double(slider.value)
        onEnd?(target)
        updateAccessibility(); setNeedsDisplay()
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
            let fraction = min(1, max(0, Double(slider.value) / duration))
            UIBezierPath(roundedRect: CGRect(x: 15, y: y - 2, width: width * CGFloat(fraction), height: 4), cornerRadius: 2).fill()
        }
    }
}
