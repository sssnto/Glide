import SwiftUI

/// Films and television use deliberate selection, separate from the home-video feed.
struct CatalogView: View {
    var library: LibraryStore
    var server: MediaServer
    var folder: MediaFolder
    @State private var items: [CatalogItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var order = CatalogOrder()
    @State private var nextIndex = 0
    @State private var total = 0
    @State private var generation = UUID()
    @State private var restored = false
    @State private var loadedRequestKey: String?
    @State private var visiblePosterID: String?
    @State private var retainedPosterID: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var shows: Bool { LibraryExperience(collectionType: folder.collectionType) == .shows }
    private var preferencesKey: String { "catalogOrder." + server.id.uuidString + folder.id }
    private var requestKey: String { folder.id + order.key + query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Text("\(total) 部" + (shows ? "节目" : "电影"))
                            .font(.subheadline.weight(.medium)).foregroundStyle(GlideTheme.muted)
                        Spacer(minLength: 8)
                        Menu {
                            ForEach(CatalogSort.allCases) { sort in
                                Button { order.sort = sort; saveOrder() } label: { Label(sort.title, systemImage: order.sort == sort ? "checkmark" : "line.3.horizontal.decrease") }
                            }
                            Divider()
                            Button(order.descending ? "改为升序" : "改为降序") { order.descending.toggle(); saveOrder() }
                        } label: {
                            Label(order.sort.title, systemImage: "arrow.up.arrow.down")
                                .font(.caption.weight(.medium)).frame(minHeight: 44)
                        }
                        .accessibilityLabel("排序：" + order.sort.title + (order.descending ? "，降序" : "，升序"))
                        .accessibilityIdentifier("catalog.sort")
                    }
                    if !loading && error == nil && items.isEmpty { ContentUnavailableView("没有匹配的作品", systemImage: "film") }
                    LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: horizontalSizeClass == .compact ? 104 : 140), spacing: 12)], alignment: .leading, spacing: 18) {
                        ForEach(items) { item in
                            NavigationLink { CatalogDetailView(library: library, server: server, initial: item) } label: {
                                CatalogPosterCard(item: item, server: server)
                            }.buttonStyle(.plain).accessibilityIdentifier("catalog." + item.id).id(item.id)
                        }
                    }.scrollTargetLayout()
                    // Keep the task owner mounted while loading; replacing it cancels its request.
                    VStack(spacing: 8) {
                        if loading { ProgressView("正在读取片库…") }
                        else if let error {
                            Text(error)
                            Button("重新加载") { Task { await load(reset: items.isEmpty || loadedRequestKey != requestKey, refresh: true) } }
                        } else if nextIndex < total {
                            Button("加载更多") { Task { await load(reset: false) } }.accessibilityIdentifier("catalog.more")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .task(id: nextIndex) {
                        if nextIndex > 0 && nextIndex < total && error == nil { await load(reset: false) }
                    }

                }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24).frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }.scrollPosition(id: $visiblePosterID)
                .onChange(of: visiblePosterID) { _, id in if let id { retainedPosterID = id } }
                .onAppear {
                    if visiblePosterID == nil, let retainedPosterID, items.contains(where: { $0.id == retainedPosterID }) {
                        visiblePosterID = retainedPosterID
                    }
                }
                .background(GlideTheme.background).navigationTitle(folder.name).navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: shows ? "搜索节目" : "搜索电影")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { UnifiedLibraryView(library: library) } label: { Label("搜索全部片库", systemImage: "magnifyingglass") }
                    }
                    ToolbarItem(placement: .topBarLeading) { Button { Task { await library.jump(to: 0) } } label: { Label("媒体库", systemImage: "chevron.left") }.accessibilityIdentifier("catalog.back") }
                }
                .refreshable { await load(reset: true, refresh: true) }
                .task(id: requestKey) {
                    if !restored {
                        restored = true
                        if let data = UserDefaults.standard.data(forKey: preferencesKey), let saved = try? JSONDecoder().decode(CatalogOrder.self, from: data), saved != order { order = saved; return }
                    }
                    // Navigation back can restart a view task. Keep the loaded grid and its scroll target.
                    if loadedRequestKey == requestKey { return }
                    do { if !query.isEmpty { try await Task.sleep(for: .milliseconds(300)) }; try Task.checkCancellation(); await load(reset: true) } catch { }
                }
        }.tint(GlideTheme.accent)
    }
    private func saveOrder() { if let data = try? JSONEncoder().encode(order) { UserDefaults.standard.set(data, forKey: preferencesKey) } }
    private func load(reset: Bool, refresh: Bool = false) async {
        guard reset || !loading else { return }
        let key = requestKey
        let id = UUID(); generation = id; loading = true; error = nil
        let retainedCursor = refresh && loadedRequestKey == key ? min(nextIndex, 1200) : 0
        let retainedAnchor = visiblePosterID ?? retainedPosterID
        let start = reset ? 0 : nextIndex
        defer { if generation == id { loading = false } }
        do {
            var page = try await MediaClient.shared.catalogPage(server: server, parentID: folder.id, type: shows ? "Series" : "Movie", start: start, order: order, search: query.trimmingCharacters(in: .whitespacesAndNewlines), refresh: refresh)
            var cursor = start + page.Items.count
            while reset && cursor < retainedCursor && cursor < page.TotalRecordCount {
                try Task.checkCancellation()
                let extra = try await MediaClient.shared.catalogPage(server: server, parentID: folder.id, type: shows ? "Series" : "Movie", start: cursor, order: order, search: query.trimmingCharacters(in: .whitespacesAndNewlines), refresh: refresh)
                guard !extra.Items.isEmpty else { throw MediaError.message("分页没有进展，请刷新重试。") }
                page.Items += extra.Items; cursor += extra.Items.count; page.TotalRecordCount = extra.TotalRecordCount
            }
            try Task.checkCancellation(); guard id == generation && key == requestKey else { return }
            var known = Set(reset ? [] : items.map(\.id)); let added = page.Items.filter { known.insert($0.id).inserted }
            guard start + page.Items.count >= page.TotalRecordCount || !added.isEmpty else { throw MediaError.message("分页没有进展，请刷新重试。") }
            if reset {
                items = added; loadedRequestKey = key
                let anchor = refresh && items.contains(where: { $0.id == retainedAnchor }) ? retainedAnchor : nil
                visiblePosterID = anchor; retainedPosterID = anchor
            }
            else { items += added }
            nextIndex = start + page.Items.count; total = page.TotalRecordCount
        } catch { if !Task.isCancelled && id == generation { self.error = error.localizedDescription } }
    }
}

