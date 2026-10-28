import SwiftUI

struct OfflineTripDetail: View {
    var library: LibraryStore
    let tripID: UUID
    @State private var store = OfflineTripStore.shared
    @State private var downloads = DownloadStore.shared
    @State private var messages: [String] = []
    @State private var checking = false
    @State private var playing: PlaySelection?
    @State private var confirmingRemoval = false
    @Environment(\.dismiss) private var dismiss
    private var trip: OfflineTrip? { store.trips.first { $0.id == tripID } }
    private var queueing: Bool { store.preparing.contains(tripID) }
    private var entries: [OfflineDownload] { (trip?.videoIDs ?? []).compactMap { id in downloads.entries.first { $0.id == id } } }
    private var completed: [OfflineDownload] { entries.filter { downloads.localURL(videoID: $0.id) != nil } }
    var body: some View {
        List {
            if let trip {
                Section {
                    LabeledContent("已下载", value: "\(completed.count) / \(trip.videoIDs.count)")
                    LabeledContent("原文件容量", value: ByteCountFormatter.string(fromByteCount: entries.reduce(0) { $0 + ($1.expectedBytes ?? 0) }, countStyle: .file))
                    Button(queueing ? "正在准备…" : "准备／重试未完成内容", systemImage: "arrow.down.circle") {
                        store.start(trip, library: library)
                    }.disabled(queueing).accessibilityIdentifier("trip.prepare")
                    if queueing { Button("停止准备") { store.stop(tripID) } }
                    Button("出发前离线检查", systemImage: "checkmark.shield") { checking = true }
                        .disabled(completed.isEmpty).accessibilityIdentifier("trip.check")
                    Button("播放已下载（\(completed.count)）", systemImage: "play.fill") { play(from: completed.first?.id) }
                        .disabled(completed.isEmpty).accessibilityIdentifier("trip.play")
                    Text("离线检查会静音试播文件并检查字幕资料。检查通过仅对应本机当前文件版本；未完成的内容不会加入离线播放队列。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !(messages + (store.preparationMessages[tripID] ?? [])).isEmpty { Section("准备结果") { ForEach(Array(Set(messages + (store.preparationMessages[tripID] ?? []))).sorted(), id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) } } }
                Section("行程内容") {
                    ForEach(trip.videos) { video in
                        let entry = entries.first { $0.id == video.id }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(video.title).font(.headline)
                            Text(status(entry)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("trip.status." + video.id)
                            if let entry {
                                if ["准备资料", "等待下载", "下载中", "校验中"].contains(entry.state) { ProgressView(value: entry.progress) }
                                if let overview = entry.overview, !overview.isEmpty { Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                if let message = entry.message { Text(message).font(.caption).foregroundStyle(.orange) }
                                if let issues = downloads.checked(entry) ? entry.checkedIssues : entry.resourceWarnings, !issues.isEmpty { Text(issues.joined(separator: "\n")).font(.caption).foregroundStyle(.orange) }
                                HStack {
                                    if entry.state == "已完成" {
                                        Button("播放") { play(from: entry.id) }.frame(minHeight: 44)
                                        Button("重新准备资料") { Task {
                                            do { try await downloads.refreshCompanions(entry.id, library: library) }
                                            catch { messages = [error.localizedDescription] }
                                        } }.frame(minHeight: 44)
                                    } else if ["等待下载", "下载中"].contains(entry.state) {
                                        Button("暂停") { Task { await downloads.pause(entry.id) } }.frame(minHeight: 44)
                                    } else if ["已暂停", "已中断", "下载失败", "文件已移除"].contains(entry.state) {
                                        Button("继续／重试") { Task { await downloads.resume(entry.id, library: library) } }.frame(minHeight: 44)
                                    }
                                }.buttonStyle(.borderless)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Section {
                    Button("清理行程包", role: .destructive) { confirmingRemoval = true }.disabled(queueing)
                }
            } else { ContentUnavailableView("行程包已移除", systemImage: "suitcase") }
        }.navigationTitle(trip?.name ?? "行程包").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $checking) { if let trip { OfflineTripCheckView(library: library, trip: trip) } }
            .fullScreenCover(item: $playing) { selection in PlayerView(library: library, queue: selection.queue, scopeName: trip?.name ?? "随身片库", cinematic: true) }
            .confirmationDialog("清理行程包", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("只移除行程包") { remove(files: false) }
                Button("移除并清理本机副本", role: .destructive) { remove(files: true) }
                Button("取消", role: .cancel) { }
            } message: { Text("其他行程包共用的文件会保留。服务器与原始本地文件不会被删除。") }
    }
    private func status(_ entry: OfflineDownload?) -> String {
        guard let entry else { return "等待准备" }
        if entry.state != "已完成" { return entry.state }
        let issues = downloads.checked(entry) ? entry.checkedIssues : entry.resourceWarnings
        if !(issues ?? []).isEmpty { return "已下载 · 配套资料需处理" }
        return downloads.checked(entry) ? "已通过离线检查" : "已下载 · 待离线检查"
    }
    private func play(from id: String?) {
        guard let id else { return }
        let videos = completed.compactMap { try? downloads.offlineVideo($0.id) }
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        playing = PlaySelection(queue: PlaybackQueue(videos: Array(videos[index...]), mode: .sequential), scopeName: trip?.name ?? "离线播放")
    }
    private func remove(files: Bool) {
        do { try store.remove(tripID, includingFiles: files); dismiss() }
        catch { messages = [error.localizedDescription] }
    }
}

struct OfflineTripCheckView: View {
    var library: LibraryStore
    let trip: OfflineTrip
    @State private var playback = PlaybackController()
    @State private var reports: [String: String] = [:]
    @State private var finished = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VideoSurface(presentation: playback.presentation, onLayer: playback.attachLayer, identity: playback.current?.id ?? "check", title: playback.current?.title ?? "离线检查", frameReady: playback.frameReady, locked: true, filled: false, onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in }, subtitleSession: playback.subtitles, secondarySubtitleSession: playback.secondarySubtitles, subtitleClock: { playback.subtitleRenderTime })
                        .frame(height: 150).listRowInsets(EdgeInsets())
                    Text(finished ? "检查完成" : "正在使用本机文件静音试播…").accessibilityIdentifier("trip.check.state")
                    if finished { Text("已通过 \(reports.values.filter { $0 == "已通过离线检查" }.count) / \(trip.videos.count)").accessibilityIdentifier("trip.check.summary") }
                    Text("播放链路禁止联网。检查确认出画面、时间推进与已保存资料，无法保证整部影片每个位置都可解码。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(trip.videos) { video in
                        LabeledContent(video.title, value: reports[video.id] ?? "等待检查").font(.subheadline)
                    }
                }
            }.navigationTitle("出发前检查").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(finished ? "完成" : "停止") { playback.stop(); dismiss() } } }
                .task { await inspect() }.onDisappear { playback.stop() }
        }
    }
    private func inspect() async {
        playback.inspectionMode = true
        for video in trip.videos {
            guard !Task.isCancelled else { return }
            do {
                let local = try DownloadStore.shared.offlineVideo(video.id)
                reports[video.id] = "正在试播"
                playback.open(local, library: library, resumeAt: 0, recordsProgress: false)
                let deadline = Date().addingTimeInterval(25)
                while !Task.isCancelled, playback.error == nil, Date() < deadline, !(playback.frameReady && playback.time >= 0.25) {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard playback.error == nil, playback.frameReady, playback.time >= 0.25 else { throw MediaError.message(playback.error ?? "未能确认出画面，请手动试播此文件。") }
                let issues = try await DownloadStore.shared.recordPlaybackCheck(video.id, engine: playback.engineDescriptor.id)
                reports[video.id] = issues.isEmpty ? "已通过离线检查" : "已出画面；" + issues.joined(separator: "；")
            } catch { reports[video.id] = error.localizedDescription }
            playback.stop()
        }
        finished = true
    }
}
