import SwiftUI

struct UnifiedLibraryView: View {
    var library: LibraryStore
    @State private var session = UnifiedLibrarySession()
    @State private var query = ""
    @State private var filter = UnifiedFilter.all
    @State private var excluded = Set<String>()
    @State private var limit = 100
    private var sources: [MediaServer] { library.servers.filter { $0.kind.isCatalogSource || $0.kind == .local } }
    private var keys: Set<String> { Set(sources.map(UnifiedSource.binding)).union(["offline"]).union(library.servers.isEmpty ? ["demo"] : []) }
    private var selected: Set<String> { keys.subtracting(excluded) }
    private var requestKey: String {
        [query, filter.rawValue, selected.sorted().joined(), library.servers.map(UnifiedSource.binding).sorted().joined(),
         DownloadStore.shared.entries.filter { $0.state == "已完成" }.map(\.filename).joined()].joined(separator: "\n")
    }
    var body: some View {
        List {
            Section {
                HStack {
                    Menu {
                        Picker("内容类型", selection: $filter) { ForEach(UnifiedFilter.allCases) { Text($0.title).tag($0) } }
                    } label: { Label(filter.title, systemImage: "line.3.horizontal.decrease").frame(minHeight: 44) }
                        .accessibilityIdentifier("unified.filter")
                    Spacer()
                    Menu {
                        Button("选择全部来源") { excluded = [] }
                        Toggle("已下载", isOn: enabled("offline"))
                        if library.servers.isEmpty { Toggle("原创演示", isOn: enabled("demo")) }
                        ForEach(sources) { server in Toggle(server.name, isOn: enabled(UnifiedSource.binding(server))) }
                    } label: { Label("来源 · \(selected.count)", systemImage: "externaldrive").frame(minHeight: 44) }
                        .accessibilityIdentifier("unified.sources")
                }
                Text("远程结果包含已缓存资料，播放时重新核验版本。已下载内容可断网搜索和播放。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = session.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
            Section {
                ForEach(Array(session.works.prefix(limit))) { work in
                    NavigationLink { UnifiedWorkView(library: library, work: work) } label: {
                        UnifiedWorkRow(library: library, work: work)
                    }.accessibilityIdentifier("unified.work." + work.id)
                }
                if session.works.count > limit { Button("显示更多已找到的作品") { limit += 100 } }
                if !session.more.isEmpty { Button("读取更多来源结果") { session.loadMore(library: library) }.disabled(!session.searching.isEmpty).accessibilityIdentifier("unified.more") }
                if session.works.isEmpty && session.searching.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "搜索你的片库" : "没有匹配的内容", systemImage: "magnifyingglass", description: Text(query.isEmpty ? "输入片名，跨来源查找；本地与已缓存内容也会集中显示。" : "可调整关键词、内容类型或来源。"))
                }
            } header: { Text("\(session.works.count) 部作品").accessibilityIdentifier("unified.count") }
            if !session.searching.isEmpty { ProgressView("正在搜索其他来源…").accessibilityIdentifier("unified.loading") }
            if !session.status.isEmpty {
                Section {
                    DisclosureGroup("来源状态") {
                        ForEach(sources) { server in
                            if let status = session.status[UnifiedSource.binding(server)] { LabeledContent(server.name, value: status).font(.caption) }
                        }
                    }
                }
            }
        }.navigationTitle("统一片库").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索片名、节目或文件名")
            .refreshable {
                session.invalidateLocal()
                await session.search(query, filter: filter, selected: selected, library: library)
            }
            .task(id: requestKey) {
                session.stop(); limit = 100
                do { if !query.isEmpty { try await Task.sleep(for: .milliseconds(300)) }; try Task.checkCancellation() }
                catch { return }
                await session.search(query, filter: filter, selected: selected, library: library)
            }.onDisappear { session.stop() }
    }
    private func enabled(_ key: String) -> Binding<Bool> {
        Binding(get: { !excluded.contains(key) }, set: { if $0 { excluded.remove(key) } else { excluded.insert(key) } })
    }
}