struct CatalogPosterCard: View {
    var item: CatalogItem
    var server: MediaServer
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var titleHeight = 36
    private var cardFacts: String {
        [item.ProductionYear.map(String.init), item.RunTimeTicks.flatMap { $0 > 0 ? ($0 < 600_000_000 ? "\($0 / 10_000_000) 秒" : "\($0 / 600_000_000) 分钟") : nil }]
            .compactMap { $0 }.joined(separator: " · ")
    }
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 12) { artwork.frame(width: 94, height: 141); metadata }
            } else {
                VStack(alignment: .leading, spacing: 6) { artwork.aspectRatio(2.0 / 3.0, contentMode: .fit); metadata }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
    private var artwork: some View {
        CatalogArtwork(item: item, server: server, pixels: 420)
            .overlay(alignment: .topTrailing) {
                if item.UserData?.Played == true {
                    Image(systemName: "checkmark.circle.fill").font(.caption)
                        .foregroundStyle(GlideTheme.accent).padding(6).background(.black.opacity(0.72), in: Circle()).padding(6)
                        .accessibilityLabel("已看")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let rating = item.CommunityRating {
                    Text("★ " + rating.formatted(.number.precision(.fractionLength(1))))
                        .font(.caption2.weight(.semibold)).monospacedDigit().padding(.horizontal, 6).padding(.vertical, 4)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 5)).padding(6)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
    }
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.Name).font(.subheadline.weight(.medium)).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .frame(minHeight: titleHeight, alignment: .topLeading)
            if !cardFacts.isEmpty {
                Text(cardFacts).font(.caption2).foregroundStyle(GlideTheme.muted).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            if let video = item.MediaSources?.first?.MediaStreams?.first(where: { $0.Type == "Video" }) {
                Text(CatalogMediaPresentation.videoSummary(video)).font(.caption2).foregroundStyle(GlideTheme.muted)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CatalogDetailView: View {
    var library: LibraryStore
    var server: MediaServer
    var initial: CatalogItem
    @State private var detail: CatalogItem?
    @State private var seasons: [CatalogItem] = []
    @State private var episodes: [CatalogItem] = []
    @State private var seasonID = ""
    @State private var sourceID = ""
    @State private var audioIndex = -2
    @State private var subtitleIndex = -2
    @State private var starting = false
    @State private var error: String?
    @State private var episodeError: String?
    @State private var loading = true
    @State private var loadingEpisodes = false
    @State private var playing: PlaySelection?
    @State private var trackSheet: TrackKind?
    @State private var downloadMessage: String?
    @State private var confirmingDownload = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var overviewExpanded = false
    var episodeQueue: [CatalogItem] = []
    private var item: CatalogItem { detail ?? initial }
    private var isSeries: Bool { item.Type == "Series" }
    private var source: CatalogItem.Source? { item.MediaSources?.first { $0.Id == sourceID } ?? item.MediaSources?.first }
    private var tracks: TrackSelection {
        TrackSelection(mediaSourceID: source?.Id, audioIndex: audioIndex == -2 ? nil : audioIndex, subtitleIndex: subtitleIndex == -2 ? nil : subtitleIndex)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                detailHero
                if loading { ProgressView("读取媒体信息…").font(.subheadline) }
                if let error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.subheadline).foregroundStyle(.orange)
                        Button("重试") { Task { await load() } }.frame(minHeight: 44)
                    }
                }
                if isSeries {
                    seasonSection
                } else {
                    detailActions
                    playbackOptions
                    if let source { CatalogTechnicalSection(source: source) }
                }
                overviewSection
                if !CatalogFacet.facets(item).isEmpty { facetSection }
                if let people = item.People, !people.isEmpty {
                    CastSection(library: library, server: server, people: people)
                }
                SimilarMediaSection(library: library, server: server, item: item)
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 24)
                .frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.background(GlideTheme.background).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) { playbackBar }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { DownloadsView(library: library) } label: { Image(systemName: "arrow.down.circle").frame(width: 44, height: 44) }
                        .accessibilityLabel("离线下载")
                }
            }
            .task(id: initial.id) { await load() }
            .refreshable { await load(refresh: true) }
            .confirmationDialog("下载原文件？", isPresented: $confirmingDownload, titleVisibility: .visible) {
                Button("加入下载队列") { Task {
                    do { try await DownloadStore.shared.enqueue(item: item, server: server, sourceID: source?.Id); downloadMessage = "已加入下载队列，可在离线中查看进度。" }
                    catch { downloadMessage = error.localizedDescription }
                } }.accessibilityIdentifier("detail.confirmDownload")
                Button("取消", role: .cancel) { }
            } message: {
                Text(downloadDescription)
            }
            .sheet(item: $trackSheet) { kind in
                TrackChoicesView(title: kind == .audio ? "选择声音" : "选择字幕", streams: source?.MediaStreams?.filter { $0.Type == (kind == .audio ? "Audio" : "Subtitle") } ?? [], selection: kind == .audio ? $audioIndex : $subtitleIndex, allowsOff: kind == .subtitle)
            }
            .task(id: seasonID) { await loadEpisodes() }
            .fullScreenCover(item: $playing) { selection in
                PlayerView(library: library, queue: selection.queue, scopeName: item.SeriesName ?? item.Name,
                           cinematic: true, initialTracks: isSeries ? TrackSelection() : tracks, initialResumeAt: selection.initialResumeAt, loadFullQueue: selection.loadFullQueue)
            }
    }
    private var detailHero: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) { heroArtwork; heroMetadata }
            } else {
                HStack(alignment: .top, spacing: 16) { heroArtwork; heroMetadata }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var heroArtwork: some View {
        CatalogArtwork(item: item, server: server, pixels: 480)
            .frame(width: item.Type == "Episode" ? 124 : horizontalSizeClass == .compact ? 94 : 132,
                   height: item.Type == "Episode" ? 78 : horizontalSizeClass == .compact ? 141 : 198)
            .clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
    }
    private var heroMetadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.Type == "Episode" ? (item.SeriesName ?? "节目") + " · " + item.episodeLabel : isSeries ? "节目" : "电影")
                .font(.caption.weight(.medium)).foregroundStyle(GlideTheme.muted)
            Text(item.Name).font(GlideTheme.Typography.pageTitle).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            CatalogFactStrip(item: item)
            if let genres = item.Genres, !genres.isEmpty {
                Text(genres.prefix(3).joined(separator: " / ")).font(.caption).foregroundStyle(GlideTheme.muted).lineLimit(2)
            }
            if let source {
                let summary = CatalogMediaPresentation.sourceSummary(source)
                if !summary.isEmpty {
                    Text(summary).font(.caption.weight(.medium)).foregroundStyle(GlideTheme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var playbackBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(GlideTheme.separator)
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
            layout {
                if isSeries {
                    Button { startSeries() } label: { primaryPlayLabel(seriesPlayTitle) }
                        .disabled(seriesTarget == nil).accessibilityIdentifier("detail.seriesPlay")
                } else {
                    Button { start() } label: {
                        primaryPlayLabel(WatchProgress.canResume(position: library.resumePosition(item.video(server: server)), duration: item.video(server: server).duration) ? "继续观看" : "开始播放")
                    }.disabled(loading || detail == nil || starting).accessibilityIdentifier("detail.play")
                    Button("从头播放") { start(resumeAt: 0) }
                        .font(.subheadline.weight(.medium)).frame(minWidth: 78, minHeight: 48)
                        .disabled(loading || detail == nil || starting)
                }
            }.padding(.horizontal, 16).padding(.vertical, 10).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.background(GlideTheme.background)
    }
    private func primaryPlayLabel(_ title: String) -> some View {
        Label(title, systemImage: "play.fill").font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48).padding(.horizontal, 12)
            .foregroundStyle(GlideTheme.onAccent).background(GlideTheme.accent, in: RoundedRectangle(cornerRadius: 12))
    }
    private var detailActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { library.toggleFavorite(item.video(server: server)) } label: {
                    Label(library.favorites.contains(item.video(server: server).id) ? "已收藏" : "收藏", systemImage: library.favorites.contains(item.video(server: server).id) ? "heart.fill" : "heart")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.accessibilityIdentifier("detail.favorite")
                Button { confirmingDownload = true } label: {
                    Label("下载原文件", systemImage: "arrow.down.circle").frame(maxWidth: .infinity, minHeight: 44)
                }.accessibilityIdentifier("detail.download")
                Menu {
                    Button(item.UserData?.Played == true ? "标为未看" : "标为已看") { Task { await toggleWatched() } }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }.accessibilityLabel("更多作品操作").accessibilityIdentifier("detail.more")
            }.font(.caption.weight(.medium)).buttonStyle(.plain)
                .background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            if starting { ProgressView("准备播放队列…").font(.caption) }
            if let downloadMessage { Text(downloadMessage).font(.caption).foregroundStyle(GlideTheme.muted) }
        }
    }
    private var playbackOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let sources = item.MediaSources, sources.count > 1 {
                Picker("播放版本", selection: $sourceID) {
                    ForEach(sources) { Text($0.Name ?? $0.Container?.uppercased() ?? "版本").tag($0.Id) }
                }.pickerStyle(.menu).font(.subheadline).frame(minHeight: 44)
                    .onChange(of: sourceID) { _, _ in audioIndex = -2; subtitleIndex = -2 }
                Divider().overlay(GlideTheme.separator)
            }
            Button { trackSheet = .audio } label: {
                PlaybackOptionRow(title: "音轨", value: selectedTrackSummary(type: "Audio", index: audioIndex))
            }.accessibilityIdentifier("detail.audio")
            Divider().overlay(GlideTheme.separator)
            Button { trackSheet = .subtitle } label: {
                PlaybackOptionRow(title: "字幕", value: selectedTrackSummary(type: "Subtitle", index: subtitleIndex))
            }.accessibilityIdentifier("detail.subtitle")
        }.padding(.horizontal, 14).buttonStyle(.plain)
            .background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 12))
    }
    private func selectedTrackSummary(type: String, index: Int) -> String {
        if type == "Subtitle", index == -1 { return "关闭" }
        let streams = source?.MediaStreams?.filter { $0.Type == type } ?? []
        if let stream = streams.first(where: { $0.Index == index }) { return TrackDisplay.summary(stream) }
        if let stream = streams.first(where: { $0.IsDefault == true }) { return "自动 · " + TrackDisplay.summary(stream) }
        return streams.isEmpty ? "服务器默认" : "自动 · \(streams.count) 条可选"
    }
    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("简介").font(GlideTheme.Typography.sectionTitle).accessibilityAddTraits(.isHeader)
            let overview = item.Overview?.isEmpty == false ? item.Overview! : "此媒体暂未提供简介。"
            Text(overview).font(.subheadline).foregroundStyle(GlideTheme.muted)
                .lineSpacing(4).lineLimit(overviewExpanded ? nil : 4).textSelection(.enabled)
            if overview.count > 100 {
                Button(overviewExpanded ? "收起简介" : "展开简介") { overviewExpanded.toggle() }
                    .font(.caption.weight(.medium)).frame(minHeight: 44)
            }
        }
    }
    private var facetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("类型与标签").font(GlideTheme.Typography.sectionTitle).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(CatalogFacet.facets(item)) { facet in
                    NavigationLink { FacetMediaView(library: library, server: server, facet: facet) } label: {
                        Text((facet.kind == .tag ? "# " : "") + facet.name).font(.caption).lineLimit(2)
                            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44)
                            .background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityIdentifier("facet." + facet.id)
                }
            }
        }
    }
    @ViewBuilder private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("剧集").font(GlideTheme.Typography.sectionTitle).accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("选择季", selection: $seasonID) { ForEach(seasons) { Text($0.IndexNumber == 0 ? "特别篇" : $0.Name).tag($0.id) } }
                    .pickerStyle(.menu).font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("detail.season")
            }
            if seasons.isEmpty && !loading && error == nil { Text("此节目暂无可用的季。").font(.subheadline).foregroundStyle(GlideTheme.muted) }
            if loadingEpisodes { ProgressView("正在读取剧集…").font(.subheadline) }
            if let episodeError {
                Text(episodeError).font(.subheadline)
                Button("重试剧集") { Task { await loadEpisodes() } }.frame(minHeight: 44)
            }
            if !loadingEpisodes && episodeError == nil && !seasonID.isEmpty && episodes.isEmpty { Text("本季暂无可用剧集。").font(.subheadline).foregroundStyle(GlideTheme.muted) }
        }
        ForEach(episodes) { episode in
            NavigationLink {
                CatalogDetailView(library: library, server: server, initial: episode, episodeQueue: episodes)
            } label: { CatalogEpisodeRow(item: episode, server: server) }
                .buttonStyle(.plain).accessibilityIdentifier("episode." + episode.id)
        }
    }
    private func toggleWatched() async {
        do {
            let watched = item.UserData?.Played != true
            let video = item.video(server: server)
            try await MediaClient.shared.setWatched(watched, video: video, server: server)
            library.positions[video.id] = watched ? (video.duration > 0 ? video.duration : nil) : 0
            library.progressSnapshots[video.id] = nil; library.persistProgress()
            UserDefaults.standard.set(library.positions, forKey: "positions")
            await load(refresh: true)
        } catch { self.error = error.localizedDescription }
    }
    private func load(refresh: Bool = false) async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let loaded = try await MediaClient.shared.catalogDetail(server: server, id: initial.id, refresh: refresh)
            try Task.checkCancellation()
            detail = loaded; sourceID = loaded.MediaSources?.first?.Id ?? ""
            library.remember([loaded.video(server: server)])
            if loaded.Type == "Series" {
                seasons = try await MediaClient.shared.catalogItems(server: server, parentID: loaded.id, type: "Season", refresh: refresh)
                let savedSeason = library.continueWatching.first { $0.video.sourceID == server.id && $0.video.seriesID == loaded.id }?.video.seasonNumber
                seasonID = seasons.first(where: { $0.IndexNumber == savedSeason })?.id ?? seasons.first(where: { $0.IndexNumber != 0 })?.id ?? seasons.first?.id ?? ""
            }
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func loadEpisodes() async {
        let selected = seasonID
        guard !selected.isEmpty else { return }
        loadingEpisodes = true; episodeError = nil; episodes = []
        defer { if selected == seasonID { loadingEpisodes = false } }
        do {
            let loaded = try await MediaClient.shared.catalogItems(server: server, parentID: selected, type: "Episode")
            try Task.checkCancellation()
            if selected == seasonID { episodes = loaded }
        } catch { if !Task.isCancelled && selected == seasonID { episodeError = error.localizedDescription } }
    }
    private var downloadDescription: String {
        let size = source?.Size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "大小由服务器提供"
        return "\(source?.Container?.uppercased() ?? "原文件") · \(size)。占用本机空间，按队列下载。离线播放仍需设备支持原文件编码。"
    }
    private var seriesEntry: ContinueWatchingItem? {
        library.continueWatching.first { $0.video.sourceID == server.id && $0.video.seriesID == item.id }
    }
    private var seriesTarget: Video? {
        if let entry = seriesEntry { return entry.video }
        return episodes.first?.video(server: server)
    }
    private var seriesPlayTitle: String {
        if let entry = seriesEntry {
            if entry.finished { return "从头观看" }
            let prefix = WatchProgress.canResume(position: library.resumePosition(entry.video), duration: entry.video.duration) ? "继续" : "播放"
            return prefix + " " + entry.episodeLabel
        }
        return episodes.first.map { "播放 " + $0.episodeLabel } ?? "正在读取剧集…"
    }
    private func completeSeries(_ id: String) -> () async throws -> [Video] {
        let server = server
        return { try await MediaClient.shared.catalogItems(server: server, parentID: id, type: "Episode").map { $0.video(server: server) } }
    }
    private func startSeries() {
        guard let target = seriesTarget else { return }
        library.remember([target])
        playing = PlaySelection(queue: PlaybackQueue(videos: [target], mode: .sequential), scopeName: item.Name,
                                initialResumeAt: seriesEntry?.finished == true ? 0 : nil, loadFullQueue: completeSeries(item.id))
    }
    private func start(resumeAt: Double? = nil) {
        guard !starting else { return }
        error = nil
        // A selected episode is immediately playable; retrieve the rest after its first frame.
        let entries = episodeQueue.isEmpty ? [item] : CatalogItem.episodeOrder(episodeQueue)
        let videos = entries.map { ($0.id == item.id ? item : $0).video(server: server) }
            .filter { item.Type != "Episode" || item.ParentIndexNumber == 0 || $0.seasonNumber != 0 }
        library.remember(videos)
        playing = PlaySelection(queue: PlaybackQueue(videos: videos, mode: .sequential, startID: item.video(server: server).id), scopeName: item.Name,
                                initialResumeAt: resumeAt, loadFullQueue: item.SeriesId.map(completeSeries))
    }
}


