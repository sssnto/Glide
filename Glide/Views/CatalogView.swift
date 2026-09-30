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
    @State private var settingsOpen = false
    @State private var order = CatalogOrder()
    @State private var nextIndex = 0
    @State private var total = 0
    @State private var generation = UUID()
    @State private var restored = false
    @State private var loadedRequestKey: String?
    @State private var visiblePosterID: String?
    @State private var retainedPosterID: String?
    private var shows: Bool { LibraryExperience(collectionType: folder.collectionType) == .shows }
    private var preferencesKey: String { "catalogOrder." + server.id.uuidString + folder.id }
    private var requestKey: String { folder.id + order.key + query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(shows ? "节目" : "电影").font(.caption.weight(.semibold)).foregroundStyle(GlideTheme.accent)
                            Text(folder.name).font(.largeTitle.weight(.semibold)).lineLimit(2)
                            Text("\(total) 部作品 · 选一部，查看详情后播放").font(.caption).foregroundStyle(GlideTheme.muted)
                        }
                        Spacer(minLength: 8)
                        Menu {
                            ForEach(CatalogSort.allCases) { sort in
                                Button { order.sort = sort; saveOrder() } label: { Label(sort.title, systemImage: order.sort == sort ? "checkmark" : "line.3.horizontal.decrease") }
                            }
                            Divider()
                            Button(order.descending ? "改为升序" : "改为降序") { order.descending.toggle(); saveOrder() }
                        } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44).background(GlideTheme.panel, in: Circle()) }
                            .accessibilityLabel("排序：" + order.sort.title + (order.descending ? "，降序" : "，升序"))
                            .accessibilityIdentifier("catalog.sort")
                    }
                    if !loading && error == nil && items.isEmpty { ContentUnavailableView("没有匹配的作品", systemImage: "film") }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 16)], alignment: .leading, spacing: 26) {
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

                }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 32).frame(maxWidth: 1100).frame(maxWidth: .infinity)
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
                    ToolbarItem(placement: .topBarLeading) { Button { Task { await library.jump(to: 0) } } label: { Label("媒体库", systemImage: "chevron.left") } }
                    ToolbarItem(placement: .topBarTrailing) { Button { settingsOpen = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置").accessibilityIdentifier("settings.open") }
                    ToolbarItem(placement: .topBarTrailing) { NavigationLink { DownloadsView(library: library) } label: { Image(systemName: "arrow.down.circle") }.accessibilityLabel("离线下载") }
                }
                .sheet(isPresented: $settingsOpen) { NavigationStack { SettingsView(library: library).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settingsOpen = false } } } } }
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
        let start = reset ? 0 : nextIndex
        defer { if generation == id { loading = false } }
        do {
            let page = try await MediaClient.shared.catalogPage(server: server, parentID: folder.id, type: shows ? "Series" : "Movie", start: start, order: order, search: query.trimmingCharacters(in: .whitespacesAndNewlines), refresh: refresh)
            try Task.checkCancellation(); guard id == generation && key == requestKey else { return }
            var known = Set(reset ? [] : items.map(\.id)); let added = page.Items.filter { known.insert($0.id).inserted }
            guard start + page.Items.count >= page.TotalRecordCount || !added.isEmpty else { throw MediaError.message("分页没有进展，请刷新重试。") }
            if reset { items = added; loadedRequestKey = key; visiblePosterID = nil; retainedPosterID = nil }
            else { items += added }
            nextIndex = start + page.Items.count; total = page.TotalRecordCount
        } catch { if !Task.isCancelled && id == generation { self.error = error.localizedDescription } }
    }
}

