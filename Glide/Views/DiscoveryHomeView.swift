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
                   }, onQueueFinished: onQueueFinished, returnLabel: selection.channelID != nil ? "返回频道" : selection.title == "继续观看" ? "返回观看" : selection.title == "观看历史" ? "返回观看历史":"返回选片")
    }
}

struct DiscoveryHomeView: View {
    var library:LibraryStore
    var openLibrary:(()->Void)?=nil
    var store=DiscoveryStore.shared
    @State private var playing:DiscoveryPlayback?
    @State private var pendingPlayback:DiscoveryPlayback?
    private enum Sheet:String,Identifiable { case sources,history,library,settings;var id:String {rawValue} }
    @State private var sheet:Sheet?
    @Environment(\.dynamicTypeSize) private var typeSize
    var body:some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment:.leading,spacing:26) {
                    if !library.continueWatching.isEmpty {
                        VStack(alignment:.leading,spacing:12) {
                            HStack {
                                WorkspaceSectionHeading(title:"继续观看")
                                Button("观看历史") { sheet = .history }.font(.caption).frame(minHeight:44)
                            }
                            ScrollView(.horizontal,showsIndicators:false) {
                                LazyHStack(alignment:.top,spacing:14) {
                                    ForEach(Array(library.continueWatching.prefix(8))) { entry in
                                        WorkspaceResumeCard(entry:entry,library:library) {
                                            playing=DiscoveryPlayback(videos:[entry.video],title:"继续观看",resumeAt:library.resumePosition(entry.video))
                                        }
                                    }
                                }
                            }.contentMargins(.bottom,2)
                        }
                    }
                    VStack(alignment:.leading,spacing:12) {
                        WorkspaceSectionHeading(title:"现在想看什么")
                        NavigationLink { TimePickView(library:library,store:store) } label: {
                            WorkspaceFeatureLabel(title:"给我选一部",detail:"按时间和观看进度挑选",symbol:"clock.badge.checkmark")
                        }.buttonStyle(.plain).accessibilityIdentifier("discovery.time.open")
                        NavigationLink { WorkspaceChannelsView(library:library,store:store) } label: {
                            WorkspaceFeatureLabel(title:"我的频道",detail:store.channels.isEmpty ? "把喜欢的内容编成连续观看的频道":"\(store.channels.count) 个频道 · 剧集保持顺序",symbol:"play.rectangle.on.rectangle")
                        }.buttonStyle(.plain).accessibilityIdentifier("workspace.channels")
                    }
                    if !library.videos.isEmpty {
                        VStack(alignment:.leading,spacing:12) {
                            HStack {
                                WorkspaceSectionHeading(title:library.selectedID == nil ? "先看一段演示":"当前片库",detail:library.selectedID == nil ? "原创素材":library.currentDirectoryName)
                                Button("查看") { browse(nil) }.font(.caption).frame(minHeight:44)
                            }
                            ScrollView(.horizontal,showsIndicators:false) {
                                LazyHStack(alignment:.top,spacing:14) {
                                    ForEach(Array(library.videos.prefix(8))) { video in
                                        Button { playing=DiscoveryPlayback(videos:[video],title:library.currentDirectoryName) } label: {
                                            VStack(alignment:.leading,spacing:7) {
                                                VideoArtwork(video:video,server:library.selectedServer).frame(width:210,height:118).clipShape(.rect(cornerRadius:10))
                                                Text(RecommendationMediaIdentity(video).title).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
                                                Text(video.duration>0 ? video.duration.mediaTime:video.demoIndex != nil ? "原创动态风景":"视频").font(.caption).foregroundStyle(.secondary)
                                            }.frame(width:210,alignment:.leading)
                                        }.buttonStyle(.plain).accessibilityIdentifier("workspace.featured."+video.id)
                                    }
                                }
                            }
                        }
                    }
                    VStack(alignment:.leading,spacing:12) {
                        HStack {
                            WorkspaceSectionHeading(title:"媒体来源",detail:"\(library.servers.count) 个连接")
                            Button { sheet = .sources } label: { Image(systemName:"plus").frame(width:44,height:44) }.accessibilityLabel("添加或管理媒体来源")
                        }
                        if library.servers.isEmpty {
                            Button { sheet = .sources } label: {
                                WorkspaceFeatureLabel(title:"连接你的片库",detail:"Jellyfin、Emby、NAS 或本地视频",symbol:"externaldrive.badge.plus")
                            }.buttonStyle(.plain).accessibilityIdentifier("workspace.connect")
                        } else {
                            ForEach(library.servers) { server in
                                Button { browse(server) } label: {
                                    HStack(spacing:12) {
                                        Image(systemName:server.kind == .local ? "folder":"externaldrive").foregroundStyle(.tint).frame(width:32,height:44)
                                        Text(server.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                        Spacer();Text(server.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                                        Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    }.contentShape(.rect)
                                }.buttonStyle(.plain).accessibilityIdentifier("workspace.source."+server.id.uuidString)
                            }
                        }
                    }
                    if let message=store.message ?? library.storageMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }.padding(.horizontal,16).padding(.top,12).padding(.bottom,28).frame(maxWidth:1000).frame(maxWidth:.infinity)
            }.background(GlideTheme.background).navigationTitle("观看").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.topBarTrailing) { NavigationLink { UnifiedLibraryView(library:library) } label: { Image(systemName:"magnifyingglass").frame(width:44,height:44) }.accessibilityLabel("搜索全部片库").accessibilityIdentifier("unified.open") }
                    ToolbarItem(placement:.topBarTrailing) { WorkspaceSettingsButton { sheet = .settings } }
                }
                .task { await library.refreshContinueWatching() }
                .sheet(item:$sheet,onDismiss:{ if let value=pendingPlayback { pendingPlayback=nil;playing=value } }) { destination in
                    switch destination {
                    case .settings:WorkspaceSettingsSheet(library:library)
                    case .sources:SourcesView(library:library)
                    case .history:PersonalLibraryView(library:library,onPlay:{ pendingPlayback=DiscoveryPlayback(videos:[$0],title:"观看历史",resumeAt:library.resumePosition($0));sheet=nil },startsWithFavorites:false)
                    case .library:LibraryView(library:library)
                    }
                }
                .fullScreenCover(item:$playing) { value in DiscoveryPlayer(library:library,selection:value,store:store) }
        }
    }
    private func browse(_ server:MediaServer?) {
        Task { if let server { await library.select(server.id) };if let openLibrary { openLibrary() } else { sheet = .library } }
    }
}