private struct UnifiedWorkRow: View {
    var library: LibraryStore
    let work: UnifiedWork
    var body: some View {
        HStack(spacing: 12) {
            UnifiedArtwork(library: library, record: work.variants.first).frame(width: 52, height: 78).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 5) {
                Text(work.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                Text([work.year.map(String.init), work.kind == "Movie" ? "电影" : work.kind == "Series" ? "节目" : work.kind == "Episode" ? "单集" : "视频"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(work.variants.count) 个播放入口" + (work.hasOffline ? " · 已下载" : "") + " · " + Array(Set(work.variants.map(\.sourceName))).sorted().joined(separator: "、"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }.padding(.vertical, 3).accessibilityElement(children: .combine)
    }
}

private struct UnifiedArtwork: View {
    var library: LibraryStore
    var record: UnifiedRecord?
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale
    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "film").foregroundStyle(.secondary) }
        }.clipped().task(id: record?.id) {
            image = nil
            guard let record else { return }
            if record.offline {
                if let data = DownloadStore.shared.entries.first(where: { $0.id == record.video.id })?.artworkData { image = try? await ArtworkCache.shared.image(data: data, pixels: Int(100 * scale)) }
            } else if let server = library.servers.first(where: { UnifiedSource.binding($0) == record.binding }) {
                if server.kind.isCatalogSource, let id = record.video.remoteID {
                    image = try? await ArtworkCache.shared.image(server: server, url: ServerURL.endpoint(server.address, "Items/\(id)/Images/Primary"), pixels: Int(100 * scale))
                } else if server.kind == .local { image = await LocalArtwork.image(video: record.video, server: server) }
            }
        }
    }
}