private struct CatalogFactStrip: View {
    var item: CatalogItem
    private var facts: [String] {
        [item.ProductionYear.map(String.init), item.OfficialRating,
         item.CommunityRating.map { "★ " + $0.formatted(.number.precision(.fractionLength(1))) },
         item.RunTimeTicks.flatMap { $0 > 0 ? ($0 < 600_000_000 ? "\($0 / 10_000_000) 秒" : "\($0 / 600_000_000) 分钟") : nil }]
            .compactMap { $0 }.filter { !$0.isEmpty }
    }
    var body: some View {
        Text(facts.joined(separator: " · ")).font(.caption).monospacedDigit()
            .foregroundStyle(GlideTheme.muted).fixedSize(horizontal: false, vertical: true)
    }
}

enum CatalogMediaPresentation {
    static func resolution(_ stream: CatalogItem.Stream) -> String? {
        guard let width = stream.Width, let height = stream.Height, width > 0, height > 0 else { return nil }
        let longEdge = max(width, height), shortEdge = min(width, height)
        if longEdge >= 7680 || shortEdge >= 4320 { return "8K" }
        if longEdge >= 3840 || shortEdge >= 2160 { return "4K" }
        if longEdge >= 2560 || shortEdge >= 1440 { return "1440p" }
        if longEdge >= 1920 || shortEdge >= 1080 { return "1080p" }
        if longEdge >= 1280 || shortEdge >= 720 { return "720p" }
        return "\(width) × \(height)"
    }
    static func range(_ stream: CatalogItem.Stream) -> String? {
        if let range = stream.VideoRangeType, !range.isEmpty, range.lowercased() != "unknown" { return range }
        if let profile = stream.DvProfile, profile > 0 { return "Dolby Vision" }
        return nil
    }
    static func videoSummary(_ stream: CatalogItem.Stream) -> String {
        [resolution(stream), TrackDisplay.codec(stream.Codec), range(stream)]
            .compactMap { $0 }.joined(separator: " · ")
    }
    static func sourceSummary(_ source: CatalogItem.Source) -> String {
        let video = source.MediaStreams?.first { $0.Type == "Video" }
        return [video.map { videoSummary($0) }, source.Container?.uppercased(),
                source.Size.flatMap { $0 > 0 ? ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) : nil }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    fileprivate static func fields(_ source: CatalogItem.Source) -> [CatalogTechnicalField] {
        var fields: [CatalogTechnicalField] = []
        if let video = source.MediaStreams?.first(where: { $0.Type == "Video" }) {
            if let width = video.Width, let height = video.Height, width > 0, height > 0 { fields.append(.init(label: "分辨率", value: "\(width) × \(height)")) }
            if let codec = TrackDisplay.codec(video.Codec) { fields.append(.init(label: "视频编码", value: codec + (video.BitDepth.map { " · \($0) bit" } ?? ""))) }
            if let frameRate = video.AverageFrameRate ?? video.RealFrameRate, frameRate > 0 {
                fields.append(.init(label: "帧率", value: frameRate.formatted(.number.precision(.fractionLength(0...3))) + " fps"))
            }
            if let bitRate = video.BitRate, bitRate > 0 { fields.append(.init(label: "视频码率", value: MediaInfoFormatting.bitrate(Double(bitRate)))) }
            if let range = range(video) { fields.append(.init(label: "动态范围", value: range)) }
        }
        if let container = source.Container, !container.isEmpty { fields.append(.init(label: "容器", value: container.uppercased())) }
        if let size = source.Size, size > 0 { fields.append(.init(label: "文件大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
        return fields
    }
}

private struct CatalogTechnicalField: Identifiable {
    var label: String
    var value: String
    var id: String { label }
}

private struct CatalogTechnicalSection: View {
    var source: CatalogItem.Source
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        let fields = CatalogMediaPresentation.fields(source)
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("媒体信息").font(GlideTheme.Typography.sectionTitle).accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 130), alignment: .leading)], alignment: .leading, spacing: 14) {
                    ForEach(fields) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.label).font(.caption2).foregroundStyle(GlideTheme.muted)
                            Text(field.value).font(.caption.weight(.medium)).foregroundStyle(GlideTheme.text)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }.accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private struct CatalogEpisodeRow: View {
    var item: CatalogItem
    var server: MediaServer
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if !dynamicTypeSize.isAccessibilitySize {
                CatalogArtwork(item: item, server: server, pixels: 360).frame(width: 100, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.episodeLabel).font(.caption2.weight(.medium)).foregroundStyle(GlideTheme.accent)
                    if let ticks = item.RunTimeTicks, ticks > 0 { Text("\(ticks / 600_000_000) 分钟").font(.caption2).foregroundStyle(GlideTheme.muted) }
                }
                Text(item.Name).font(.subheadline.weight(.medium)).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if let overview = item.Overview, !overview.isEmpty { Text(overview).font(.caption).foregroundStyle(GlideTheme.muted).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: item.UserData?.Played == true ? "checkmark.circle.fill" : "chevron.right")
                .font(.caption2).foregroundStyle(GlideTheme.muted).accessibilityHidden(true)
        }.padding(.vertical, 4).frame(minHeight: 70).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}


