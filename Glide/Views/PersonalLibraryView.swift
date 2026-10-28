import SwiftUI

struct PersonalLibraryView: View {
    var library: LibraryStore
    var onPlay: (Video) -> Void
    var presentedAsSheet = true
    @Environment(\.dismiss) private var dismiss
    @State private var favorites = false
    private var entries: [ContinueWatchingItem] {
        if favorites {
            return library.favoriteVideos.map { ContinueWatchingItem(id: $0.id, video: $0, historyIDs: [$0.id], lastPlayedAt: .distantPast) }
        }
        return library.continueWatching
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { ClipLibraryView(library: library) } label: {
                        Label("精彩片段集", systemImage: "scissors").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.accessibilityIdentifier("personal.clips")
                    NavigationLink { MomentLibraryView(library: library) } label: {
                        Label("时刻收藏", systemImage: "bookmark")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.accessibilityIdentifier("personal.moments")
                }
                Section {
                    Picker("个人片库", selection: $favorites) {
                        Text("继续观看").tag(false)
                        Text("我的收藏").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("personal.mode")
                }.listRowBackground(Color.clear)
                if entries.isEmpty {
                    ContentUnavailableView(favorites ? "还没有收藏" : "还没有观看记录", systemImage: favorites ? "heart" : "play.circle", description: Text(favorites ? "播放时点亮爱心，或长按封面收藏。" : "电影和节目会在这里继续观看；家庭刷看不保存历史。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(entries) { entry in
                    let position = library.resumePosition(entry.video)
                    Button { onPlay(entry.video); if presentedAsSheet { dismiss() } } label: {
                        HStack(spacing: 14) {
                            VideoArtwork(video: cover(entry), server: library.servers.first { $0.id == entry.video.sourceID }).frame(width: 60, height: 84).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 7) {
                                Text(favorites ? entry.video.title : entry.title).font(GlideTheme.Typography.itemTitle).lineLimit(2)
                                Text(sourceName(entry.video)).font(.caption).foregroundStyle(GlideTheme.muted)
                                if !favorites {
                                    if !entry.episodeLabel.isEmpty { Text(entry.episodeLabel).font(.caption).foregroundStyle(GlideTheme.accent) }
                                    Text(entry.finished ? "已看完 · 从头观看" : position > 1 ? "已观看 " + position.mediaTime : "下一集")
                                        .font(.caption).foregroundStyle(GlideTheme.muted)
                                    if !entry.finished, entry.video.duration > 0 { ProgressView(value: min(position, entry.video.duration), total: entry.video.duration).tint(GlideTheme.accent) }
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.fill").font(.subheadline).foregroundStyle(GlideTheme.accent).frame(width: 44, height: 44)
                        }.padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("personal.video." + (entry.video.remoteID ?? entry.video.id))
                        .listRowBackground(GlideTheme.panel)
                        .contextMenu {
                            if let series = entry.video.seriesID, let server = library.servers.first(where: { $0.id == entry.video.sourceID }) {
                                NavigationLink("查看节目与全部集数") { CatalogDetailView(library: library, server: server, initial: CatalogItem(Id: series, Name: entry.title, Type: "Series")) }
                            }
                            Button(favorites ? "取消收藏" : "删除播放记录", role: .destructive) { remove(entry) }
                        }
                        .swipeActions { Button(favorites ? "取消收藏" : "移除记录", role: .destructive) { remove(entry) } }
                }.onDelete { indices in indices.map { entries[$0] }.forEach(remove) }

            }.scrollContentBackground(.hidden).background(GlideTheme.background)
                .font(GlideTheme.Typography.body).navigationTitle("我的片库").navigationBarTitleDisplayMode(.inline)
                .task { await library.refreshContinueWatching() }
                .refreshable { await library.refreshContinueWatching(refresh: true) }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { EditButton().disabled(entries.isEmpty) }
                    if presentedAsSheet { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                }
        }.tint(GlideTheme.accent)
    }
    private func remove(_ entry: ContinueWatchingItem) {
        if favorites { library.toggleFavorite(entry.video) } else { library.removeContinueWatching(entry) }
    }
    private func cover(_ entry: ContinueWatchingItem) -> Video {
        var video = entry.video
        if !favorites, let series = video.seriesID, let server = library.servers.first(where: { $0.id == video.sourceID }) {
            video.artwork = ServerURL.endpoint(server.address, "Items/\(series)/Images/Primary", query: ["maxWidth": "320"])
        }
        return video
    }
    private func sourceName(_ video: Video) -> String { video.streamLinkID != nil ? "链接播放" : library.servers.first { $0.id == video.sourceID }?.name ?? "离线演示" }
}
