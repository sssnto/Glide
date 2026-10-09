import SwiftUI

struct PlaySelection: Identifiable {
    var id = UUID()
    var queue: PlaybackQueue
    var scopeName: String
    var loadFullQueue: (() async throws -> [Video])? = nil
}

enum LibrarySheet: String, Identifiable {
    case sources, help, personal, pins, downloads, settings
    var id: String { rawValue }
}

private enum HomeBrowseView: String {
    case directories, videos
}

struct LibraryView: View {
    var library: LibraryStore
    @State private var sheet: LibrarySheet?
    @State private var selection: PlaySelection?
    @State private var search = ""
    @State private var favoritesOnly = false
    @AppStorage("playbackMode") private var playbackMode: PlaybackMode = .sequential
    @AppStorage("homeBrowseView") private var homeBrowseView: HomeBrowseView = .videos
    @State private var preparing = false
    @State private var preparedCount = 0
    @State private var preparationID: UUID?
    @State private var preparationTask: Task<Void, Never>?
    @State private var queueError: String?
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
            if let server = library.selectedServer, server.kind == .jellyfin,
               let folder = library.jellyPath.first, LibraryExperience(collectionType: folder.collectionType) != .home {
                CatalogView(library: library, server: server, folder: folder)
            } else { homeBody }
        }
    }
    private var homeBody: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header.padding(.horizontal, geometry.size.width > 600 ? 40 : 24)
                    .padding(.vertical, 8)
                if library.selectedID != nil && !isLibraryRoot {
                    directoryNavigation.padding(.horizontal, geometry.size.width > 600 ? 40 : 24)
                        .padding(.vertical, 12)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if library.selectedID == nil { demoHero }
                        else if !isLibraryRoot { serverHero }
                        pinnedSection
                        if library.selectedID != nil && !isLibraryRoot {
                            Picker("浏览方式", selection: $homeBrowseView) {
                                Text("目录").tag(HomeBrowseView.directories)
                                Text("视频").tag(HomeBrowseView.videos)
                            }.pickerStyle(.segmented).accessibilityIdentifier("library.contentView")
                        }
                        if showsDirectories { folderSection }
                        if showsVideos && library.selectedID != nil {
                            HStack {
                                Image(systemName: "magnifyingglass").foregroundStyle(GlideTheme.muted)
                                TextField(library.browseOptions.includesDescendants ? "搜索当前目录及子目录" : "搜索当前层的视频", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).accessibilityIdentifier("library.search")
                                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清除搜索") }
                            }.padding(14).background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                        }
                        if let error = library.error {
                            VStack(alignment: .leading, spacing: 12) {
                                Label(error, systemImage: "wifi.exclamationmark").font(.subheadline)
                                HStack(spacing: 12) {
                                    Button("重新加载") { Task { await library.reload() } }.buttonStyle(.bordered)
                                    Button("管理媒体源") { sheet = .sources }.buttonStyle(.borderedProminent)
                                }
                            }.padding().frame(maxWidth: .infinity, alignment: .leading).background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                        }
                        if showsVideos {
                            videoHeading
                            if library.selectedID != nil { browseOptionsBar }
                            playbackToolbar
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
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: geometry.size.width > 600 ? 210 : 145), spacing: 14, alignment: .top)], spacing: 22) {
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
                            HStack(spacing: 7) {
                                Image(systemName: "hand.draw")
                                Text("上下切片 / 左右倍速 / 双指缩放后拖动")
                            }.font(.caption2).tracking(1).foregroundStyle(GlideTheme.muted).frame(maxWidth: .infinity).padding(.top, 7)
                        } else if library.loading {
                            ProgressView(isLibraryRoot ? "正在读取媒体库…" : "正在读取目录…").frame(maxWidth: .infinity).padding(30)
                        } else if library.folders.isEmpty && library.directories.isEmpty && library.error == nil {
                            if isLibraryRoot {
                                ContentUnavailableView("没有可用的媒体库", systemImage: "square.stack.3d.up", description: Text("检查服务器中的媒体库配置和当前账号的访问权限。"))
                            } else {
                                VStack(spacing: 12) {
                                    ContentUnavailableView("没有子目录", systemImage: "folder", description: Text("切换到视频，查看当前范围内的内容。"))
                                    Button("查看视频") { homeBrowseView = .videos }.buttonStyle(.bordered)
                                }
                            }
                        }
                    }.padding(.horizontal, geometry.size.width > 600 ? 40 : 24).padding(.top, 16).padding(.bottom, 96)
                        .frame(maxWidth: 1100)
                        .frame(maxWidth: .infinity)
                }
                .scrollPosition(id: $visibleID, anchor: .top)
                .onChange(of: visibleID) { _, id in
                    if let id, filtered.contains(where: { "video:" + $0.id == id }) || library.folders.contains(where: { "folder:" + $0.id == id }) || library.directories.contains(where: { "folder:" + $0.id == id }) {
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
        .task { if library.selectedID != nil && library.videos.isEmpty && library.folders.isEmpty && library.directories.isEmpty && !library.loading { await library.reload() }; restorePosition() }
        .task(id: filterTaskKey) { await searchCurrentScope() }
        .onChange(of: library.scopeKey) { _, _ in cancelPreparation(); queueError = nil }
        .onChange(of: library.locationKey) { _, _ in search = ""; favoritesOnly = false; restorePosition() }
        .onChange(of: library.browseOptions) { _, _ in visibleID = nil }
        .onChange(of: search) { _, _ in visibleID = nil }
        .onChange(of: favoritesOnly) { _, _ in visibleID = nil }
        .onDisappear { cancelPreparation() }
        .overlay { preparationOverlay }
        .alert("无法准备播放队列", isPresented: Binding(get: { queueError != nil }, set: { if !$0 { queueError = nil } })) { Button("知道了") { queueError = nil } } message: { Text(queueError ?? "") }
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
    private var isLibraryRoot: Bool { library.selectedServer?.kind == .jellyfin && library.jellyPath.isEmpty }
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
    private var directoryNavigation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if library.hasParent {
                    Button { Task { await library.back() } } label: { Label("上一级", systemImage: "arrow.turn.up.left").font(.subheadline) }.accessibilityIdentifier("directory.back")
                } else {
                    Label("选择媒体库", systemImage: "square.stack.3d.up").font(.subheadline).foregroundStyle(GlideTheme.muted)
                }
                Spacer()
                Button { Task { await library.reload() } } label: {
                    Label(library.selectedServer?.kind == .jellyfin && library.jellyPath.isEmpty ? "刷新媒体库" : "刷新本目录", systemImage: "arrow.clockwise").font(.subheadline)
                }.disabled(library.loading).accessibilityIdentifier("directory.refresh")
            }
            if library.selectedServer?.kind == .jellyfin && !library.jellyPath.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        Button("媒体库") { Task { await library.jump(to: 0) } }
                        ForEach(Array(library.jellyPath.enumerated()), id: \.element.id) { depth, folder in
                            Image(systemName: "chevron.right").font(.system(size: 8))
                            Button(folder.name) { Task { await library.jump(to: depth + 1) } }.lineLimit(1)
                        }
                    }.font(.caption).foregroundStyle(GlideTheme.muted)
                }
            } else if !library.path.isEmpty {
                Text(library.path.map(\.lastPathComponent).joined(separator: " / ")).font(.caption).foregroundStyle(GlideTheme.muted).lineLimit(2)
            }
        }
    }
    private var header: some View {
        HStack {
            Text("glide").font(.system(size: 28, weight: .semibold, design: .rounded)).tracking(-1.4)
            Spacer()
            Button { sheet = .pins } label: { Image(systemName: "pin").frame(width: 44, height: 44) }
                .accessibilityLabel("固定目录").accessibilityIdentifier("pins.open")
            Button { sheet = .sources } label: {
                Label(library.selectedServer?.name ?? "连接片库", systemImage: library.selectedServer?.kind.symbol ?? "plus")
                    .font(.caption.weight(.medium)).lineLimit(1).padding(.horizontal, 14).frame(minHeight: 44)
                    .frame(maxWidth: 180)
                    .background(GlideTheme.panel, in: Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("sources.open")
        }
    }
    @ViewBuilder private var folderSection: some View {
        if let server = library.selectedServer, isLibraryRoot || !library.folders.isEmpty || !library.directories.isEmpty {
            let orderedFolders = library.folderSort.sorted(library.folders)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(isLibraryRoot ? "媒体库" : "目录").font(.title3.weight(.semibold))
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 260), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(orderedFolders) { folder in
                        LibraryFolderTile(title: folder.name, server: server, folder: folder, isLibrary: isLibraryRoot) {
                            Task { await library.enter(folder) }
                        }
                            .accessibilityIdentifier("folder." + folder.id).id("folder:" + folder.id)
                            .task { if folder.id == orderedFolders.last?.id && library.hasMoreFolders { await library.moreFolders() } }
                    }
                    ForEach(library.folderSort.sorted(library.directories)) { entry in
                        LibraryFolderTile(title: entry.name, server: server, directory: entry) {
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
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(favoritesOnly ? "本目录收藏" : term.isEmpty ? "全部视频" : "搜索结果").font(.title3.weight(.semibold))
                Text(usesFilters ? "\(library.browseOptions.scopeTitle) · \(filtered.count) 个匹配结果" : library.selectedID == nil ? "3 段离线动态风景" : "\(library.browseOptions.scopeTitle) · 共 \(library.total) 个视频")
                    .font(.caption).foregroundStyle(GlideTheme.muted)
            }.accessibilityIdentifier("videos.heading")
            Spacer()
            Button { favoritesOnly.toggle() } label: {
                Image(systemName: favoritesOnly ? "heart.fill" : "heart").frame(width: 44, height: 44)
                    .foregroundStyle(favoritesOnly ? GlideTheme.accent : GlideTheme.muted)
            }.accessibilityLabel(favoritesOnly ? "显示全部视频" : "只看收藏")
        }
    }
    private var playbackToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { modePicker.frame(minWidth: 185); playDirectoryButton }
            VStack(alignment: .leading, spacing: 12) { modePicker; playDirectoryButton }
        }
    }
    private var playDirectoryButton: some View {
        Button { startPlayback(useFilters: usesFilters) } label: {
            Label(usesFilters ? "播放结果" : library.selectedID == nil ? "体验刷片" : "刷本目录", systemImage: "play.fill")
                .font(.subheadline.weight(.semibold)).fixedSize().padding(.horizontal, 18).frame(minHeight: 44)
                .background(GlideTheme.accent, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.black)
        }.disabled(library.loading || filtering || (usesFilters && filtered.isEmpty)).accessibilityIdentifier(library.selectedID == nil ? "demo.play" : "directory.play")
    }
    private var demoHero: some View {
        ZStack(alignment: .bottomLeading) {
            LandscapeArt().overlay { LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom) }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Circle().fill(GlideTheme.accent).frame(width: 5, height: 5)
                    Text("YOUR MEDIA, IN MOTION").font(.system(size: 9, weight: .semibold)).tracking(2.2)
                }.foregroundStyle(GlideTheme.accent)
                Text("你的片库，随手一刷。").font(.system(size: 27, weight: .semibold)).lineSpacing(4)
                Text("从私人收藏，到下一段心动。")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.68))
            }.padding(24)
            Text("离线演示").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.7)).padding(9).background(.black.opacity(0.16), in: Capsule()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(16)
        }.frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 28))
    }
    private var serverHero: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isLibraryRoot ? "你的片库" : library.currentDirectoryName).font(.largeTitle.weight(.semibold))
                Text(isLibraryRoot ? "选择一个片库，开始随心观看。" : "\(library.folders.count + library.directories.count) 个目录 · \(library.videos.count) 个视频")
                    .font(.subheadline).foregroundStyle(GlideTheme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if library.canPinDirectory {
                Button { library.toggleDirectoryPin() } label: {
                    Image(systemName: library.isDirectoryPinned ? "pin.fill" : "pin")
                        .foregroundStyle(GlideTheme.accent).frame(width: 44, height: 44)
                        .background(GlideTheme.panel, in: Circle())
                }.accessibilityLabel(library.isDirectoryPinned ? "取消固定此目录" : "固定此目录").accessibilityIdentifier("directory.pin")
            }
        }
    }
    private var browseOptionsBar: some View {
        HStack {
            Menu {
                ForEach([true, false], id: \.self) { recursive in
                    Button {
                        var options = library.browseOptions; options.includesDescendants = recursive
                        Task { await library.setBrowseOptions(options) }
                    } label: {
                        Label((recursive ? "包含子目录" : "仅当前层"), systemImage: library.browseOptions.includesDescendants == recursive ? "checkmark" : "folder")
                    }
                }
            } label: { Label(library.browseOptions.scopeTitle, systemImage: "square.stack.3d.up").font(.caption).frame(minHeight: 44) }
                .accessibilityIdentifier("library.scope")
            Spacer()
            Menu {
                ForEach(VideoSort.allCases) { sort in
                    Button {
                        var options = library.browseOptions; options.sort = sort
                        Task { await library.setBrowseOptions(options) }
                    } label: { Label(sort.title, systemImage: library.browseOptions.sort == sort ? "checkmark" : sort.symbol) }
                }
            } label: { Label(library.browseOptions.sort.title, systemImage: "arrow.up.arrow.down").font(.caption).frame(minHeight: 44) }
                .accessibilityIdentifier("library.sort")
        }.foregroundStyle(GlideTheme.muted)
    }
    @ViewBuilder private var pinnedSection: some View {
        let eligible = library.bookmarks.filter { $0.sourceID == library.selectedID && LibraryExperience(collectionType: $0.jellyPath.first?.collectionType) == .home }
        if (isLibraryRoot || library.selectedServer?.kind == .webDAV && library.path.isEmpty) && !eligible.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("常用刷看").font(.headline)
                    Spacer()
                    Button("管理") { sheet = .pins }.font(.caption).frame(minHeight: 44)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
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
    private func videoCard(_ video: Video) -> some View {
        Button { startPlayback(selected: video, useFilters: true) } label: {
            VStack(alignment: .leading, spacing: 10) {
                VideoPreviewArtwork(video: video, server: library.servers.first { $0.id == video.sourceID })
                    .overlay(alignment: .bottomTrailing) { Text(video.duration.mediaTime).font(.system(size: 9, weight: .semibold, design: .monospaced)).padding(6).background(.black.opacity(0.4), in: Capsule()).padding(9) }
                    .overlay(alignment: .topLeading) { if library.favorites.contains(video.id) { Image(systemName: "heart.fill").font(.caption).foregroundStyle(GlideTheme.accent).padding(10) } }
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                Text(video.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(video.demoIndex == nil ? video.subtitle : "GLIDE ORIGINAL · 演示").font(.caption).foregroundStyle(GlideTheme.muted).lineLimit(1)
                if library.browseOptions.sort == .addedNewest || library.browseOptions.sort == .addedOldest {
                    Text(video.addedAt?.formatted(date: .numeric, time: .omitted) ?? "无时间信息")
                        .font(.caption2).foregroundStyle(GlideTheme.muted)
                }
                if library.resumePosition(video) > 0 && video.duration > 0 { ProgressView(value: min(library.resumePosition(video), video.duration), total: video.duration).tint(GlideTheme.accent) }
            }.foregroundStyle(GlideTheme.text)
        }.buttonStyle(.plain).accessibilityIdentifier("video." + (video.remoteID ?? video.id))
            .contextMenu {
                Button(library.favorites.contains(video.id) ? "取消收藏" : "收藏视频", systemImage: library.favorites.contains(video.id) ? "heart.slash" : "heart") { library.toggleFavorite(video) }
            }
    }
}

#Preview { LibraryView(library: LibraryStore()).preferredColorScheme(.dark) }