struct CatalogPosterCard: View {
    var item: CatalogItem
    var server: MediaServer
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CatalogArtwork(item: item, server: server).aspectRatio(2 / 3, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if let rating = item.CommunityRating { Text("★ " + rating.formatted(.number.precision(.fractionLength(1)))).font(.caption.bold()).padding(7).background(.black.opacity(0.7), in: Capsule()).padding(8) }
                }.clipShape(RoundedRectangle(cornerRadius: 16)).contentShape(Rectangle())
            Text(item.Name).font(.subheadline.weight(.semibold)).lineLimit(2).frame(height: 42, alignment: .topLeading)
            Text([item.Type == "Series" ? "节目" : "电影", item.ProductionYear.map(String.init)].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(GlideTheme.muted).lineLimit(1)
        }.contentShape(Rectangle())
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
    @State private var startFromBeginning = false
    @State private var error: String?
    @State private var episodeError: String?
    @State private var loading = true
    @State private var loadingEpisodes = false
    @State private var playing: PlaySelection?
    @State private var trackSheet: TrackKind?
    @State private var downloadMessage: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var episodeQueue: [CatalogItem] = []
    private var item: CatalogItem { detail ?? initial }
    private var isSeries: Bool { item.Type == "Series" }
    private var source: CatalogItem.Source? { item.MediaSources?.first { $0.Id == sourceID } ?? item.MediaSources?.first }
    private var tracks: TrackSelection {
        TrackSelection(mediaSourceID: source?.Id, audioIndex: audioIndex == -2 ? nil : audioIndex, subtitleIndex: subtitleIndex == -2 ? nil : subtitleIndex)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                detailHero
                if loading { ProgressView("读取媒体信息…") }
                if let error { Text(error).foregroundStyle(.orange); Button("重试") { Task { await load() } } }
                if isSeries { seasonSection }
                if !isSeries {
                    Button { startFromBeginning = false; start() } label: {
                        Label(WatchProgress.canResume(position: library.resumePosition(item.video(server: server)), duration: item.video(server: server).duration) ? "继续观看" : "开始播放", systemImage: "play.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(18)
                            .background(GlideTheme.accent, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.black)
                    }.disabled(loading || detail == nil || starting).accessibilityIdentifier("detail.play")
                    if starting { ProgressView("准备播放队列…") }
                    HStack {
                        Button("从头播放") { startFromBeginning = true; start() }.disabled(starting)
                        Spacer()
                        Button(item.UserData?.Played == true ? "标为未看" : "标为已看") { Task {
                            do {
                                let watched = item.UserData?.Played != true
                                try await MediaClient.shared.setWatched(watched, video: item.video(server: server), server: server)
                                library.positions[item.video(server: server).id] = 0
                                library.progressSnapshots[item.video(server: server).id] = nil; library.persistProgress()
                                UserDefaults.standard.set(library.positions, forKey: "positions")
                                await load(refresh: true)
                            } catch { self.error = error.localizedDescription }
                        } }
                    }.font(.subheadline)
                    playbackOptions
                    Button { Task {
                        do { try await DownloadStore.shared.enqueue(item: item, server: server, sourceID: source?.Id); downloadMessage = "已加入后台下载，可在离线下载中查看进度。" }
                        catch { downloadMessage = error.localizedDescription }
                    } } label: { Label("下载原文件", systemImage: "arrow.down.circle").frame(maxWidth: .infinity, minHeight: 44) }.accessibilityIdentifier("detail.download")
                    if let downloadMessage { Text(downloadMessage).font(.caption).foregroundStyle(GlideTheme.muted) }
                    NavigationLink("离线下载") { DownloadsView(library: library) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("简介").font(.title3.bold())
                    Text(item.Overview?.isEmpty == false ? item.Overview! : "此媒体暂未提供简介。")
                        .font(.body).foregroundStyle(GlideTheme.muted).textSelection(.enabled)
                }
                if !CatalogFacet.facets(item).isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("类型与标签").font(.title3.bold())
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading) {
                            ForEach(CatalogFacet.facets(item)) { facet in
                                NavigationLink { FacetMediaView(library: library, server: server, facet: facet) } label: {
                                    Text((facet.kind == .tag ? "# " : "") + facet.name).font(.subheadline).lineLimit(2)
                                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44)
                                        .background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                                }.buttonStyle(.plain).accessibilityIdentifier("facet." + facet.id)
                            }
                        }
                    }
                }
                if let people = item.People, !people.isEmpty {
                    CastSection(library: library, server: server, people: people)
                }
                SimilarMediaSection(library: library, server: server, item: item)
            }.padding(24).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.background(GlideTheme.background).navigationBarTitleDisplayMode(.inline)
            .task(id: initial.id) { await load() }
            .refreshable { await load(refresh: true) }
            .sheet(item: $trackSheet) { kind in
                TrackChoicesView(title: kind == .audio ? "选择声音" : "选择字幕", streams: source?.MediaStreams?.filter { $0.Type == (kind == .audio ? "Audio" : "Subtitle") } ?? [], selection: kind == .audio ? $audioIndex : $subtitleIndex, allowsOff: kind == .subtitle)
            }
            .task(id: seasonID) { await loadEpisodes() }
            .fullScreenCover(item: $playing) { selection in
                PlayerView(library: library, queue: selection.queue, scopeName: item.SeriesName ?? item.Name,
                           cinematic: true, initialTracks: tracks, initialResumeAt: startFromBeginning ? 0 : nil)
            }
    }
    private var detailHero: some View {
        Group {
            if item.Type == "Episode" {
                VStack(alignment: .leading, spacing: 16) {
                    CatalogArtwork(item: item, server: server)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    heroMetadata
                }
            } else if horizontalSizeClass == .compact {
                VStack(alignment: .leading, spacing: 16) {
                    CatalogArtwork(item: item, server: server)
                        .frame(width: 176, height: 264)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    heroMetadata
                }
            } else {
                HStack(alignment: .top, spacing: 28) {
                    CatalogArtwork(item: item, server: server)
                        .frame(width: 192, height: 288)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    heroMetadata.padding(.top, 10)
                    Spacer(minLength: 0)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var heroMetadata: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.Type == "Episode" ? (item.SeriesName ?? "节目") + " · " + item.episodeLabel : isSeries ? "节目" : "电影")
                .font(.caption.weight(.semibold)).foregroundStyle(GlideTheme.accent)
            Text(item.Name).font(.system(.largeTitle, design: .rounded, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(item.facts).font(.subheadline).foregroundStyle(GlideTheme.muted)
            if let genres = item.Genres, !genres.isEmpty {
                Text(genres.prefix(3).joined(separator: "  ·  ")).font(.caption).foregroundStyle(GlideTheme.muted)
            }
        }
    }
    private var playbackOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("播放版本与语言").font(.headline)
            if let sources = item.MediaSources, sources.count > 1 {
                Picker("版本", selection: $sourceID) { ForEach(sources) { Text($0.Name ?? $0.Id).tag($0.Id) } }
                    .onChange(of: sourceID) { _, _ in audioIndex = -2; subtitleIndex = -2 }
            }
            Button { trackSheet = .audio } label: { PlaybackOptionRow(title: "声音", value: source?.MediaStreams?.first { $0.Index == audioIndex }?.label ?? "服务器默认") }.accessibilityIdentifier("detail.audio")
            Divider()
            Button { trackSheet = .subtitle } label: { PlaybackOptionRow(title: "字幕", value: subtitleIndex == -1 ? "关闭字幕" : source?.MediaStreams?.first { $0.Index == subtitleIndex }?.label ?? "服务器默认") }.accessibilityIdentifier("detail.subtitle")
            Text("画质与转码由播放器自动处理。")
                .font(.caption).foregroundStyle(GlideTheme.muted)
        }.pickerStyle(.menu).padding(18).background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 18))
    }
    @ViewBuilder private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("季与集").font(.title3.bold())
            if seasons.isEmpty && !loading && error == nil { Text("此节目暂无可用的季。") }
            Picker("选择季", selection: $seasonID) { ForEach(seasons) { Text($0.IndexNumber == 0 ? "特别篇" : $0.Name).tag($0.id) } }
                .pickerStyle(.menu).accessibilityIdentifier("detail.season")
            if loadingEpisodes { ProgressView("正在读取剧集…") }
            if let episodeError { Text(episodeError); Button("重试剧集") { Task { await loadEpisodes() } } }
            if !loadingEpisodes && episodeError == nil && !seasonID.isEmpty && episodes.isEmpty { Text("本季暂无可用剧集。") }
            ForEach(episodes) { episode in
                NavigationLink {
                    CatalogDetailView(library: library, server: server, initial: episode, episodeQueue: episodes)
                } label: {
                    HStack(spacing: 14) {
                        CatalogArtwork(item: episode, server: server).frame(width: 110, height: 66).clipShape(RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
                        VStack(alignment: .leading, spacing: 6) {
                            Text(episode.episodeLabel).font(.caption).foregroundStyle(GlideTheme.accent)
                            Text(episode.Name).font(.headline).lineLimit(2)
                            Text(episode.Overview ?? "查看详情与播放选项").font(.caption).foregroundStyle(GlideTheme.muted).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption)
                    }.padding(12).background(GlideTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityIdentifier("episode." + episode.id)
            }
        }
    }
    private func load(refresh: Bool = false) async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let loaded = try await MediaClient.shared.catalogDetail(server: server, id: initial.id, refresh: refresh)
            try Task.checkCancellation()
            detail = loaded; sourceID = loaded.MediaSources?.first?.Id ?? ""
            if loaded.Type == "Series" {
                seasons = try await MediaClient.shared.catalogItems(server: server, parentID: loaded.id, type: "Season", refresh: refresh)
                seasonID = seasons.first?.id ?? ""
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
    private func start() {
        guard !starting else { return }
        starting = true; error = nil
        Task { @MainActor in
            defer { starting = false }
            do {
                var entries = episodeQueue.isEmpty ? [item] : CatalogItem.episodeOrder(episodeQueue)
                if item.Type == "Episode", let series = item.SeriesId {
                    entries = CatalogItem.episodeOrder(try await MediaClient.shared.catalogItems(server: server, parentID: series, type: "Episode"))
                    if !entries.contains(where: { $0.id == item.id }) { entries.append(item); entries = CatalogItem.episodeOrder(entries) }
                }
                let videos = entries.map { ($0.id == item.id ? item : $0).video(server: server) }
                library.remember(videos)
                playing = PlaySelection(queue: PlaybackQueue(videos: videos, mode: .sequential, startID: item.video(server: server).id), scopeName: item.Name)
            } catch { self.error = "无法准备剧集队列，请重试。" }
        }
    }
}


struct CatalogArtwork: View {
    var item: CatalogItem
    var server: MediaServer
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            GlideTheme.panel
            if let image { GeometryReader { proxy in
                Image(uiImage: image).resizable().scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
            }.allowsHitTesting(false) }
            else { Image(systemName: item.Type == "Person" ? "person.crop.rectangle" : item.Type == "Series" ? "tv" : "film").font(.largeTitle).foregroundStyle(GlideTheme.muted) }
        }.clipped().task(id: server.id.uuidString + item.id + (item.ImageTags?["Primary"] ?? "")) {
            image = nil
            var query = ["maxWidth": "700", "quality": "90"]
            if let tag = item.ImageTags?["Primary"] { query["tag"] = tag }
            let url = ServerURL.endpoint(server.address, "Items/\(item.id)/Images/Primary", query: query)
            if let loaded = try? await ArtworkCache.shared.image(server: server, url: url, pixels: 900), !Task.isCancelled { image = loaded }
        }
    }
}

struct FacetMediaView: View {
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
            LazyVStack(alignment: .leading, spacing: 20) {
                Text("当前服务器 · 同" + (facet.kind == .tag ? "标签" : "类型") + "作品").font(.subheadline).foregroundStyle(GlideTheme.muted)
                Text("共 \(total) 部 · 已加载 \(items.count) 部").font(.caption).foregroundStyle(GlideTheme.muted)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], spacing: 22) {
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
            }.padding(24).frame(maxWidth: 1100).frame(maxWidth: .infinity)
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
    var library: LibraryStore
    var server: MediaServer
    var item: CatalogItem
    @State private var items: [CatalogItem] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("相似推荐").font(.title3.bold())
            if loading { ProgressView("正在寻找相似作品…") }
            if let error {
                Text(error).font(.caption).foregroundStyle(GlideTheme.muted)
                Button("重新获取推荐") { Task { await load(refresh: true) } }
            } else if loaded && items.isEmpty { Text("Jellyfin 暂无相似作品推荐。 ").font(.subheadline).foregroundStyle(GlideTheme.muted) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { related in
                        NavigationLink { CatalogDetailView(library: library, server: server, initial: related) } label: {
                            CatalogPosterCard(item: related, server: server).frame(width: 145)
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
