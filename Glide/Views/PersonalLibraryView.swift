import SwiftUI

struct PersonalLibraryView: View {
    var library: LibraryStore
    var onPlay: (Video) -> Void
    var presentedAsSheet = true
    @Environment(\.dismiss) private var dismiss
    @State private var favorites = false
    private var videos: [Video] { favorites ? library.favoriteVideos : library.recentVideos }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("个人片库", selection: $favorites) {
                        Text("继续观看").tag(false)
                        Text("我的收藏").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("personal.mode")
                }.listRowBackground(Color.clear)
                if videos.isEmpty {
                    ContentUnavailableView(favorites ? "还没有收藏" : "还没有未看完的视频", systemImage: favorites ? "heart" : "play.circle", description: Text(favorites ? "播放时点亮爱心，或长按封面收藏。旧版收藏会在浏览对应目录时补全。" : "观看进度会保存在此设备，回来时接着看。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(videos) { video in
                    Button { onPlay(video); if presentedAsSheet { dismiss() } } label: {
                        HStack(spacing: 14) {
                            VideoArtwork(video: video).frame(width: 76, height: 90).clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 7) {
                                Text(video.title).font(.headline).lineLimit(2)
                                Text(sourceName(video)).font(.caption).foregroundStyle(GlideTheme.muted)
                                if !favorites {
                                    Text("已观看 " + library.resumePosition(video).mediaTime).font(.caption).foregroundStyle(GlideTheme.muted)
                                    if video.duration > 0 { ProgressView(value: min(library.resumePosition(video), video.duration), total: video.duration).tint(GlideTheme.accent) }
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.fill").foregroundStyle(GlideTheme.accent)
                        }.padding(.vertical, 5)
                    }.buttonStyle(.plain).accessibilityIdentifier("personal.video." + (video.remoteID ?? video.id))
                        .listRowBackground(GlideTheme.panel)
                        .contextMenu {
                            Button(favorites ? "取消收藏" : "删除播放记录", role: .destructive) { remove(video) }
                        }
                        .swipeActions {
                            Button(favorites ? "取消收藏" : "移除记录", role: .destructive) {
                                remove(video)
                            }
                        }
                }
                .onDelete { indices in
                    let selected = indices.map { videos[$0] }
                    selected.forEach(remove)
                }
                Section {
                    Text("可通过编辑、左滑或长按删除本机记录；不会删除服务器上的影片。播放进度会尝试与 Jellyfin 同步；删除本机历史不会重置服务器进度。")
                        .font(.footnote).foregroundStyle(GlideTheme.muted)
                }.listRowBackground(Color.clear)
            }.scrollContentBackground(.hidden).background(GlideTheme.background)
                .navigationTitle("继续与收藏")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { EditButton().disabled(videos.isEmpty) }
                    if presentedAsSheet { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                }
        }.tint(GlideTheme.accent)
    }
    private func remove(_ video: Video) {
        if favorites { library.toggleFavorite(video) } else { library.removeHistory(video) }
    }
    private func sourceName(_ video: Video) -> String {
        library.servers.first { $0.id == video.sourceID }?.name ?? "离线演示"
    }
}