struct UnifiedWorkView: View {
    var library: LibraryStore
    let work: UnifiedWork
    @State private var selectionID: String?
    @State private var playing: UnifiedPlaybackResolver.Selection?
    @State private var starting = false
    @State private var error: String?
    @State private var showChannels = false
    @State private var tripScope: DiscoveryScope?
    @State private var series: UnifiedRecord?
    @State private var refreshedVariants: [UnifiedRecord]?
    private var variants: [UnifiedRecord] { refreshedVariants ?? work.variants }
    private var selected: UnifiedRecord? {
        if let selectionID { return variants.first { $0.id == selectionID } }
        return variants.first
    }
    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    UnifiedArtwork(library: library, record: selected).frame(width: 80, height: 120).clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(work.title).font(.title3.weight(.semibold))
                        if let year = work.year { Text(String(year)).font(.subheadline).foregroundStyle(.secondary) }
                        Text("选择来源与版本后播放").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 5)
                if let overview = selected?.overview, !overview.isEmpty { Text(overview).font(.subheadline).foregroundStyle(.secondary).lineLimit(6) }
            }
            Section {
                ForEach(variants) { variant in
                    Button { selectionID = variant.id } label: {
                        UnifiedVariantRow(variant: variant, selected: selected?.id == variant.id)
                    }.buttonStyle(.plain).accessibilityIdentifier("unified.variant." + variant.id)
                        .accessibilityAddTraits(selected?.id == variant.id ? [.isSelected] : [])
                }
            } header: { Text("播放入口 · \(variants.count)") }
              footer: { if let date = variants.map(\.updatedAt).max() { Text("资料最近更新：" + date.formatted(date: .abbreviated, time: .shortened)) } }
            Section {
                Button { start() } label: { UnifiedActionLabel(title: work.kind == "Series" ? "选择季集" : "播放所选版本", symbol: "play.fill") }
                    .buttonStyle(.plain)
                    .disabled(starting || selected == nil).accessibilityIdentifier("unified.play")
                if starting { ProgressView("核验所选文件…") }
                if let selected, !selected.offline, selected.video.demoIndex == nil {
                    Button { showChannels = true } label: { UnifiedActionLabel(title: "加入私人频道", symbol: "tv") }
                        .buttonStyle(.plain).accessibilityIdentifier("unified.channel")
                    Button {
                        do { tripScope = try UnifiedSource.scope(selected, library: library) } catch { self.error = error.localizedDescription }
                    } label: { UnifiedActionLabel(title: "准备离线行程", symbol: "suitcase.rolling") }
                        .buttonStyle(.plain).disabled(!selected.isDefault).accessibilityIdentifier("unified.trip")
                    Text("频道按所选来源编排，使用来源默认版本；离线行程暂支持默认原文件。具体容量和内容将在行程页再次确认。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("unified.error") }
            }
        }.navigationTitle("作品").navigationBarTitleDisplayMode(.inline)
            .task {
                let saved = try? await UnifiedLibraryIndex.shared.preferred(work.id)
                selectionID = saved ?? UnifiedLibraryGrouping.preferred(in: work, saved: nil)?.id
                if let saved, !variants.contains(where: { $0.id == saved }) { error = "上次选择不在当前来源中或已不可用，请重新选择播放入口。" }
                await refreshVersions()
            }
            .fullScreenCover(item: $playing) { selection in
                PlayerView(library: library, queue: PlaybackQueue(videos: [selection.video], mode: .sequential), scopeName: "统一片库", cinematic: true, initialTracks: selection.tracks, returnLabel: "返回作品")
            }
            .sheet(item: $series) { record in
                if let server = library.servers.first(where: { UnifiedSource.binding($0) == record.binding }), let id = record.video.remoteID {
                    NavigationStack { CatalogDetailView(library: library, server: server, initial: CatalogItem(Id: id, Name: record.video.title, Type: "Series"))
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { series = nil } } } }
                }
            }
            .sheet(isPresented: $showChannels) { if let selected { UnifiedChannelPicker(library: library, record: selected) } }
            .sheet(item: $tripScope) { scope in OfflineTripComposer(library: library, initialScopes: [scope]) }
    }
    private func start() {
        guard let selected else { return }
        starting = true; error = nil
        Task {
            defer { starting = false }
            do {
                if selected.kind == "Series" {
                    _ = try UnifiedSource.scope(selected, library: library)
                    await remember(selected); series = selected
                } else {
                    let resolved = try await UnifiedPlaybackResolver.resolve(selected, library: library)
                    try Task.checkCancellation()
                    await remember(selected); playing = resolved
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func remember(_ record: UnifiedRecord) async {
        do { try await UnifiedLibraryIndex.shared.prefer(work: work.id, record: record.id) }
        catch { self.error = "本次版本偏好尚未保存，可继续播放。" }
    }
    private func refreshVersions() async {
        var seen = Set<String>()
        let candidates = work.variants.filter { !$0.offline && $0.video.remoteID != nil && seen.insert($0.fileIdentity).inserted }
        await withTaskGroup(of: (String, [UnifiedRecord]?, String?).self) { group in
            for record in candidates {
                guard let server = library.servers.first(where: { UnifiedSource.binding($0) == record.binding }), let remote = record.video.remoteID else { continue }
                group.addTask { @MainActor in
                    do {
                        let item = try await MediaClient.shared.catalogDetail(server: server, id: remote, refresh: true)
                        try Task.checkCancellation()
                        guard item.Id == remote, item.Type == record.kind else { throw MediaError.message("作品资料已变化，请重新搜索。") }
                        let rows = UnifiedSource.records(item: item, server: server)
                        if let expected = record.providerKey, let actual = rows.first?.providerKey, expected != actual { throw MediaError.message("作品标识已变化，请重新搜索。") }
                        return (record.fileIdentity, rows, nil)
                    } catch { return (record.fileIdentity, nil, error.localizedDescription) }
                }
            }
            for await (identity, rows, failure) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                if let rows, let binding = rows.first?.binding, library.servers.contains(where: { UnifiedSource.binding($0) == binding }) {
                    let retained = variants.filter { $0.offline || $0.fileIdentity != identity }
                    refreshedVariants = retained + rows
                    if let selectionID, !variants.contains(where: { $0.id == selectionID }) { error = "所选版本已不可用，请重新选择播放入口。" }
                    do { try await UnifiedLibraryIndex.shared.merge(rows, replacingFile: identity) } catch { self.error = "版本资料已读取，但本次尚未缓存。" }
                } else if let failure { error = "部分来源资料未刷新：" + failure }
            }
        }
    }
}

private struct UnifiedVariantRow: View {
    let variant: UnifiedRecord
    let selected: Bool
    private var sourceTitle: String { variant.sourceName + (variant.offline ? " · 本机副本" : "") }
    private var summary: String {
        guard let source = variant.mediaSource else { return variant.kind == "Series" ? "进入此来源选择季集" : "格式资料未提供" }
        let value = CatalogMediaPresentation.sourceSummary(source)
        return value.isEmpty ? "版本资料未提供" : value
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(sourceTitle).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                if let name = variant.mediaSource?.Name, !name.isEmpty { Text(name).font(.caption).foregroundStyle(.secondary) }
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
    }
}

private struct UnifiedActionLabel: View {
    var title: String
    var symbol: String
    var body: some View {
        Label(title, systemImage: symbol).foregroundStyle(.tint)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
    }
}

private struct UnifiedChannelPicker: View {
    var library: LibraryStore
    let record: UnifiedRecord
    @State private var store = DiscoveryStore.shared
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { add(nil) } label: { UnifiedActionLabel(title: "新建频道并加入", symbol: "plus") }
                        .buttonStyle(.plain).accessibilityIdentifier("unified.channel.new")
                    ForEach(store.channels) { channel in
                        Button { add(channel) } label: { UnifiedActionLabel(title: channel.name, symbol: "tv") }.buttonStyle(.plain)
                    }
                } footer: { Text("节目加入完整节目范围；单片和本地文件加入所选条目。") }
                if let message { Text(message).foregroundStyle(.orange) }
            }.navigationTitle("加入私人频道").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
    private func add(_ existing: PrivateChannel?) {
        do {
            let scope = try UnifiedSource.scope(record, library: library)
            var channel = existing ?? PrivateChannel(name: String(record.video.title.prefix(60)), scopes: [])
            if !channel.scopes.contains(where: { $0.id == scope.id }) { channel.scopes.append(scope) }
            try store.save(channel); dismiss()
        } catch { message = error.localizedDescription }
    }
}
