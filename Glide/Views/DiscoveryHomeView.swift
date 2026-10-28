import SwiftUI

struct DiscoveryPlayback: Identifiable {
    var id = UUID()
    var videos: [Video]
    var title: String
    var resumeAt: Double?
    var channelID: UUID?
}

struct DiscoveryPlayer: View {
    var library: LibraryStore
    var selection: DiscoveryPlayback
    var store: DiscoveryStore
    var onQueueFinished: (() -> Void)? = nil
    var body: some View {
        PlayerView(library: library, queue: PlaybackQueue(videos: selection.videos, mode: .sequential), scopeName: selection.title,
                   initialResumeAt: selection.resumeAt, channelMode: selection.channelID != nil,
                   onFirstFrame: { video in
                       if let channel = selection.channelID { store.recordStart(channelID: channel, videoID: video.id) }
                   }, onQueueFinished: onQueueFinished, returnLabel: selection.channelID != nil ? "返回频道" : selection.title == "继续观看" ? "返回首页" : "返回选片")
    }
}

struct DiscoveryHomeView: View {
    var library: LibraryStore
    var store = DiscoveryStore.shared
    @State private var editing: PrivateChannel?
    @State private var playing: DiscoveryPlayback?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { UnifiedLibraryView(library: library) } label: {
                        Label("搜索全部片库", systemImage: "magnifyingglass").frame(minHeight: 44)
                    }.accessibilityIdentifier("unified.open")
                }
                Section {
                    NavigationLink { ClipLibraryView(library: library) } label: {
                        Label("精彩片段集", systemImage: "scissors").frame(minHeight: 44)
                    }.accessibilityIdentifier("clips.open")
                    NavigationLink { TimePickView(library: library, store: store) } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("给我选一部").font(.headline)
                                Text("按你现在的时间，挑一部能看完的").font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                        } icon: { Image(systemName: "clock.badge.checkmark").font(.title2) }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.accessibilityIdentifier("discovery.time.open")
                }
                if !library.continueWatching.isEmpty {
                    Section("继续观看") {
                        ForEach(Array(library.continueWatching.prefix(3))) { item in
                            Button { playing = DiscoveryPlayback(videos: [item.video], title: "继续观看", resumeAt: library.resumePosition(item.video)) } label: {
                                DiscoveryVideoRow(video: item.video, library: library, detail: item.episodeLabel.isEmpty ? "继续上次观看" : item.episodeLabel)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    if store.channels.isEmpty {
                        Text("把喜欢的剧集、电影或视频目录编排成频道，打开就能看。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 4)
                    }
                    ForEach(store.channels) { channel in
                        NavigationLink { PrivateChannelView(library: library, store: store, channelID: channel.id) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(channel.name).font(.headline)
                                    Text("\(channel.scopes.count) 个内容范围 · 剧集按顺序").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 5)
                            } icon: { Image(systemName: "tv") }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.accessibilityIdentifier("discovery.channel." + channel.id.uuidString)
                            .swipeActions {
                                Button("删除频道", role: .destructive) { do { try store.remove(channel.id) } catch { self.error = error.localizedDescription } }
                            }
                    }
                    Button("新建频道", systemImage: "plus") { editing = PrivateChannel(name: "我的频道", scopes: [DiscoveryResolver.current(library)]) }
                        .accessibilityIdentifier("discovery.channel.create")
                } header: { Text("我的频道") }
                if let message = store.message ?? library.storageMessage { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
            }
            .navigationTitle("首页").navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(GlideTheme.background)
            .sheet(item: $editing) { draft in ChannelEditorView(library: library, store: store, draft: draft) }
            .fullScreenCover(item: $playing) { selection in DiscoveryPlayer(library: library, selection: selection, store: store) }
            .alert("暂时无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
        }
    }
}

struct DiscoveryVideoRow: View {
    var video: Video
    var library: LibraryStore
    var detail: String
    var body: some View {
        HStack(spacing: 12) {
            VideoArtwork(video: video, server: library.servers.first { $0.id == video.sourceID })
                .frame(width: 48, height: 68).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 5) {
                Text(video.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let server = library.servers.first(where: { $0.id == video.sourceID }) { Text(server.name).font(.caption2).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).contentShape(Rectangle())
    }
}

struct ChannelEditorView: View {
    var library: LibraryStore
    var store: DiscoveryStore
    @State var draft: PrivateChannel
    var onSaved: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    private enum Sheet: String, Identifiable { case scopes; var id: String { rawValue } }
    @State private var sheet: Sheet?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("频道名称") { TextField("例如：下饭喜剧台", text: $draft.name).accessibilityIdentifier("discovery.channel.name") }
                Section {
                    ForEach(draft.scopes) { scope in Label(scope.name, systemImage: "rectangle.stack") }
                        .onDelete { draft.scopes.remove(atOffsets: $0) }
                    Button("选择内容范围", systemImage: "plus") { sheet = .scopes }.accessibilityIdentifier("discovery.channel.scopes")
                } header: { Text("内容 · \(draft.scopes.count) 个范围") } footer: { Text("可以混合多个来源。向左滑动可移除范围，同一视频会自动去重。") }
                Section {
                    Toggle("只播未看完的内容", isOn: $draft.unwatchedOnly).accessibilityIdentifier("discovery.channel.unwatched")
                    Toggle("避开最近七天开播的内容", isOn: $draft.avoidRecent).accessibilityIdentifier("discovery.channel.recent")
                    Label("剧集内部按季集顺序", systemImage: "list.number").foregroundStyle(.secondary)
                } header: { Text("编排规则") } footer: { Text("多个剧集和目录轮流播放；未看完的剧集继续上次，不会为避开重复而跳集。频道有明确结束，不自动循环。开播去重记录仅保存在本机，可在频道内清除。") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle("编辑频道").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            do { try store.save(draft); onSaved?(); dismiss() } catch { self.error = error.localizedDescription }
                        }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.scopes.isEmpty).accessibilityIdentifier("discovery.channel.save")
                    }
                }
                .sheet(item: $sheet) { _ in DiscoveryScopePicker(library: library, selected: draft.scopes) { draft.scopes = $0 } }
        }
    }
}