struct WorkspaceChannelsView:View {
    let library:LibraryStore
    let store:DiscoveryStore
    @State private var editing:PrivateChannel?
    var body:some View {
        List {
            if store.channels.isEmpty {
                ContentUnavailableView("创建你的频道",systemImage:"play.rectangle.on.rectangle",description:Text("把电影、剧集和目录编排在一起，打开就能接着看。"))
            }
            ForEach(store.channels) { channel in
                NavigationLink { PrivateChannelView(library:library,store:store,channelID:channel.id) } label: {
                    VStack(alignment:.leading,spacing:5) {
                        Text(channel.name).font(.subheadline.weight(.semibold))
                        Text("\(channel.scopes.count) 个内容范围 · 剧集按顺序").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical,6)
                }.accessibilityIdentifier("discovery.channel."+channel.id.uuidString)
            }
        }.navigationTitle("我的频道").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.primaryAction) { Button { editing=PrivateChannel(name:"我的频道",scopes:[DiscoveryResolver.current(library)]) } label: { Label("新建频道",systemImage:"plus") }.accessibilityIdentifier("discovery.channel.create") } }
            .sheet(item:$editing) { draft in ChannelEditorView(library:library,store:store,draft:draft) }
    }
}

struct DiscoveryVideoRow: View {
    var video: Video
    var library: LibraryStore
    var detail: String
    var showsWorkIdentity = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var identity: RecommendationMediaIdentity { RecommendationMediaIdentity(video) }
    var body: some View {
        HStack(alignment: showsWorkIdentity ? .top : .center, spacing: 12) {
            VideoArtwork(video: video, server: library.servers.first { $0.id == video.sourceID })
                .frame(width: showsWorkIdentity ? 60 : 48, height: showsWorkIdentity ? 90 : 68).clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(showsWorkIdentity ? identity.title : video.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if showsWorkIdentity, let episode = identity.episode {
                    Text(episode).font(.caption).foregroundStyle(.primary).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
                if showsWorkIdentity, let facts = identity.facts { Text(facts).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let server = library.servers.first(where: { $0.id == video.sourceID }) {
                    Text(showsWorkIdentity ? "来源 · " + server.name : server.name).font(.caption2).foregroundStyle(.secondary)
                }
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
