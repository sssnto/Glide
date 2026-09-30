import SwiftUI

struct DownloadsView: View {
    var library: LibraryStore
    @State private var downloads = DownloadStore.shared
    @State private var selection: PlaySelection?
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("随时继续观看", systemImage: "arrow.down.to.line.compact")
                        .font(.title3.weight(.semibold)).foregroundStyle(GlideTheme.text)
                    Text("已下载的影片保存在此设备。下载支持后台继续。")
                        .font(.subheadline).foregroundStyle(GlideTheme.muted)
                }.padding(.vertical, 8)
            }.listRowBackground(Color.clear)
            if downloads.entries.isEmpty {
                ContentUnavailableView("还没有离线影片", systemImage: "arrow.down.circle", description: Text("打开电影或单集详情，选择下载原文件。"))
                    .listRowBackground(Color.clear)
            }
            ForEach(downloads.entries) { entry in
                HStack(alignment: .top, spacing: 14) {
                    VideoArtwork(video: entry.video)
                        .frame(width: 84, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 9) {
                    Text(entry.video.title).font(.headline).lineLimit(2)
                    HStack { Text(entry.state).font(.caption).foregroundStyle(GlideTheme.accent).accessibilityIdentifier("download.state." + (entry.video.remoteID ?? entry.id)); Spacer(); if entry.state == "下载中" { Text(entry.progress, format: .percent.precision(.fractionLength(0))).font(.caption).foregroundStyle(GlideTheme.muted) } }
                    if entry.state == "下载中" { ProgressView(value: entry.progress) }
                    if entry.state == "下载中" { Button("暂停下载") { Task { await downloads.pause(entry.id) } }.accessibilityIdentifier("download.pause." + (entry.video.remoteID ?? entry.id)) }
                    if ["已暂停", "下载失败", "已中断", "文件已移除"].contains(entry.state) { Button(entry.state == "已暂停" ? "继续下载" : "重试下载") { Task { await downloads.resume(entry.id, library: library) } }.accessibilityIdentifier("download.resume." + (entry.video.remoteID ?? entry.id)) }
                    if let message = entry.message { Text(message).font(.caption).foregroundStyle(.orange) }
                    if let url = downloads.localURL(videoID: entry.id) {
                        Button {
                            var video = entry.video; video.url = url
                            selection = PlaySelection(queue: PlaybackQueue(videos: [video], mode: .sequential), scopeName: "离线播放")
                        } label: { Label("离线播放", systemImage: "play.fill") }
                            .accessibilityIdentifier("offline.play." + (entry.video.remoteID ?? entry.id))
                    }
                    }
                }.padding(.vertical, 8)
                    .listRowBackground(GlideTheme.panel)
                    .swipeActions { Button(entry.state == "下载中" ? "取消下载" : "删除", role: .destructive) { downloads.remove(entry.id) } }
            }
            Section { Text("仅支持 MP4 / MOV / M4V 原文件；视频编码仍需设备支持。强制退出应用会中断下载任务。")
                    .font(.footnote).foregroundStyle(GlideTheme.muted) }
                .listRowBackground(Color.clear)
        }.scrollContentBackground(.hidden).background(GlideTheme.background)
            .navigationTitle("离线下载").task { await downloads.reconcile() }
            .fullScreenCover(item: $selection) { item in PlayerView(library: library, queue: item.queue, scopeName: item.scopeName, cinematic: true) }
    }
}
