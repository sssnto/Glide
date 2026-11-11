import SwiftUI

struct PlaySelection: Identifiable {
    var id = UUID()
    var queue: PlaybackQueue
    var scopeName: String
    var initialResumeAt: Double? = nil
    var loadFullQueue: (() async throws -> [Video])? = nil
}

enum LibrarySheet: String, Identifiable {
    case sources, help, personal, pins, downloads, settings, links, unified, rotationQueue
    var id: String { rawValue }
}

private enum HomeBrowseView: String {
    case directories, videos
}

struct LibraryView: View {
    var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var rotationInline = RotationInlineSelection()
    @State private var sheet: LibrarySheet?
    @State private var selection: PlaySelection?
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var favoritesOnly = false
    @AppStorage("playbackMode") private var playbackMode: PlaybackMode = .sequential
    @State private var homeBrowseView: HomeBrowseView = .videos
    @State private var preparing = false
    @State private var preparedCount = 0
    @State private var preparationID: UUID?
    @State private var preparationTask: Task<Void, Never>?
    @State private var queueError: String?
    @State private var deletingImportedVideo: Video?
    @State private var deletionError: String?
    @State private var resultVideos: [Video] = []
    @State private var resultKey: String?
    @State private var resultOwner: String?
    @State private var failedKey: String?
    @State private var searchError: String?
    @State private var searchedCount = 0
    @State private var filterAttempt = 0
    @State private var pendingPersonalVideo: Video?
    @State private var pendingBookmark: DirectoryBookmark?
    @State private var visibleID: String?
    @State private var orderedFolders: [MediaFolder] = []
    @State private var orderedDirectories: [DAVEntry] = []
    @State private var orderedFolderKey = ""
    private var folderPresentationKey: String {
        library.scopeKey + ":" + library.contentRevision.uuidString + ":" + library.folderSort.rawValue + ":\(library.folders.count):\(library.directories.count)"
    }
    private var positionKey: String { library.scopeKey + ":" + homeBrowseView.rawValue + ":" + term + ":" + String(favoritesOnly) }
    private func restorePosition() { visibleID = library.browserPositions[positionKey] }

    private var term: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var usesFilters: Bool { !term.isEmpty || favoritesOnly }
    private var showsDirectories: Bool { library.selectedID != nil && (isLibraryRoot || homeBrowseView == .directories) }
    private var showsVideos: Bool { library.selectedID == nil || (!isLibraryRoot && homeBrowseView == .videos) }
    private var filterTaskKey: String { filterKey + (showsVideos ? ":videos" : ":directories") }
    private var filterKey: String {
        [library.scopeKey, library.contentRevision.uuidString, term, String(library.loading),
         favoritesOnly ? library.favorites.sorted().joined(separator: "|") + ":favorites" : "all", String(filterAttempt)].joined(separator: "\n")
    }
    private var resultScope: String { library.scopeKey + ":" + term + ":" + (favoritesOnly ? library.favorites.sorted().joined(separator: "|") : "all") }
    private var filtering: Bool { usesFilters && !isLibraryRoot && resultKey != filterKey && failedKey != filterKey }

