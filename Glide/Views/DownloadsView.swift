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
        List {
            Section {
                Label("随时继续观看", systemImage: "arrow.down.to.line").font(.headline)
                Text("下载按队列逐一进行。完成校验的影片可在断网时播放。")
                    .font(.subheadline).foregroundStyle(GlideTheme.muted)
                Text("已安排 " + ByteCountFormatter.string(fromByteCount: downloads.allocatedBytes, countStyle: .file))
                    .font(.caption).foregroundStyle(GlideTheme.muted).accessibilityIdentifier("downloads.storage")
            }.listRowBackground(Color.clear)
            if downloads.entries.isEmpty {
                ContentUnavailableView("还没有离线影片", systemImage: "arrow.down.circle", description: Text("打开电影或单集详情，选择下载原文件。"))
                    .listRowBackground(Color.clear)
            }
            ForEach(groups, id: \.self) { title in
                let entries = downloads.entries.filter { group($0) == title }
                if !entries.isEmpty {
                    Section(title) { ForEach(entries) { entry in downloadRow(entry) } }
                }
            }
            Section {
                Text("支持系统可播放的 MP4 / MOV / M4V 原文件。强制退出可能中断后台任务；重新打开可重试。已完成文件独立保存，移除来源时可选择保留。")
                    .font(.footnote).foregroundStyle(GlideTheme.muted)
            }.listRowBackground(Color.clear)
        }.scrollContentBackground(.hidden).background(GlideTheme.background)
            .navigationTitle("离线下载").task { await downloads.reconcile() }
            .fullScreenCover(item: $selection) { item in
                PlayerView(library: library, queue: item.queue, scopeName: item.scopeName, cinematic: true)
            }
    }
    private func downloadRow(_ entry: OfflineDownload) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let data = entry.artworkData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else { VideoArtwork(video: entry.video) }
            }.frame(width: 76, height: 102).background(GlideTheme.background).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 9) {
                Text(entry.video.title).font(.headline).lineLimit(2)
                HStack {
                    Text(entry.state).font(.caption).foregroundStyle(GlideTheme.accent)
                        .accessibilityIdentifier("download.state." + (entry.video.remoteID ?? entry.id))
                    Spacer()
                    if entry.state == "下载中" { Text(entry.progress, format: .percent.precision(.fractionLength(0))).font(.caption) }
                }
                if entry.state == "下载中" { ProgressView(value: entry.progress) }
                if ["等待下载", "下载中"].contains(entry.state) {
                    Button(entry.state == "等待下载" ? "暂停排队" : "暂停下载") { Task { await downloads.pause(entry.id) } }
                        .accessibilityIdentifier("download.pause." + (entry.video.remoteID ?? entry.id))
                }
                if ["已暂停", "下载失败", "已中断", "文件已移除"].contains(entry.state) {
                    Button(entry.state == "已暂停" ? "继续下载" : "重试下载") { Task { await downloads.resume(entry.id, library: library) } }
                        .accessibilityIdentifier("download.resume." + (entry.video.remoteID ?? entry.id))
                }
                if let message = entry.message { Text(message).font(.caption).foregroundStyle(.orange) }
                if let url = downloads.localURL(videoID: entry.id) {
                    Button {
                        var video = entry.video; video.url = url
                        selection = PlaySelection(queue: PlaybackQueue(videos: [video], mode: .sequential), scopeName: "离线播放")
                    } label: { Label("离线播放", systemImage: "play.fill") }
                        .accessibilityIdentifier("offline.play." + (entry.video.remoteID ?? entry.id))
                }
            }
        }.padding(.vertical, 8).listRowBackground(GlideTheme.panel)
            .swipeActions {
                Button(["等待下载", "下载中"].contains(entry.state) ? "取消下载" : "删除", role: .destructive) { downloads.remove(entry.id) }
            }
    }
}