struct CatalogArtwork: View {
    var item: CatalogItem
    var server: MediaServer
    var contentMode: ContentMode = .fill
    var pixels = 540
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            GlideTheme.panel
            if let image { GeometryReader { proxy in
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).frame(width: proxy.size.width, height: proxy.size.height).clipped()
            }.allowsHitTesting(false) }
            else { Image(systemName: item.Type == "Person" ? "person.crop.rectangle" : item.Type == "Series" ? "tv" : "film").font(.largeTitle).foregroundStyle(GlideTheme.muted) }
        }.clipped().task(id: server.id.uuidString + item.id + (item.ImageTags?["Primary"] ?? "") + String(pixels)) {
            image = nil
            var query = ["maxWidth": String(pixels), "quality": "85"]
            if let tag = item.ImageTags?["Primary"] { query["tag"] = tag }
            let url = ServerURL.endpoint(server.address, "Items/\(item.id)/Images/Primary", query: query)
            if let loaded = try? await ArtworkCache.shared.image(server: server, url: url, pixels: pixels), !Task.isCancelled { image = loaded }
        }
    }
}

struct FacetMediaView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var library: LibraryStore
    var server: MediaServer
    var facet: CatalogFacet
    @State private var items: [CatalogItem] = []
    @State private var next = 0
    @State private var total = 0
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var generation = UUID()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("同" + (facet.kind == .tag ? "标签" : "类型") + "作品 · 共 \(total) 部").font(.subheadline).foregroundStyle(GlideTheme.muted)
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: horizontalSizeClass == .compact ? 104 : 140), spacing: 12)], spacing: 18) {
                    ForEach(items) { item in
                        NavigationLink { CatalogDetailView(library: library, server: server, initial: item) } label: {
                            CatalogPosterCard(item: item, server: server)
                        }.buttonStyle(.plain).accessibilityIdentifier("facet.media." + item.id)
                    }
                }
                if loaded && items.isEmpty && error == nil { ContentUnavailableView("暂无相同标签的作品", systemImage: "tag") }
                VStack {
                    if loading { ProgressView("正在查找作品…") }
                    else if let error { Text(error); Button("重试") { Task { await load(reset: !loaded) } } }
                    else if next < total { Button("加载更多") { Task { await load(reset: false) } }.accessibilityIdentifier("facet.more") }
                }.frame(maxWidth: .infinity, minHeight: 56)
            }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 24).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.background(GlideTheme.background).navigationTitle(facet.name).navigationBarTitleDisplayMode(.inline)
            .task(id: facet.id) { if !loaded { await load(reset: true) } }
            .refreshable { await load(reset: true, refresh: true) }
    }
    private func load(reset: Bool, refresh: Bool = false) async {
        guard reset || !loading else { return }
        let id = UUID(); generation = id; loading = true; error = nil
        let start = reset ? 0 : next
        defer { if id == generation { loading = false } }
        do {
            let page = try await MediaClient.shared.facetMedia(server: server, facet: facet, start: start, refresh: refresh)
            try Task.checkCancellation(); guard id == generation else { return }
            var known = Set(reset ? [] : items.map(\.id))
            let added = page.Items.filter { known.insert($0.id).inserted }
            guard start + page.Items.count >= page.TotalRecordCount || !added.isEmpty else { throw MediaError.message("分页没有进展，请刷新重试。") }
            if reset { items = added } else { items += added }
            next = start + page.Items.count; total = page.TotalRecordCount; loaded = true
        } catch { if !Task.isCancelled && id == generation { self.error = error.localizedDescription } }
    }
}