    private var filtered: [Video] {
        usesFilters ? (resultOwner == resultScope ? resultVideos : []) : library.videos
    }
    var body: some View {
        Group {
            if let server = library.selectedServer, server.kind.isCatalogSource,
               let folder = library.jellyPath.first, LibraryExperience(collectionType: folder.collectionType) != .home {
                CatalogView(library: library, server: server, folder: folder)
            } else { homeBody }
        }
        .modifier(RotationStatusWatcher(store: library.rotationQueue, server: library.selectedServer, ids: library.videos.compactMap(\.remoteID)))
        .onChange(of: library.locationKey) { _, _ in
            rotationInline.end()
            homeBrowseView = .videos
            search = ""; favoritesOnly = false; restorePosition()
        }
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--glide-ui-audit"), ProcessInfo.processInfo.arguments.contains("--glide-ui-audit-sources") { sheet = .sources }
        }
        #endif
    }
    private var homeBody: some View {
        NavigationStack {
            homeContent
                .navigationTitle(library.selectedID == nil ? "片库" : library.currentDirectoryName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { sheet = .sources } label: { Label("媒体来源", systemImage: "externaldrive") }
                            .accessibilityIdentifier("sources.open")
                            .accessibilityValue(library.selectedServer?.name ?? "未连接")
                    }
                    ToolbarItem(placement:.topBarTrailing) {
                        if library.selectedServer?.kind == .jellyfin,!library.jellyPath.isEmpty,showsVideos,!rotationInline.active {
                            Button("选择") { rotationInline.begin() }.accessibilityLabel("选择视频以批量旋转").accessibilityIdentifier("rotation.inline.begin")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if rotationInline.active {
                            Button("取消选择") { rotationInline.end() }.accessibilityIdentifier("rotation.inline.cancel")
                        } else { Menu {
                            if library.selectedServer?.kind == .jellyfin {
                                if !library.jellyPath.isEmpty { Button("批量旋转", systemImage: "checkmark.circle") { homeBrowseView = .videos; rotationInline.begin() }.accessibilityIdentifier("rotation.batch.open") }
                                Button("旋转任务", systemImage: "list.bullet.rectangle") { sheet = .rotationQueue }
                                Divider()
                            }
                            Button { sheet = .unified } label: { Label("搜索全部片库", systemImage: "magnifyingglass") }
                            Button { sheet = .links } label: { Label("链接与 STRM", systemImage: "link") }.accessibilityIdentifier("links.open")
                            Button { sheet = .pins } label: { Label("固定目录", systemImage: "pin") }.accessibilityIdentifier("pins.open")
                            if library.canPinDirectory {
                                Button(library.isDirectoryPinned ? "取消固定此目录":"固定此目录",systemImage:library.isDirectoryPinned ? "pin.slash":"pin") { library.toggleDirectoryPin() }.accessibilityIdentifier("directory.pin")
                            }
                            Button("刷新当前范围",systemImage:"arrow.clockwise") { Task { await library.reload() } }.disabled(library.loading).accessibilityIdentifier("directory.refresh")
                            if library.selectedServer?.kind == .webDAV,let date=library.directoryScanDate {
                                Text("上次扫描："+date.formatted(date:.abbreviated,time:.shortened)).accessibilityIdentifier("directory.cached")
                            }
                            Divider()
                            Button("设置与媒体来源",systemImage:"gearshape") { sheet = .settings }
                        } label: { Label("更多", systemImage: "ellipsis.circle") }
                        .accessibilityIdentifier("library.more") }
                    }
                }
        }
        .modifier(RotationInlineControls(library:library,server:library.selectedServer,selection:rotationInline,loaded:filtered))
        .onChange(of:homeBrowseView) { _,value in if value == .directories { rotationInline.end() } }
    }
    private var homeContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if library.selectedID != nil && !isLibraryRoot {
                    directoryNavigation.padding(.horizontal, geometry.size.width > 600 ? 32 : 16)
                        .padding(.vertical, 2)
                    Picker("浏览方式", selection: $homeBrowseView) {
                        Text("媒体").tag(HomeBrowseView.videos)
                        Text("目录").tag(HomeBrowseView.directories)
                    }.pickerStyle(.segmented).accessibilityIdentifier("library.contentView")
                        .padding(.horizontal, geometry.size.width > 600 ? 32 : 16)
                        .padding(.vertical, 6)
                }
                if showsVideos && library.selectedID != nil {
                    searchBox.padding(.horizontal, geometry.size.width > 600 ? 32 : 16).padding(.vertical, 6)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        pinnedSection
                        if showsDirectories { folderSection(width: geometry.size.width) }
                        if let error = library.error {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(error, systemImage: "wifi.exclamationmark").font(.subheadline)
                                HStack(spacing: 12) {
                                    Button("重新加载") { Task { await library.reload() } }.buttonStyle(.bordered)
                                    Button("管理媒体源") { sheet = .sources }.buttonStyle(.borderedProminent)
                                }
                            }.padding().frame(maxWidth: .infinity, alignment: .leading).background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                        }
                        if library.loading && library.selectedServer?.kind.isFileSource == true {
                            HStack {
                                ProgressView()
                                Text("已找到 \(library.scannedVideoCount) 个视频").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("停止扫描") { library.cancelDirectoryScan() }.font(.caption).frame(minHeight: 44)
                                    .accessibilityIdentifier("directory.cancelScan")
                            }
                        } else if library.scanStopped {
                            Text("扫描已停止，已保留当前结果。下拉刷新可重新扫描。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if showsVideos {
                            videoHeading
                            if rotationInline.active {
                                Text("点选缩略图勾选视频，长按可预览方向。")
                                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                            }
                        }
                        if showsVideos {
                            if filtering && filtered.isEmpty {
                                ProgressView("正在搜索当前范围…已读取 \(searchedCount) 个视频")
                                    .font(.caption).frame(maxWidth: .infinity).padding(24).accessibilityIdentifier("search.loading")
                            } else if usesFilters && failedKey == filterKey && filtered.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(searchError ?? "搜索失败，请重试。").font(.subheadline)
                                    Button("重试搜索") { filterAttempt += 1 }
                                }.padding().background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                            } else if library.loading && filtered.isEmpty { ProgressView("正在读取媒体库…").frame(maxWidth: .infinity).padding(30) }
                            else if filtered.isEmpty && library.error == nil {
                                ContentUnavailableView(favoritesOnly ? "此范围还没有收藏" : search.isEmpty ? "这里还没有视频" : "没有匹配的视频", systemImage: favoritesOnly ? "heart" : "film", description: Text(favoritesOnly ? "播放时点亮爱心，把喜欢的留住。" : "检查媒体库权限，或换一个文件夹。"))
                            } else {
                                AdaptiveMediaGrid(minimum: geometry.size.width > 600 ? 160 : 100) {
                                    ForEach(filtered) { video in
                                        videoCard(video).id("video:" + video.id)
                                            .task { if !usesFilters && video.id == library.videos.last?.id { await library.more() } }
                                    }
                                }.scrollTargetLayout()
                            }
                            if library.loading && !filtered.isEmpty { ProgressView("正在更新…").font(.caption).frame(maxWidth: .infinity) }
                            if !filtered.isEmpty && usesFilters && failedKey == filterKey {
                                Text(searchError ?? "更新失败，已保留原结果。").font(.caption).foregroundStyle(.orange)
                                Button("重试搜索") { filterAttempt += 1 }
                            }
                            if library.hasMore && !usesFilters {
                                Button("加载更多视频（\(library.nextIndex) / \(library.total)）") { Task { await library.more() } }.frame(maxWidth: .infinity)
                            }

                        } else if library.loading {
                            ProgressView(isLibraryRoot ? "正在读取媒体库…" : "正在读取目录…").frame(maxWidth: .infinity).padding(30)
                        } else if library.folders.isEmpty && library.directories.isEmpty && library.error == nil {
                            if isLibraryRoot {
                                ContentUnavailableView("没有可用的媒体库", systemImage: "square.stack.3d.up", description: Text("检查服务器中的媒体库配置和当前账号的访问权限。"))
                            } else {
                                VStack(spacing: 12) {
                                    ContentUnavailableView("没有子目录", systemImage: "folder", description: Text("切换到媒体，查看当前范围内的内容。"))
                                    Button("查看媒体") { homeBrowseView = .videos }.buttonStyle(.bordered)
                                }
                            }
                        }
                    }.padding(.horizontal, geometry.size.width > 600 ? 32 : 16).padding(.top, 12).padding(.bottom, 24)
                        .frame(maxWidth: 1100)
                        .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollPosition(id: $visibleID, anchor: .top)
                .onChange(of: visibleID) { _, id in
                    if let id, id.hasPrefix("video:") || id.hasPrefix("folder:"), library.browserPositions[positionKey] != id {
                        library.browserPositions[positionKey] = id
                    }
                }
                .refreshable {
                    let anchor = visibleID
                    await library.reload()
                    visibleID = anchor
                }
                .onAppear { restorePosition() }
                .id(homeBrowseView)
                .onChange(of: homeBrowseView) { _, _ in
                    cancelPreparation(); queueError = nil; visibleID = nil
                }
            }.background(GlideTheme.background)
        }
        .task { await library.loadIfNeeded(); restorePosition() }
        .task(id: filterTaskKey) { await searchCurrentScope() }
        .task(id: folderPresentationKey) {
            // Sort when contents change, not for every visible scroll anchor.
            orderedFolders = library.folderSort.sorted(library.folders)
            orderedDirectories = library.folderSort.sorted(library.directories)
            orderedFolderKey = folderPresentationKey
        }
        .onChange(of: library.scopeKey) { _, _ in cancelPreparation(); queueError = nil }
        .onChange(of: library.browseOptions) { _, _ in visibleID = nil }
        .onChange(of: search) { _, _ in visibleID = nil }
        .onChange(of: favoritesOnly) { _, _ in visibleID = nil }
        .onDisappear { cancelPreparation() }
        .overlay { preparationOverlay }
        .alert("无法准备播放队列", isPresented: Binding(get: { queueError != nil }, set: { if !$0 { queueError = nil } })) { Button("知道了") { queueError = nil } } message: { Text(queueError ?? "") }
        .confirmationDialog("删除导入的视频？", isPresented: Binding(get: { deletingImportedVideo != nil }, set: { if !$0 { deletingImportedVideo = nil } }), titleVisibility: .visible) {
            if let video = deletingImportedVideo {
                Button("删除 Glide 内的副本", role: .destructive) {
                    deletingImportedVideo = nil
                    Task { do { try await library.deleteImportedVideo(video) } catch { deletionError = error.localizedDescription } }
                }
            }
            Button("取消", role: .cancel) { deletingImportedVideo = nil }
        } message: { Text("同时移除此视频的本机收藏与记录。原始文件保留在导入前的位置。") }
        .alert("无法删除视频", isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } })) {
            Button("知道了") { deletionError = nil }
        } message: { Text(deletionError ?? "") }
        .sheet(item: $sheet, onDismiss: {
            if let bookmark = pendingBookmark {
                pendingBookmark = nil
                Task { await library.openBookmark(bookmark) }
            } else if let video = pendingPersonalVideo {
                pendingPersonalVideo = nil
                selection = PlaySelection(queue: PlaybackQueue(videos: [video], mode: .sequential), scopeName: "个人片库")
            }
        }) { destination in
            switch destination {
            case .rotationQueue:
                if let server = library.selectedServer {
                    NavigationStack { RotationQueueView(library: library, server: server).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } } }
                }
            case .unified: NavigationStack { UnifiedLibraryView(library: library).toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { sheet = nil } } } }
            case .links: NavigationStack { StreamLinksView(library: library).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } } }
            case .sources: SourcesView(library: library)
            case .downloads: NavigationStack { DownloadsView(library: library).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } } }
            case .settings: NavigationStack { SettingsView(library: library).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheet = nil } } } }
            case .help: GestureHelpView()
            case .personal: PersonalLibraryView(library: library) { pendingPersonalVideo = $0 }
            case .pins: PinnedDirectoriesView(library: library) { pendingBookmark = $0 }
            }
        }
        .fullScreenCover(item: $selection) { selection in
            PlayerView(library: library, queue: selection.queue, scopeName: selection.scopeName, cinematic: ["Movie", "Episode"].contains(selection.queue.current?.mediaType ?? ""), loadFullQueue: selection.loadFullQueue)
        }
    }
    private var searchBox: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(GlideTheme.muted)
            TextField(library.browseOptions.includesDescendants ? "搜索当前目录及子目录" : "搜索当前层的视频", text: $search)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                .focused($searchFocused).onSubmit { searchFocused = false }.accessibilityIdentifier("library.search")
            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("清除搜索") }
        }.font(GlideTheme.Typography.body).padding(.horizontal, 12).frame(minHeight: 44)
            .background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 10))
    }
    private func searchCurrentScope() async {
        let key = filterKey, query = term, favoriteIDs = favoritesOnly ? library.favorites : nil
        guard showsVideos, usesFilters, !isLibraryRoot, !library.loading, resultKey != key else { return }
        searchedCount = 0; searchError = nil
        do {
            try await Task.sleep(for: .milliseconds(300))
            let all = try await library.collectPlaybackVideos(search: query) { count in
                if key == filterKey { searchedCount = count }
            }
            try Task.checkCancellation()
            guard key == filterKey else { return }
            resultVideos = all.filter { (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) && (favoriteIDs == nil || favoriteIDs!.contains($0.id)) }
            library.remember(resultVideos)
            resultKey = key; resultOwner = resultScope; failedKey = nil
        } catch {
            guard !Task.isCancelled, key == filterKey else { return }
            searchError = error.localizedDescription; failedKey = key
        }
    }
    private var isLibraryRoot: Bool { library.selectedServer?.kind.isCatalogSource == true && library.jellyPath.isEmpty }
    private var modePicker: some View {
        Picker("播放顺序", selection: $playbackMode) {
            ForEach(PlaybackMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
        }.pickerStyle(.segmented).accessibilityIdentifier("queue.mode")
    }
    @ViewBuilder private var preparationOverlay: some View {
        if preparing {
            ZStack {
                Color.black.opacity(0.7).ignoresSafeArea()
                VStack(spacing: 18) {
                    ProgressView().tint(GlideTheme.accent)
                    Text("正在收集目录下的视频").font(.headline)
                    Text("\(library.browseOptions.scopeTitle) · 已找到 \(preparedCount) 个视频").font(.caption).foregroundStyle(GlideTheme.muted)
                    Button("取消") { cancelPreparation() }.padding(8)
                }.padding(30).background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 22))
            }
        }
    }
    private func cancelPreparation() {
        preparationTask?.cancel(); preparationTask = nil; preparationID = nil; preparing = false
    }
    private func startPlayback(selected: Video? = nil, useFilters: Bool = false) {
        cancelPreparation()
        let id = UUID(), scope = library.scopeKey, name = library.currentDirectoryName, mode = playbackMode
        let query = useFilters ? term : "", favorites = useFilters && favoritesOnly ? library.favorites : nil
        if useFilters && usesFilters && resultKey == filterKey {
            guard !resultVideos.isEmpty else { return }
            selection = PlaySelection(queue: PlaybackQueue(videos: resultVideos, mode: mode, startID: selected?.id), scopeName: name)
            return
        }
        if !usesFilters, mode == .sequential || !library.hasMore, !library.videos.isEmpty, selected == nil || library.videos.contains(where: { $0.id == selected?.id }) {
            let completeScope = scope
            let needsExpansion = library.hasMore
            let loader: (() async throws -> [Video])? = needsExpansion ? {
                let videos = try await library.collectPlaybackVideos { _ in }
                try Task.checkCancellation()
                guard library.scopeKey == completeScope else { throw CancellationError() }
                return videos
            } : nil
            selection = PlaySelection(queue: PlaybackQueue(videos: library.videos, mode: mode, startID: selected?.id), scopeName: name, loadFullQueue: loader)
            return
        }
        preparing = true; preparedCount = 0; preparationID = id; queueError = nil
        preparationTask = Task {
            defer { if preparationID == id { preparing = false; preparationTask = nil; preparationID = nil } }
            do {
                var videos = try await library.collectPlaybackVideos(search: query) { count in
                    if preparationID == id { preparedCount = count }
                }
                try Task.checkCancellation()
                guard preparationID == id, scope == library.scopeKey else { return }
                videos = videos.filter { (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) && (favorites == nil || favorites!.contains($0.id)) }
                guard !videos.isEmpty else { throw MediaError.message("当前范围中没有符合条件的视频。") }
                selection = PlaySelection(queue: PlaybackQueue(videos: videos, mode: mode, startID: selected?.id), scopeName: name)
            } catch {
                if !Task.isCancelled, preparationID == id { queueError = error.localizedDescription }
            }
        }
    }
    @ViewBuilder private var directoryNavigation: some View {
        if library.hasParent {
            HStack(spacing:8) {
                Button { Task { await library.back() } } label: {
                    Image(systemName:"arrow.turn.up.left").frame(width:44,height:44)
                }.accessibilityLabel("返回上一级目录").accessibilityIdentifier("directory.back")
                if library.selectedServer?.kind.isCatalogSource == true {
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:6) {
                            Button("媒体库") { Task { await library.jump(to:0) } }.frame(minHeight:44)
                            ForEach(Array(library.jellyPath.enumerated()),id:\.element.id) { depth,folder in
                                Image(systemName:"chevron.right").font(.system(size:8))
                                Button(folder.name) { Task { await library.jump(to:depth+1) } }.lineLimit(1).frame(minHeight:44)
                            }
                        }
                    }
                } else {
                    Text(library.path.map(\.lastPathComponent).joined(separator:" / ")).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength:0)
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func folderSection(width: CGFloat) -> some View {
        if let server = library.selectedServer, isLibraryRoot || !library.folders.isEmpty || !library.directories.isEmpty {
            let orderedFolders = orderedFolderKey == folderPresentationKey ? self.orderedFolders : []
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isLibraryRoot ? "媒体库" : "目录").font(GlideTheme.Typography.sectionTitle)
                    Spacer()
                    Text("\(library.folders.count + library.directories.count) 个")
                        .font(.caption).foregroundStyle(GlideTheme.muted)
                    Menu {
                        ForEach(FolderSort.allCases) { sort in
                            Button {
                                Task { await library.setFolderSort(sort) }
                            } label: {
                                Label(sort.title, systemImage: library.folderSort == sort ? "checkmark" : "arrow.up.arrow.down")
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("目录排序：" + library.folderSort.title)
                    .accessibilityIdentifier("folders.sort")
                }
                AdaptiveMediaGrid(minimum: width > 600 ? 160 : 100, rowSpacing: 16) {
                    ForEach(orderedFolders) { folder in
                        LibraryFolderTile(title: folder.name, server: server, folder: folder, isLibrary: isLibraryRoot) {
                            Task { await library.enter(folder) }
                        }
                            .accessibilityIdentifier("folder." + folder.id).id("folder:" + folder.id)
                            .task { if folder.id == orderedFolders.last?.id && library.hasMoreFolders { await library.moreFolders() } }
                    }
                    ForEach(orderedFolderKey == folderPresentationKey ? orderedDirectories : []) { entry in
                        LibraryFolderTile(title: entry.name, server: server, directory: entry, artworkRevision:library.artworkRevision) {
                            Task { await library.enter(entry.url) }
                        }
                            .accessibilityIdentifier("folder." + entry.id).id("folder:" + entry.id)
                    }
                }.scrollTargetLayout()
            }
        }
        if library.hasMoreFolders { Button("加载更多目录") { Task { await library.moreFolders() } }.font(.subheadline) }
    }
    private var videoHeading: some View {
        HStack(spacing:8) {
            VStack(alignment:.leading,spacing:3) {
                Text(favoritesOnly ? "收藏视频":term.isEmpty ? "全部视频":"搜索结果").font(.subheadline.weight(.semibold))
                Text(usesFilters ? "\(filtered.count) 个结果":library.selectedID == nil ? "原创演示 · 可离线播放":"\(library.total) 个视频 · \(library.browseOptions.scopeTitle)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("videos.heading")
            browseOptionsBar
            if !rotationInline.active { playDirectoryButton }
        }
    }
    private var playDirectoryButton: some View {
        Button { startPlayback(useFilters:usesFilters) } label: {
            Image(systemName:"play.fill").font(.subheadline.weight(.semibold)).frame(width:48,height:44)
        }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
            .accessibilityLabel(usesFilters ? "播放搜索结果":library.selectedID == nil ? "播放演示":"播放全部视频")
            .disabled(library.loading || filtering || filtered.isEmpty)
            .accessibilityIdentifier(library.selectedID == nil ? "demo.play":"directory.play")
    }
    private var browseOptionsBar: some View {
        Menu {
            if library.selectedID != nil {
                Picker("浏览范围",selection:Binding(get:{library.browseOptions.includesDescendants},set:{ recursive in
                    var options=library.browseOptions;options.includesDescendants=recursive
                    Task { await library.setBrowseOptions(options) }
                })) { Text("包含子目录").tag(true);Text("仅当前层").tag(false) }.accessibilityIdentifier("library.scope")
                Picker("视频排序",selection:Binding(get:{library.browseOptions.sort},set:{ sort in
                    var options=library.browseOptions;options.sort=sort
                    Task { await library.setBrowseOptions(options) }
                })) { ForEach(VideoSort.allCases) { sort in Label(sort.title,systemImage:sort.symbol).tag(sort) } }
            }
            Toggle("只看收藏",isOn:$favoritesOnly)
            Picker("播放顺序",selection:$playbackMode) {
                ForEach(PlaybackMode.allCases) { mode in Label(mode.title,systemImage:mode.symbol).tag(mode) }
            }.accessibilityIdentifier("queue.mode")
        } label: { Image(systemName:"line.3.horizontal.decrease").frame(width:44,height:44) }
            .accessibilityLabel("筛选、排序与播放顺序").accessibilityIdentifier("library.sort")
    }
    @ViewBuilder private var pinnedSection: some View {
        let eligible = library.bookmarks.filter { $0.sourceID == library.selectedID && LibraryExperience(collectionType: $0.jellyPath.first?.collectionType) == .home }
        if (isLibraryRoot || library.selectedServer?.kind.isFileSource == true && library.path.isEmpty) && !eligible.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("固定目录").font(GlideTheme.Typography.sectionTitle)
                    Spacer()
                    Button("管理") { sheet = .pins }.font(.caption).frame(minHeight: 44)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(eligible) { bookmark in
                            HStack(spacing: 8) {
                            Button { Task { await library.openBookmark(bookmark) } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(bookmark.name, systemImage: "pin.fill").font(.subheadline).lineLimit(1)
                                    Text(library.servers.first { $0.id == bookmark.sourceID }?.name ?? "来源已移除").font(.caption).foregroundStyle(GlideTheme.muted).lineLimit(1)
                                }.padding(14).background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(.plain).accessibilityIdentifier("quickPin." + bookmark.id)
                            Button { Task {
                                guard await library.openBookmark(bookmark) else { return }
                                startPlayback()
                            } } label: { Image(systemName: "play.fill").frame(width: 44, height: 44) }
                                .accessibilityLabel("刷看 " + bookmark.name).accessibilityIdentifier("quickPin.play." + bookmark.id)
                            }
                        }
                    }
                }
            }
        }
    }
    private func cardArtwork(_ video:Video)->some View {
                VideoPreviewArtwork(video: video, server: library.servers.first { $0.id == video.sourceID })
                    .overlay(alignment: .bottomTrailing) { if !dynamicTypeSize.isAccessibilitySize { Text(video.duration > 0 ? video.duration.mediaTime : "视频").font(.system(.caption2, design: .monospaced, weight: .semibold)).foregroundStyle(.white).padding(6).background(.black.opacity(0.65), in: Capsule()).padding(9) } }
                    .overlay(alignment: .topLeading) { if !dynamicTypeSize.isAccessibilitySize,library.favorites.contains(video.id) { Image(systemName: "heart.fill").font(.caption).foregroundStyle(GlideTheme.accent).padding(10) } }
                    .overlay(alignment:.topTrailing) { if rotationInline.active { RotationSelectionMark(selected:rotationInline.contains(video)) } }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private func cardMetadata(_ video:Video)->some View {
        VStack(alignment:.leading,spacing:6) {
                Text(RecommendationMediaIdentity(video).title).font(GlideTheme.Typography.itemTitle).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil:2)
                if let episode=RecommendationMediaIdentity(video).episode { Text(episode).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                VideoRotationStatus(server: library.servers.first { $0.id == video.sourceID }, itemID: video.remoteID)
                if dynamicTypeSize.isAccessibilitySize {
                    if video.duration>0 { Text("片长 "+video.duration.mediaTime).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    if library.favorites.contains(video.id) { Text("已收藏").font(.caption).foregroundStyle(.secondary) }
                }
                Text(video.demoIndex == nil ? video.subtitle : "本地演示 · 无需网络").font(.caption).foregroundStyle(GlideTheme.muted).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil:1)
                if library.browseOptions.sort == .addedNewest || library.browseOptions.sort == .addedOldest {
                    Text(video.addedAt?.formatted(date: .numeric, time: .omitted) ?? "无时间信息")
                        .font(.caption2).foregroundStyle(GlideTheme.muted)
                }
                if library.resumePosition(video) > 0 && video.duration > 0 { ProgressView(value: min(library.resumePosition(video), video.duration), total: video.duration).tint(GlideTheme.accent) }
        }
    }
    private func videoCard(_ video: Video) -> some View {
        Button { if rotationInline.active { rotationInline.toggle(video) } else { startPlayback(selected: video, useFilters: true) } } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment:.top,spacing:14) {
                        cardArtwork(video).frame(width:100)
                        cardMetadata(video).frame(maxWidth:.infinity,alignment:.leading)
                    }
                } else {
                    VStack(alignment:.leading,spacing:6) { cardArtwork(video);cardMetadata(video) }
                }
            }.foregroundStyle(GlideTheme.text).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("video." + (video.remoteID ?? video.id))
            .accessibilityValue(rotationInline.active ? (rotationInline.contains(video) ? "已选择":"未选择"):"")
            .accessibilityAddTraits(rotationInline.contains(video) ? .isSelected:[])
            .accessibilityHint(rotationInline.active ? "点按勾选或取消此视频":"点按播放")
            .contextMenu {
                if rotationInline.active { Button("预览视频",systemImage:"play") { startPlayback(selected:video,useFilters:true) } }
                if library.selectedServer?.kind == .jellyfin && !rotationInline.active {
                    Button("旋转并保存", systemImage: "rotate.right") { rotationInline.begin(video) }
                }
                Button(library.favorites.contains(video.id) ? "取消收藏" : "收藏视频", systemImage: library.favorites.contains(video.id) ? "heart.slash" : "heart") { library.toggleFavorite(video) }
                if library.canDeleteImportedVideo(video) {
                    Button("删除导入的视频", systemImage: "trash", role: .destructive) { deletingImportedVideo = video }
                }
            }
    }
}

#Preview { LibraryView(library: LibraryStore()).preferredColorScheme(.dark) }
