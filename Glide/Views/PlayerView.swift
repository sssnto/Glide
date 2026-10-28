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
    var initialMoment: MediaMoment? = nil
    var momentStore = MomentStore.shared
    var channelMode = false
    var onFirstFrame: ((Video) -> Void)? = nil
    var onQueueFinished: (() -> Void)? = nil
    var returnLabel = "返回片库"
    var clip: MediaClip? = nil
    var clipPosition = ""
    var clipCanGoBack = false
    var clipCanGoForward = false
    var onClipMove: ((Int) -> Void)? = nil
    var onClipCompleted: (() -> Void)? = nil
    var onClipProgress: ((Double) -> Void)? = nil
    var onFullVideo: ((Double) -> Void)? = nil
    var onExit: (() -> Void)? = nil
    @State private var notifiedStarts = Set<String>()
    private var isCinema: Bool { cinematic || ["Movie", "Episode"].contains(current.mediaType ?? "") }
    private var recordsProgress: Bool {
        if clip != nil { return false }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--glide-unified-fixture") || ProcessInfo.processInfo.arguments.contains("--glide-clip-fixture") { return false }
        if ProcessInfo.processInfo.arguments.contains("--glide-ui-audit") || ProcessInfo.processInfo.arguments.contains("--glide-discovery-probe") || ProcessInfo.processInfo.arguments.contains("--glide-map-probe") || ProcessInfo.processInfo.arguments.contains("--glide-map-fixture") { return false }
#endif
        return isCinema || library.servers.first(where: { $0.id == current.sourceID })?.remembersPlayback == true
    }
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
    private enum SettingsAction { case diagnostic, videoInfo, subtitleImport, subtitleControls, navigation, moment, clip }
    @State private var pendingSettingsAction: SettingsAction?
    @State private var navigationSelection: VideoNavigationPresentation?
    @State private var navigationWasPlaying = false
    @State private var navigationTarget: Double?
    @State private var clipDraft: MediaClip?
    @State private var clipWasPlaying = false
    @State private var clipPreparing = false
    @State private var clipError: String?
    @State private var diagnosticOpen = false
    @State private var videoInfoOpen = false
    @State private var skipSettingsOpen = false
    @State private var pathCopied = false
    @State private var episodesOpen = false
    @State private var videoDetail: CatalogItem?
    @State private var importingSubtitle = false
    private var subtitles: SubtitleSession { playback.subtitles }
    @State private var bottomControlsHeight: CGFloat = 0
    @State private var subtitleControlsOpen = false
    @State private var subtitlePresentationTask: Task<Void, Never>?
    @State private var subtitleImportLane = SubtitleLane.primary
    @State private var subtitleImportReturnsToControls = false
    @State private var pendingSubtitleLane: SubtitleLane?
    @State private var subtitleImportVideoID: String?
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
                    onSwipe: { if clip != nil || channelMode || !isCinema || isEpisode { move($0) } },
                    onToggle: { playback.toggle(); scheduleHideAfterInteraction() }, onSeek: {
                        // SpatialTapGesture can also complete when a long press is released.
                        suppressTapUntil = Date().addingTimeInterval(0.5)
                        playback.seek(playback.time + $0); scheduleHideAfterInteraction()
                    },
                    onSpeedPreset: { playback.setRate($0); scheduleHideAfterInteraction() }, onHUD: showHUD, subtitleSession: subtitles, secondarySubtitleSession: playback.secondarySubtitles,
                    subtitleClock: { playback.subtitleRenderTime }, subtitleVideoMatrix: playback.subtitleVideoMatrix, subtitleSourceSize: playback.subtitleVideoSize)
                    .ignoresSafeArea()
                if !playback.frameReady && playback.error == nil {
                    if current.offlineOnly != true, let server = library.servers.first(where: { $0.id == current.sourceID }), server.kind.isCatalogSource, let id = current.remoteID {
                        CatalogArtwork(item: CatalogItem(Id: id, Name: current.title, Type: current.mediaType), server: server, contentMode: .fit).opacity(0.45).allowsHitTesting(false)
                    } else { VideoArtwork(video: current, contentMode: .fit).opacity(0.45).allowsHitTesting(false) }
                }
                if controls {
                    LinearGradient(stops: [.init(color: .black.opacity(0.65), location: 0), .init(color: .clear, location: 0.3), .init(color: .clear, location: 0.55), .init(color: .black.opacity(0.85), location: 1)], startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
                }
                PlayerPGSOverlay(session: subtitles, filled: filled).ignoresSafeArea()
                PlayerSubtitleOverlay(playback: playback, cues: subtitles.overlayCues, delay: subtitles.delay,
                                      bottomInset: max(geometry.size.height * subtitleBottom / 100, controls && !locked ? bottomControlsHeight + 24 : 0), secondaryCues: playback.secondarySubtitles.overlayCues, secondaryDelay: playback.secondarySubtitles.delay)
                if controls {
                    VStack {
                        if locked { HStack { Spacer(); RoundControl(symbol: "lock.fill", label: "解锁触控") { locked = false; scheduleHideAfterInteraction() } } }
                        else { topBar }
                        Spacer()
                        if !locked { bottomControls(compact: landscape) }
                    }.padding(.horizontal, landscape ? 28 : 20).padding(.top, 4).padding(.bottom, 8)
                    .transition(.opacity)
                }
                PlayerSkipControls(playback: playback, locked: locked, controls: controls, landscape: landscape) {
                    suppressTapUntil = Date().addingTimeInterval(0.5)
                    scheduleHideAfterInteraction()
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
                        if playback.showsOriginalTransport {
                            Button(playback.originalTransportTitle) { playback.tryOriginalTransport() }
                                .buttonStyle(.bordered).disabled(!playback.canTryOriginalTransport)
                                .accessibilityIdentifier("player.transport.afterFailure")
                        }
                        if playback.canSwitchEngine {
                            Button(playback.engineDescriptor.id == .avPlayer ? "尝试兼容播放" : "返回系统播放") {
                                suppressTapUntil = Date().addingTimeInterval(0.5)
                                controls = true
                                playback.switchEngine(to: playback.engineDescriptor.id == .avPlayer ? .vlc : .avPlayer)
                            }.buttonStyle(.bordered).accessibilityIdentifier("player.switchAfterFailure")
                        }
                        HStack {
                            Button("返回片库") { exitPlayer() }
                            Spacer()
                            Button("播放诊断") { diagnosticOpen = true }
                            Button("重试") { playback.retry() }.buttonStyle(.borderedProminent).tint(GlideTheme.accent).foregroundStyle(GlideTheme.onAccent)
                        }
                    }.padding(26).frame(maxWidth: 370).background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 24)).padding(24)
                }
            }
            .accessibilityHidden(clipDraft != nil || clipPreparing)
            .onPreferenceChange(PlayerControlsHeightKey.self) { value in
                if abs(bottomControlsHeight - value) > 0.5 { bottomControlsHeight = value }
            }
            .simultaneousGesture(SpatialTapGesture().onEnded { touch in
                // Keep the tap above the video renderer, including after the
                // controls fade away. Buttons retain their own touch targets.
                guard Date() >= suppressTapUntil else { return }
                if !locked, playback.activeSkip != nil {
                    let inset = PlayerSkipControls.bottomInset(controls: controls, landscape: landscape)
                    // Ignore the skip controls' band regardless of gesture callback order.
                    if touch.location.y >= geometry.size.height - inset - 64,
                       touch.location.y <= geometry.size.height - inset + 16 { return }
                }
                if controls && (touch.location.y < 110 || touch.location.y > geometry.size.height - (landscape ? 150 : 230)) { return }
                toggleControls()
            })
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!controls)
        .persistentSystemOverlays(controls ? .visible : .hidden)
        .onAppear {
            initialOrientation = ScreenRotation.activeScene?.interfaceOrientation
            UIApplication.shared.isIdleTimerDisabled = true
            playback.clip = clip
            playback.tracks = initialTracks
            playback.pendingMomentReference = initialMoment?.reference
            var autoplay = true
#if DEBUG
            if clip != nil, ProcessInfo.processInfo.arguments.contains("--glide-clip-start-paused") { autoplay = false }
            if ProcessInfo.processInfo.arguments.contains("--glide-dual-subtitle-fixture") || ProcessInfo.processInfo.arguments.contains("--glide-format-fixtures") || ProcessInfo.processInfo.arguments.contains("--glide-subtitle-fixture") || ProcessInfo.processInfo.arguments.contains("--glide-subtitle-smb-fixture") || ProcessInfo.processInfo.arguments.contains("--glide-smb-fixture") {
                autoplay = !UserDefaults.standard.bool(forKey: "glideQAStartPaused")
            }
#endif
            playback.open(current, library: library, resumeAt: initialResumeAt, autoplay: autoplay, recordsProgress: recordsProgress); scheduleHide()
        }
        .onDisappear {
            scrubTarget = nil
            if clip != nil { onClipProgress?(playback.time) }
            playback.pictureInPicture.stop(); playback.close(); hudTask?.cancel(); hideTask?.cancel(); subtitlePresentationTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
            if manuallyRotated, let initialOrientation { ScreenRotation.request(ScreenRotation.mask(for: initialOrientation)) { _ in } }
        }
        .task(id: queueReload) { await expandQueue() }
        .task(id: warmupKey) {
            guard clip == nil, playback.frameReady, !playback.loading, playback.isPlaying,
                  playback.rate == 1, scenePhase == .active, let nextVideo else { playback.cancelWarmup(); return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await playback.prepareNext(nextVideo, library: library)
        }
        .fileImporter(isPresented: $importingSubtitle, allowedContentTypes: [.plainText, UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText, UTType(filenameExtension: "ass") ?? .plainText, UTType(filenameExtension: "ssa") ?? .plainText], allowsMultipleSelection: false, onCompletion: { result in
            if case .success(let urls) = result, let url = urls.first {
                if subtitleImportVideoID == current.id { (subtitleImportLane == .primary ? subtitles : playback.secondarySubtitles).importFile(url) }
                else { subtitles.message = "视频已切换，请为当前视频重新选择字幕。" }
            }
            finishSubtitleImport()
        }, onCancellation: { finishSubtitleImport() })
        .onChange(of: current.id) { _, _ in scrubTarget = nil; subtitlePresentationTask?.cancel() }
        .sheet(item: $navigationSelection, onDismiss: finishNavigation) { selection in
            VideoNavigationView(library: library, selection: selection, store: momentStore) { navigationTarget = $0 }
        }
        .sheet(isPresented: $diagnosticOpen, onDismiss: { scheduleHide() }) {
            NavigationStack { DiagnosticView(diagnostic: playback.diagnostic).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { diagnosticOpen = false } } } }
        }
        .sheet(isPresented: $videoInfoOpen, onDismiss: { scheduleHide() }) { videoInfoPanel }
        .sheet(isPresented: $settingsOpen, onDismiss: {
            skipSettingsOpen = false
            let action = pendingSettingsAction; pendingSettingsAction = nil
            switch action {
            case .navigation: presentNavigation()
            case .moment: presentNavigation(createMoment: true)
            case .clip: presentClip()
            case .diagnostic: diagnosticOpen = true
            case .videoInfo: videoInfoOpen = true
            case .subtitleImport: beginSubtitleImport()
            case .subtitleControls: subtitleControlsOpen = true
            case nil: scheduleHide()
            }
        }) { settingsPanel }
        .sheet(isPresented: $subtitleControlsOpen, onDismiss: {
            if let lane = pendingSubtitleLane { pendingSubtitleLane = nil; beginSubtitleImport(lane, returnToControls: true) }
            else { scheduleHide() }
        }) {
            SubtitleControlsView(playback: playback) { lane in pendingSubtitleLane = lane }
        }
        .sheet(isPresented: $episodesOpen, onDismiss: { scheduleHide() }) {
            EpisodePickerView(videos: queue.source.filter { $0.mediaType == "Episode" }, currentID: current.id,
                              loading: queueLoading, failed: queueLoadError,
                              onRetry: { queueReload += 1 }, onSelect: selectEpisode)
        }
        .task(id: videoInfoOpen ? current.id : "") {
            pathCopied = false
            guard current.offlineOnly != true, videoInfoOpen, let server = library.servers.first(where: { $0.id == current.sourceID }),
                  server.kind.isCatalogSource, let id = current.remoteID else { videoDetail = nil; return }
            videoDetail = nil
            let detail = try? await MediaClient.shared.catalogDetail(server: server, id: id)
            guard !Task.isCancelled, current.remoteID == id else { return }
            videoDetail = detail
        }
        .onChange(of: settingsOpen) { _, open in if open { hideTask?.cancel() } else { scheduleHide() } }
        .onChange(of: episodesOpen) { _, open in if open { hideTask?.cancel() } else { scheduleHide() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background && !playback.pictureInPicture.active && !playback.externalPlaybackActive { playback.pause(); controls = true } }
        .onChange(of: playback.isPlaying) { _, playing in if playing { scheduleHide() } else if !playback.loading { controls = true } }
        .sheet(item: $clipDraft, onDismiss: {
            if clipWasPlaying { playback.play() }; clipWasPlaying = false; scheduleHide()
        }) { draft in ClipEditorView(library: library, clip: draft) }
        .alert("无法收藏片段", isPresented: Binding(get: { clipError != nil }, set: { if !$0 { clipError = nil } })) {
            Button("好") { clipError = nil }
        } message: { Text(clipError ?? "") }
        .onChange(of: Int(playback.time / 2)) { _, _ in if clip != nil { onClipProgress?(playback.time) } }
        .onChange(of: playback.clipCompletedCount) { _, _ in if clip != nil { onClipCompleted?() } }
        .onChange(of: playback.completedCount) { _, _ in if scenePhase == .active { advance(1, automatic: true) } }
        .onChange(of: playback.frameReady) { _, ready in
#if DEBUG
            if (ProcessInfo.processInfo.arguments.contains("--glide-discovery-probe") || ProcessInfo.processInfo.arguments.contains("--glide-map-probe") || ProcessInfo.processInfo.arguments.contains("--glide-map-fixture")), case .native(let player) = playback.presentation { player.isMuted = true }
#endif
            if ready, notifiedStarts.insert(current.id).inserted { onFirstFrame?(current) }
        }
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
            RoundControl(symbol: "chevron.down", label: returnLabel) { exitPlayer() }
            VStack(alignment: .leading, spacing: 3) {
                Text(current.title).font(GlideTheme.Typography.itemTitle).lineLimit(1).foregroundStyle(.white)
                Text(clip != nil ? clipPosition : (isEpisode && !episodePosition.isEmpty ? episodePosition + " · " : "") + "\(queue.index + 1) / \(queue.ordered.count)" + (queueLoading ? (isEpisode ? " · 正在加载剧集" : " · 正在补全目录") : ""))
                    .font(.caption2).monospacedDigit().foregroundStyle(.white.opacity(0.58)).accessibilityIdentifier("player.queuePosition")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RoundControl(symbol: "rectangle.split.3x3", label: "画面与时刻") { presentNavigation() }
                .disabled(playback.navigationPosition == nil)
                .accessibilityIdentifier("player.navigation")
            RoundControl(symbol: "lock.open", label: "锁定触控") { locked = true; showHUD("已锁定触控"); scheduleHideAfterInteraction() }
            RoundControl(symbol: "ellipsis", label: "播放设置") {
                quickMenuHolding = false; hideTask?.cancel(); settingsOpen = true
            }
        }
    }
    private func exitPlayer() { if let onExit { onExit() } else { dismiss() } }
    private func presentClip() {
        guard let position = playback.navigationPosition, let resource = playback.resource else { return }
        clipWasPlaying = playback.isPlaybackRequested; playback.pause(); hideTask?.cancel(); clipPreparing = true
        Task { @MainActor in
            defer { clipPreparing = false }
            do {
                let reference = try await MomentResolver.reference(video: current, library: library, resource: resource)
                let video = try MomentResolver.storedVideo(current, library: library)
                guard !Task.isCancelled, playback.current?.id == video.id else { return }
                let start = min(position, max(0, playback.duration - 0.5))
                clipDraft = MediaClip(moment: MediaMoment(video: video, reference: reference, position: start, duration: playback.duration, name: ""), end: min(playback.duration, start + 15))
            } catch { clipError = error.localizedDescription; if clipWasPlaying { playback.play() }; clipWasPlaying = false }
        }
    }
    private func presentNavigation(createMoment: Bool = false) {
        guard let position = playback.navigationPosition, let resource = playback.resource else { return }
        quickMenuHolding = false; hideTask?.cancel(); playback.cancelWarmup()
        navigationWasPlaying = playback.isPlaying; navigationTarget = nil
        playback.pause()
        navigationSelection = VideoNavigationPresentation(video: current, resource: resource, duration: playback.duration, position: position, createMoment: createMoment)
    }
    private func finishNavigation() {
        if let target = navigationTarget { playback.seek(target); playback.play() }
        else if navigationWasPlaying { playback.play() }
        navigationTarget = nil; navigationWasPlaying = false; scheduleHide()
    }
    private var settingsPanel: some View {
        NavigationStack {
            Form {
                Section {
                    Button("内容地图与章节", systemImage: "rectangle.split.3x3") { pendingSettingsAction = .navigation; settingsOpen = false }
                        .disabled(playback.navigationPosition == nil).accessibilityIdentifier("player.map.open")
                    Button("收藏精彩片段", systemImage: "scissors") { pendingSettingsAction = .clip; settingsOpen = false }
                        .disabled(playback.navigationPosition == nil || clipPreparing).accessibilityIdentifier("player.clip.create")
                    Button("收藏当前时刻", systemImage: "bookmark") { pendingSettingsAction = .moment; settingsOpen = false }
                        .disabled(playback.navigationPosition == nil).accessibilityIdentifier("player.moment.create")
                    NavigationLink { PlaybackLoopView(playback: playback) } label: { Label("单句重播与 A–B 循环", systemImage: "repeat") }.disabled(clip != nil).accessibilityIdentifier("player.loop.open")
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
                        Divider()
                        Button { skipSettingsOpen = true } label: {
                            Label("片头片尾", systemImage: "forward.end.alt")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.accessibilityIdentifier("player.skip.settings")
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
                        PlayerSettingsLabel(title: "音轨", symbol: "waveform", value: playback.audioMenuValue)
                    }.accessibilityIdentifier("player.audio.menu").disabled(!playback.hasAudioOptions)
                    Menu { subtitleMenuItems } label: {
                        PlayerSettingsLabel(title: "字幕", symbol: "captions.bubble", value: subtitleMenuValue)
                    }.accessibilityIdentifier("player.subtitle.menu")
                    if playback.engineDescriptor.capabilities.contains(.aspectFill) {
                        Button { filled.toggle() } label: {
                            PlayerSettingsLabel(title: filled ? "完整显示画面" : "填满屏幕", symbol: "arrow.up.left.and.arrow.down.right", value: filled ? "已填满" : "适应")
                        }
                    }
                    if !isCinema && !channelMode {
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
                    Button("字幕控制与双字幕…") { pendingSettingsAction = .subtitleControls; settingsOpen = false }.accessibilityIdentifier("player.settings.subtitleControls")
                    Button("导入 SRT／VTT／ASS／SSA 字幕", systemImage: "doc.badge.plus") { pendingSettingsAction = .subtitleImport; settingsOpen = false }
                    if subtitles.discovering { ProgressView("正在匹配同目录字幕…") }
                    if subtitles.reading { ProgressView("正在读取字幕…") }
                    if let name = subtitles.activeName { Text(name).font(.caption).textSelection(.enabled).accessibilityIdentifier("player.subtitle.filename") }
                    if !subtitles.cues.isEmpty || subtitles.hasASS {
                        Stepper("字幕延迟：\(subtitles.delay, specifier: "%.1f") 秒", value: Binding(get: { subtitles.delay }, set: { subtitles.setDelay($0) }), in: -30...30, step: 0.5)
                            .accessibilityIdentifier("player.subtitle.delay")
                        if !subtitles.hasASS { Stepper("字幕底部距离：\(Int(subtitleBottom))%", value: $subtitleBottom, in: 5...35, step: 2) }
                        Button("关闭全部字幕") { playback.closeExternalSubtitles() }
                        Text("外部字幕显示在本机画面中，画中画与 AirPlay 不包含此字幕。").font(.caption).foregroundStyle(.secondary)
                    }
                    if subtitles.hasMemory { Button("清除此视频的字幕记忆") { subtitles.forget() }.accessibilityIdentifier("player.subtitle.forget") }
                    if let message = subtitles.message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("player.subtitle.message") }
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
            .navigationDestination(isPresented: $skipSettingsOpen) {
                PlaybackSkipSettings(session: playback.skips, duration: playback.duration, position: playback.time)
            }
            .navigationTitle("播放设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { settingsOpen = false }.accessibilityIdentifier("player.settings.done")
            } }
        }
        .presentationDetents(skipSettingsOpen ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
    private var subtitleSelectionTitle: String {
        !playback.secondarySubtitles.cues.isEmpty ? (subtitles.cues.isEmpty ? "第二字幕" : "双字幕") : subtitles.activeName ?? playback.selectedServerSubtitle?.label ?? playback.selectedSubtitle?.displayName ?? "关闭"
    }
    private var subtitleMenuValue: String {
        playback.serverSubtitleOptions.isEmpty ? subtitleSelectionTitle : subtitleSelectionTitle + " · \(playback.serverSubtitleOptions.count) 条可选"
    }
    @ViewBuilder private var speedMenuItems: some View {
        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
            Button("\(rate.formatted())×" + (playback.rate == Float(rate) ? " ✓" : "")) { playback.setRate(Float(rate)); scheduleHideAfterInteraction() }
        }
    }
    @ViewBuilder private var audioMenuItems: some View {
        if !playback.serverAudioOptions.isEmpty {
            Section("服务器音轨 · \(playback.serverAudioOptions.count)") {
                ForEach(playback.serverAudioOptions) { stream in
                    Button(stream.label + " · #\(stream.Index)" + (playback.selectedServerAudioIndex == stream.Index ? " ✓" : "")) {
                        playback.chooseServerAudio(stream); scheduleHideAfterInteraction()
                    }.disabled(playback.pictureInPicture.active).accessibilityIdentifier("player.audio.server.\(stream.Index)")
                }
            }
            if playback.pictureInPicture.active { Text("请先关闭画中画，再切换音轨") }
        } else {
            ForEach(playback.audioOptions) { option in
                Button(option.displayName + (playback.selectedAudio == option ? " ✓" : "")) { playback.selectAudio(option); scheduleHideAfterInteraction() }
                    .accessibilityIdentifier("player.audio." + option.id)
            }
            if playback.audioOptions.isEmpty { Text("当前流没有可选音轨") }
        }
    }
    @ViewBuilder private var subtitleMenuItems: some View {
        Button("关闭字幕" + (playback.selectedServerSubtitleIndex == nil && playback.selectedSubtitle == nil && !subtitles.hasASS && !playback.secondarySubtitles.hasASS && subtitles.cues.isEmpty && playback.secondarySubtitles.cues.isEmpty ? " ✓" : "")) { playback.closeExternalSubtitles(); scheduleHideAfterInteraction() }
            .accessibilityIdentifier("player.subtitle.off")
        if !playback.serverSubtitleOptions.isEmpty {
            Section("服务器字幕 · \(playback.serverSubtitleOptions.count)") {
                ForEach(playback.serverSubtitleOptions) { stream in
                    Button(stream.label + " · #\(stream.Index)" + (playback.selectedServerSubtitleIndex == stream.Index ? " ✓" : "")) {
                        playback.chooseServerSubtitle(stream); scheduleHideAfterInteraction()
                    }.disabled(playback.pictureInPicture.active).accessibilityIdentifier("player.subtitle.server.\(stream.Index)")
                }
            }
        } else {
            ForEach(playback.subtitleOptions) { option in
                Button(option.displayName + (playback.selectedSubtitle == option && !subtitles.hasASS && subtitles.cues.isEmpty ? " ✓" : "")) { playback.chooseEmbeddedSubtitle(option); scheduleHideAfterInteraction() }
                    .accessibilityIdentifier("player.subtitle." + option.id)
            }
            if playback.subtitleOptions.isEmpty { Text("当前流没有内嵌字幕") }
        }
        if playback.serverSubtitlePendingIndex != nil { Text("正在读取所选字幕…") }
        if let message = subtitles.message { Text(message) }
        if let saved = subtitles.importedCopy {
            Button("已导入：" + saved.name + (subtitles.choice == saved.choice ? " ✓" : "")) { subtitles.useImportedCopy(); scheduleHideAfterInteraction() }
                .accessibilityIdentifier("player.subtitle.imported")
        }
        if !subtitles.candidates.isEmpty {
            Section("同目录字幕") {
                ForEach(subtitles.candidates) { candidate in
                    Button(candidate.name + (subtitles.activeName == candidate.name ? " ✓" : "")) { subtitles.choose(candidate); scheduleHideAfterInteraction() }
                        .accessibilityIdentifier("player.subtitle.sidecar." + candidate.name)
                }
            }
        }
        if subtitles.discovering { Text("正在匹配同目录字幕…") }
        if subtitles.hasMemory || playback.secondarySubtitles.hasMemory { Button("清除此视频的字幕记忆") { playback.forgetSubtitles(); scheduleHideAfterInteraction() }.accessibilityIdentifier("player.subtitle.forget") }
        Divider()
        Button("字幕控制与双字幕…") { presentSubtitleControls() }
            .accessibilityIdentifier("player.subtitle.controls")
        Button("导入 SRT／VTT／ASS／SSA 字幕") {
            quickMenuHolding = false; hideTask?.cancel()
            if settingsOpen { pendingSettingsAction = .subtitleImport; settingsOpen = false }
            else { beginSubtitleImport() }
        }
    }
    private func presentSubtitleControls() {
        quickMenuHolding = false; hideTask?.cancel(); subtitlePresentationTask?.cancel()
        if settingsOpen { pendingSettingsAction = .subtitleControls; settingsOpen = false; return }
        let videoID = current.id
        subtitlePresentationTask = Task { @MainActor in
            // Let the native menu dismiss before presenting another controller.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, current.id == videoID else { return }
            subtitleControlsOpen = true
        }
    }
    private func finishSubtitleImport() {
        subtitleImportVideoID = nil; controls = true
        if subtitleImportReturnsToControls { presentSubtitleControls() } else { settingsOpen = true }
        subtitleImportReturnsToControls = false
    }
    private func beginSubtitleImport(_ lane: SubtitleLane = .primary, returnToControls: Bool = false) { subtitleImportReturnsToControls = returnToControls; subtitleImportLane = lane; subtitleImportVideoID = current.id; importingSubtitle = true }
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
            if let clip {
                Text("片段 " + clip.moment.position.mediaTime + "–" + clip.end.mediaTime).font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.75)).accessibilityIdentifier("clip.range")
            }
            PlayerLoopStatus(playback: playback)
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
        }.background {
            GeometryReader { proxy in Color.clear.preference(key: PlayerControlsHeightKey.self, value: proxy.size.height) }
                .allowsHitTesting(false)
        }
    }
    private func expandQueue() async {
        guard clip == nil else { queueExpansionComplete = true; return }
        if current.offlineOnly == true { queueExpansionComplete = true; return }
        if channelMode { queueExpansionComplete = true; return }
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
                      server.kind.isCatalogSource, let id = current.remoteID else {
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
            RoundControl(symbol: "backward.end.fill", label: clip != nil ? "上一个片段" : !channelMode && isEpisode ? "上一集" : "上一个视频") { move(-1) }
                .disabled(clip != nil ? !clipCanGoBack : !queue.canGoBack).opacity((clip != nil ? clipCanGoBack : queue.canGoBack) ? 1 : 0.3)
            RoundControl(symbol: "gobackward.10", label: "快退 \(Int(PlaybackPreferences.seekInterval)) 秒") { playback.seek(playback.time - PlaybackPreferences.seekInterval); scheduleHideAfterInteraction() }
            RoundControl(symbol: playback.isPlaybackRequested ? "pause.fill" : "play.fill", label: playback.isPlaybackRequested ? "暂停" : "播放", prominent: true, compact: compact) { playback.toggle(); scheduleHideAfterInteraction() }
                .accessibilityIdentifier(clip != nil ? "clip.toggle" : "player.toggle")
            RoundControl(symbol: "goforward.10", label: "快进 \(Int(PlaybackPreferences.seekInterval)) 秒") { playback.seek(playback.time + PlaybackPreferences.seekInterval); scheduleHideAfterInteraction() }
            RoundControl(symbol: "forward.end.fill", label: clip != nil ? "下一个片段" : !channelMode && isEpisode ? "下一集" : "下一个视频") { move(1) }
                .disabled(clip != nil ? !clipCanGoForward : !queue.canGoForward).opacity((clip != nil ? clipCanGoForward : queue.canGoForward) ? 1 : 0.3)
        }
    }
    private func playbackActions(compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 8) {
            if clip != nil, onFullVideo != nil {
                Button { playback.pause(); onFullVideo?(playback.time) } label: {
                    PlayerQuickActionLabel(title: "观看完整视频", symbol: "play.rectangle")
                }.accessibilityIdentifier("clip.fullVideo")
            } else if isEpisode {
                Button { quickMenuHolding = false; hideTask?.cancel(); episodesOpen = true } label: {
                    PlayerQuickActionLabel(title: "选集", symbol: "list.bullet.rectangle")
                }.accessibilityIdentifier("player.episodes")
            } else if !isCinema && !channelMode {
                Button { changeMode(queue.mode == .sequential ? .random : .sequential) } label: {
                    PlayerQuickActionLabel(title: queue.mode == .random ? "随机" : "顺序", symbol: queue.mode.symbol)
                }.accessibilityLabel(queue.mode.title).accessibilityIdentifier("player.mode")
            }
            Menu { speedMenuItems } label: {
                PlayerQuickActionLabel(title: "\(playback.rate.formatted())×", symbol: "speedometer")
            }.accessibilityLabel("播放速度").accessibilityIdentifier("player.quick.speed")
                .simultaneousGesture(TapGesture().onEnded { holdControlsForQuickMenu() })
            Menu { audioMenuItems } label: {
                PlayerQuickActionLabel(title: playback.serverAudioOptions.count > 1 ? "音轨 · \(playback.serverAudioOptions.count)" : "音轨", symbol: "waveform")
            }.accessibilityLabel("音轨").accessibilityValue(playback.audioMenuValue)
                .accessibilityIdentifier("player.quick.audio")
                .simultaneousGesture(TapGesture().onEnded { if playback.hasAudioOptions { holdControlsForQuickMenu() } })
                .disabled(!playback.hasAudioOptions).opacity(playback.hasAudioOptions ? 1 : 0.45)
            Menu { subtitleMenuItems } label: {
                PlayerQuickActionLabel(title: "字幕", symbol: "captions.bubble", active: subtitles.hasASS || subtitles.hasBitmap || !subtitles.cues.isEmpty || !playback.secondarySubtitles.cues.isEmpty || playback.selectedSubtitle != nil)
            }.accessibilityLabel("字幕").accessibilityValue(subtitleMenuValue)
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
        guard !channelMode else { return }
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
        if clip != nil { if automatic { onClipCompleted?() } else { onClipMove?(delta) }; return }
        if !automatic { pendingAutomaticAdvance = false }
        guard queue.move(delta) else {
            if automatic && channelMode { onQueueFinished?() }
            if delta > 0 && !queueExpansionComplete && (loadFullQueue != nil || isEpisode && queue.source.count == 1) {
                if automatic { pendingAutomaticAdvance = true }
                showHUD(isEpisode ? "正在加载下一集…" : "正在加载下一部…")
                return
            }
            if automatic { controls = true }
            showHUD(delta > 0 ? (channelMode ? "频道本次已播完" : isEpisode ? "已经是最后一集" : isCinema ? "已播放完毕" : "本目录已刷完") : (channelMode ? "已经是频道第一条" : isEpisode ? "已经是第一集" : "已经是第一部"))
            return
        }
        playCurrent(automatic: automatic)
    }
    private func playCurrent(automatic: Bool) {
        // Stream indices and source IDs belong to one file, never reuse them for another episode.
        playback.tracks = TrackSelection()
        playback.open(current, library: library, recordsProgress: recordsProgress)
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
        guard !voiceOverEnabled, !quickMenuHolding, controls, scrubTarget == nil, !settingsOpen, !subtitleControlsOpen, !diagnosticOpen, !episodesOpen, !videoInfoOpen, navigationSelection == nil, clipDraft == nil, !clipPreparing else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(PlaybackPreferences.controlsDelay))
            guard !Task.isCancelled, !voiceOverEnabled, !quickMenuHolding, scrubTarget == nil, !settingsOpen, !subtitleControlsOpen, !diagnosticOpen, !episodesOpen, !videoInfoOpen, navigationSelection == nil, clipDraft == nil, !clipPreparing, playback.error == nil, playback.isPlaying else { return }
            withAnimation { controls = false }
        }
    }
}