struct SimilarMediaSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var library: LibraryStore
    var server: MediaServer
    var item: CatalogItem
    @State private var items: [CatalogItem] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("相似推荐").font(GlideTheme.Typography.sectionTitle).accessibilityAddTraits(.isHeader)
            if loading { ProgressView("正在寻找相似作品…") }
            if let error {
                Text(error).font(.caption).foregroundStyle(GlideTheme.muted)
                Button("重新获取推荐") { Task { await load(refresh: true) } }
            } else if loaded && items.isEmpty { Text("服务器暂无相似作品推荐。 ").font(.subheadline).foregroundStyle(GlideTheme.muted) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { related in
                        NavigationLink { CatalogDetailView(library: library, server: server, initial: related) } label: {
                            CatalogPosterCard(item: related, server: server).frame(width: dynamicTypeSize.isAccessibilitySize ? 300 : 118)
                        }.buttonStyle(.plain).accessibilityIdentifier("similar." + related.id)
                    }
                }
            }
        }.task(id: item.SeriesId ?? item.id) { if !loaded { await load() } }
    }
    private func load(refresh: Bool = false) async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let results = try await MediaClient.shared.similarMedia(server: server, item: item, refresh: refresh)
            try Task.checkCancellation(); items = results; loaded = true
        } catch { if !Task.isCancelled { self.error = "暂时无法获取推荐，请稍后重试。" } }
    }
}