struct PrivateChannelView: View {
    var library: LibraryStore
    var store: DiscoveryStore
    var channelID: UUID
    private var channel: PrivateChannel? { store.channels.first { $0.id == channelID } }
    @State private var editing: PrivateChannel?
    @State private var playing: DiscoveryPlayback?
    @State private var queue: [Video] = []
    @State private var loading = true
    @State private var count = 0
    @State private var error: String?
    @State private var revision = UUID()
    var body: some View {
        List {
            if let channel {
                Section {
                    Button { playing = DiscoveryPlayback(videos: queue, title: channel.name, channelID: channel.id) } label: {
                        Label("开始播放 · \(queue.count) 条", systemImage: "play.fill").font(.headline).padding(.vertical, 6)
                    }.disabled(loading || queue.isEmpty).accessibilityIdentifier("discovery.channel.play")
                    Text(channel.scopes.map(\.name).joined(separator: "、")).font(.subheadline).foregroundStyle(.secondary)
                    Text((channel.unwatchedOnly ? "只播未看完 · " : "") + (channel.avoidRecent ? "避开最近七天 · " : "") + "剧集按顺序").font(.caption).foregroundStyle(.secondary)
                }
                if loading { ProgressView("正在准备 · 已读取 \(count) 条").accessibilityIdentifier("discovery.loading") }
                if let error { Section { Text(error).foregroundStyle(.secondary); Button("重新准备") { revision = UUID() } } }
                if !loading && queue.isEmpty && error == nil {
                    ContentUnavailableView("暂时没有可播放内容", systemImage: "tv", description: Text("可调整内容范围或编排规则；最近播过的内容可能已被排除。"))
                }
                Section("本次编排") {
                    ForEach(Array(queue.enumerated()), id: \.element.id) { index, video in
                        DiscoveryVideoRow(video: video, library: library, detail: "\(index + 1) · " + (video.seriesTitle ?? (video.duration > 0 ? video.duration.mediaTime : "片长未知")))
                            .accessibilityIdentifier("discovery.queue.\(index)")
                    }
                }
            }
        }.navigationTitle(channel?.name ?? "频道已移除").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("编辑频道", systemImage: "pencil") { editing = channel }.accessibilityIdentifier("discovery.channel.edit")
                    Button("重新准备", systemImage: "arrow.clockwise") { revision = UUID() }
                    Button("清除开播去重记录") {
                        guard var value = channel else { return }; value.lastStarted = [:]
                        do { try store.save(value); revision = UUID() } catch { self.error = error.localizedDescription }
                    }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("discovery.channel.more")
            } }
            .task(id: revision) {
                guard let channel else { loading = false; return }
                loading = true; queue = []; error = nil; count = 0
                do {
                    let batches = try await DiscoveryResolver.batches(channel.scopes, library: library) { count = $0 }
                    try Task.checkCancellation()
                    queue = ChannelPlanner.queue(batches, channel: channel, positions: [:]); loading = false
                } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
            }
            .sheet(item: $editing) { draft in ChannelEditorView(library: library, store: store, draft: draft) { revision = UUID() } }
            .fullScreenCover(item: $playing, onDismiss: { revision = UUID() }) { selection in DiscoveryPlayer(library: library, selection: selection, store: store) }
    }
}