/// Observe the playback clock here so the player menus do not rebuild every tick.
private struct PlayerSkipControls: View {
    var playback: PlaybackController
    var locked: Bool
    var controls: Bool
    var landscape: Bool
    var onInteraction: () -> Void
    static func bottomInset(controls: Bool, landscape: Bool) -> CGFloat { controls ? (landscape ? 152 : 210) : 28 }
    var body: some View {
        if !locked, playback.frameReady, playback.error == nil, let segment = playback.activeSkip {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Button {
                            onInteraction(); playback.skip(segment)
                        } label: {
                            Label(segment.kind.title, systemImage: "forward.end").frame(minHeight: 44)
                        }
                            .accessibilityIdentifier("player.skip.action")
                            .disabled(playback.isSeeking)
                        Button {
                            onInteraction(); playback.skips.consume(segment)
                        } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("本次不跳过").accessibilityIdentifier("player.skip.dismiss")
                    }.font(.subheadline.weight(.medium)).padding(.leading, 14)
                        .background(.black.opacity(0.8), in: Capsule()).foregroundStyle(.white)
                }
            }.padding(.horizontal, 24).padding(.bottom, Self.bottomInset(controls: controls, landscape: landscape))
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
    private var lowerBound: Double { playback.clip?.moment.position ?? 0 }
    private var visibleDuration: Double { playback.clip?.length ?? playback.duration }
    private var visibleRanges: [BufferedRange] {
        guard playback.clip != nil else { return playback.bufferedRanges }
        return playback.bufferedRanges.compactMap { range in
            let start = max(0, range.start - lowerBound), end = min(visibleDuration, range.end - lowerBound)
            return end > start ? BufferedRange(start: start, end: end) : nil
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            BufferedSeekBar(value: max(0, (scrubTarget ?? playback.time) - lowerBound),
                            duration: visibleDuration, ranges: visibleRanges,
                            onScrubStart: { onScrubStart(); scrubTarget = playback.time },
                            onScrubChange: { scrubTarget = $0 + lowerBound },
                            onScrubEnd: { target in scrubTarget = nil; playback.seek(target + lowerBound); onScrubEnd() })
            HStack(spacing: 12) {
                Text(max(0, (scrubTarget ?? playback.time) - lowerBound).mediaTime).accessibilityIdentifier("player.elapsed")
                Spacer(minLength: 8)
                Text(deliveryTitle).font(.caption2).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.65))
                    .accessibilityIdentifier("player.delivery")
                    .accessibilityValue(playback.resource?.delivery.title ?? "连接中")
                Spacer(minLength: 8)
                Text(visibleDuration.mediaTime).accessibilityLabel("总时长，" + visibleDuration.mediaTime)
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

struct PlayerPGSOverlay: View {
    var session: SubtitleSession
    var filled = false
    var body: some View {
        if let frame = session.bitmapFrame {
            GeometryReader { geometry in
                let sx = geometry.size.width / CGFloat(frame.width), sy = geometry.size.height / CGFloat(frame.height)
                let scale = filled ? max(sx, sy) : min(sx, sy)
                let originX = (geometry.size.width - CGFloat(frame.width) * scale) / 2
                let originY = (geometry.size.height - CGFloat(frame.height) * scale) / 2
                ZStack(alignment: .topLeading) {
                    ForEach(frame.layers.indices, id: \.self) { index in
                        let layer = frame.layers[index]
                        Image(decorative: layer.image, scale: 1).resizable()
                            .frame(width: CGFloat(layer.rect.width) * scale, height: CGFloat(layer.rect.height) * scale)
                            .offset(x: originX + CGFloat(layer.rect.x) * scale, y: originY + CGFloat(layer.rect.y) * scale)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
            }.allowsHitTesting(false).accessibilityLabel("PGS 图形字幕").accessibilityIdentifier("player.subtitle.bitmap")
        }
    }
}

struct PlayerSubtitleOverlay: View {
    var playback: PlaybackController
    var cues: [SubtitleCue]
    var delay: Double
    var bottomInset: CGFloat
    var secondaryCues: [SubtitleCue] = []
    var secondaryDelay: Double = 0
    @AppStorage("externalSubtitleAppearance.v1") private var appearanceData = Data()
    @AppStorage("subtitleScale") private var legacyScale = 100.0
    @AppStorage("externalSubtitleSecondaryScale") private var legacySecondaryScale = 85.0
    var body: some View {
        let primary = SubtitleCue.visible(cues, time: playback.time, delay: delay)
        let secondary = SubtitleCue.visible(secondaryCues, time: playback.time, delay: secondaryDelay)
        if primary != nil || secondary != nil {
            VStack {
                Spacer()
                SubtitleCaptionStack(primary: primary, secondary: secondary, appearance: .restore(appearanceData, legacyScale: legacyScale, legacySecondaryScale: legacySecondaryScale))
                .padding(.horizontal, 24).padding(.bottom, bottomInset)
            }.allowsHitTesting(false)
        }
    }
}

private struct PlayerLoopStatus: View {
    var playback: PlaybackController
    var body: some View {
        if let loop = playback.loop {
            HStack(spacing: 8) {
                Label(loop.mode == .once ? "单句重播" : "A–B \(loop.start.mediaTime)–\(loop.end.mediaTime)", systemImage: "repeat")
                    .accessibilityIdentifier("player.loop.status")
                Spacer()
                Button("退出") { playback.clearLoop() }.frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("player.loop.clear")
            }.font(.caption).foregroundStyle(GlideTheme.accent)
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
            UIColor.white.setFill()
            let fraction = min(1, max(0, value / duration))
            UIBezierPath(roundedRect: CGRect(x: 15, y: y - 2, width: width * CGFloat(fraction), height: 4), cornerRadius: 2).fill()
        }
        let fraction = duration > 0 ? min(1, max(0, value / duration)) : 0
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: 15 + width * CGFloat(fraction) - 10, y: y - 10, width: 20, height: 20)).fill()
    }
}

private struct PlayerControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
