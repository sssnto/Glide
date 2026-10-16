import SwiftUI

struct DownloadsView: View {
    var library: LibraryStore
    @State private var downloads = DownloadStore.shared
    @State private var selection: PlaySelection?
    private let groups = ["可播放", "进行中", "需处理"]
    private func group(_ entry: OfflineDownload) -> String {
        entry.state == "已完成" ? "可播放" : ["等待下载", "下载中", "校验中"].contains(entry.state) ? "进行中" : "需处理"
    }
    var body: some View {
        let grouped = Dictionary(grouping: downloads.entries, by: group)
        List {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Label("设备存储", systemImage: "internaldrive").font(GlideTheme.Typography.secondary)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: downloads.allocatedBytes, countStyle: .file))
                        .font(GlideTheme.Typography.technical).foregroundStyle(GlideTheme.muted).accessibilityIdentifier("downloads.storage")
                }
            }.listRowBackground(Color.clear)
            if downloads.entries.isEmpty {
                ContentUnavailableView("还没有离线影片", systemImage: "arrow.down.circle", description: Text("打开电影或单集详情，选择下载原文件。"))
                    .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.self) { title in
                let entries = grouped[title] ?? []
                if !entries.isEmpty {
                    Section(title) { ForEach(entries) { entry in downloadRow(entry) } }
                }
            }
            Section {
                DisclosureGroup("离线播放说明") { Text("支持系统可播放的 MP4 / MOV / M4V 原文件。强制退出可能中断后台任务；重新打开可重试。已完成文件独立保存，移除来源时可选择保留。")
                    .font(.footnote).foregroundStyle(GlideTheme.muted) }
            }.listRowBackground(Color.clear)
        }.scrollContentBackground(.hidden).background(GlideTheme.background)
            .font(GlideTheme.Typography.body).navigationTitle("离线下载").navigationBarTitleDisplayMode(.inline).task { await downloads.reconcile() }
            .fullScreenCover(item: $selection) { item in
                PlayerView(library: library, queue: item.queue, scopeName: item.scopeName, cinematic: true)
            }
    }
    private func downloadRow(_ entry: OfflineDownload) -> some View {
        HStack(alignment: .top, spacing: 14) {
            OfflineDownloadArtwork(video: entry.video, data: entry.artworkData)
                .frame(width: 60, height: 84).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.video.title).font(GlideTheme.Typography.itemTitle).lineLimit(2)
                HStack {
                    Text(entry.state).font(.caption).foregroundStyle(GlideTheme.accent)
                        .accessibilityIdentifier("download.state." + (entry.video.remoteID ?? entry.id))
                    Spacer()
                    if entry.state == "下载中" { Text(entry.progress, format: .percent.precision(.fractionLength(0))).font(.caption) }
                }
                HStack(spacing: 6) {
                    if let bytes = entry.expectedBytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
                    if entry.video.duration > 0 { Text(entry.video.duration.mediaTime) }
                }.font(GlideTheme.Typography.caption).foregroundStyle(GlideTheme.muted)
                if entry.state == "下载中" { ProgressView(value: entry.progress) }
                if ["等待下载", "下载中"].contains(entry.state) {
                    Button(entry.state == "等待下载" ? "暂停排队" : "暂停下载") { Task { await downloads.pause(entry.id) } }
                        .frame(minHeight: 44).accessibilityIdentifier("download.pause." + (entry.video.remoteID ?? entry.id))
                }
                if ["已暂停", "下载失败", "已中断", "文件已移除"].contains(entry.state) {
                    Button(entry.state == "已暂停" ? "继续下载" : "重试下载") { Task { await downloads.resume(entry.id, library: library) } }
                        .frame(minHeight: 44).accessibilityIdentifier("download.resume." + (entry.video.remoteID ?? entry.id))
                }
                if let message = entry.message { Text(message).font(.caption).foregroundStyle(.orange) }
                if let url = downloads.localURL(videoID: entry.id) {
                    Button {
                        var video = entry.video; video.url = url
                        selection = PlaySelection(queue: PlaybackQueue(videos: [video], mode: .sequential), scopeName: "离线播放")
                    } label: { Label("离线播放", systemImage: "play.fill") }
                        .frame(minHeight: 44).accessibilityIdentifier("offline.play." + (entry.video.remoteID ?? entry.id))
                }
            }
        }.padding(.vertical, 4).font(GlideTheme.Typography.secondary).buttonStyle(.borderless).listRowBackground(GlideTheme.panel)
            .swipeActions {
                Button(["等待下载", "下载中"].contains(entry.state) ? "取消下载" : "删除", role: .destructive) { downloads.remove(entry.id) }
            }
    }
}

private struct OfflineDownloadArtwork: View {
    let video: Video
    let data: Data?
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        ZStack {
            GlideTheme.background
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { VideoArtwork(video: video) }
        }.task(id: data) {
            image = nil
            guard let data else { return }
            let decoded = try? await ArtworkCache.shared.image(data: data, pixels: Int(84 * displayScale))
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}
