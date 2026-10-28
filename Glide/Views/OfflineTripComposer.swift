import SwiftUI

struct OfflineTripComposer: View {
    var library: LibraryStore
    var initialScopes: [DiscoveryScope] = []
    @Environment(\.dismiss) private var dismiss
    @State private var name = "我的旅程"
    @State private var hours = 4
    @State private var gigabytes = 8
    @State private var episodeCount = 3
    @State private var byEpisodes = false
    @State private var scopes: [DiscoveryScope] = []
    @State private var channelID: UUID?
    @State private var showScopes = false
    @State private var result: OfflineTripResolver.Result?
    @State private var excluded = Set<String>()
    @State private var loading = false
    @State private var count = 0
    @State private var error: String?
    @State private var work: Task<Void, Never>?
    @State private var creating = false
    @FocusState private var editingName: Bool
    @State private var store = OfflineTripStore.shared
    @State private var channels = DiscoveryStore.shared
    private var channel: PrivateChannel? { channels.channels.first { $0.id == channelID } }
    private var byteLimit: Int64 { Int64(gigabytes) * 1024 * 1024 * 1024 }
    private var plan: OfflineTripPlanner.Plan {
        let values = result?.candidates ?? []
        return byEpisodes ? OfflineTripPlanner.episodes(values, count: episodeCount, bytes: byteLimit) : OfflineTripPlanner.plan(values, seconds: Double(hours * 3600), bytes: byteLimit)
    }
    private var selected: [OfflineTripCandidate] { plan.items.filter { !excluded.contains($0.id) } }
    var body: some View {
        NavigationStack {
            Form {
                Section("出发前，准备好想看的") {
                    TextField("行程名称", text: $name).focused($editingName).submitLabel(.done).onSubmit { editingName = false }
                        .frame(minHeight: 44).accessibilityIdentifier("trip.name")
                    Toggle("连续剧打包", isOn: $byEpisodes).accessibilityIdentifier("trip.episodes")
                    if byEpisodes {
                        Picker("接下来的集数", selection: $episodeCount) { Text("3 集").tag(3); Text("5 集").tag(5) }
                        Text("请选择一部剧的范围。按季集顺序打包，跳过明确已看完的集数。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Stepper("观看时间：\(hours) 小时", value: $hours, in: 1...24)
                    }
                    Stepper("容量上限：\(gigabytes) GB", value: $gigabytes, in: 1...64)
                }
                Section("从哪里挑选") {
                    Picker("私人频道", selection: $channelID) {
                        Text("手动选择范围").tag(Optional<UUID>.none)
                        ForEach(channels.channels) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(loading)
                    if channel == nil {
                        Button("选择片库或目录", systemImage: "rectangle.stack") { showScopes = true }.disabled(loading)
                        Text(scopes.map(\.name).joined(separator: "、").isEmpty ? "支持本地、Jellyfin 和 Emby" : scopes.map(\.name).joined(separator: "、"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        work?.cancel(); loading = true; error = nil; result = nil; excluded = []
                        let selectedScopes = channel?.scopes ?? scopes, selectedChannel = channel
                        work = Task {
                            defer { loading = false }
                            do {
                                guard !selectedScopes.isEmpty else { throw MediaError.message("请先选择内容范围。") }
                                result = try await OfflineTripResolver.candidates(scopes: selectedScopes, channel: selectedChannel, library: library) { count = $0 }
                            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                        }
                    } label: { Label(result == nil ? "生成候选" : "重新生成候选", systemImage: "sparkles") }
                        .disabled(loading || creating).accessibilityIdentifier("trip.generate")
                    if loading { ProgressView("正在检查片长和大小 · \(count)") }
                }
                if let error { Section { Text(error).foregroundStyle(.orange).accessibilityIdentifier("trip.error") } }
                if result != nil {
                    Section {
                        LabeledContent("已选 \(selected.count) 个", value: selected.reduce(0) { $0 + $1.remaining }.mediaTime)
                        LabeledContent("视频容量", value: ByteCountFormatter.string(fromByteCount: selected.reduce(0) { $0 + $1.bytes }, countStyle: .file))
                        Text("容量按完整原文件计算，字幕和封面另占少量空间。已有下载直接复用；确认后才开始准备。").font(.caption).foregroundStyle(.secondary)
                        if plan.items.isEmpty { Text("当前预算内没有合适内容，可增加时间或容量，或调整范围。").foregroundStyle(.secondary) }
                        ForEach(plan.items) { candidate in
                            Button {
                                if excluded.contains(candidate.id) { excluded.remove(candidate.id) } else { excluded.insert(candidate.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: excluded.contains(candidate.id) ? "circle" : "checkmark.circle.fill")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(candidate.video.title).foregroundStyle(.primary)
                                        Text("\(candidate.remaining.mediaTime) · \(ByteCountFormatter.string(fromByteCount: candidate.bytes, countStyle: .file))" + (candidate.alreadySaved ? " · 复用已下载" : ""))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(minHeight: 44)
                            }.accessibilityIdentifier("trip.candidate." + candidate.id)
                        }
                    } header: { Text("确认行程内容") }
                    if let notices = result?.notices, !notices.isEmpty {
                        Section { DisclosureGroup("未纳入的内容 · \(notices.count)") { ForEach(Array(notices.prefix(30)), id: \.self) { Text($0).font(.caption) } } }
                    }
                }
            }.navigationTitle("创建行程包").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { work?.cancel(); dismiss() }.disabled(creating) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("准备行程包") { create() }.disabled(selected.isEmpty || loading || creating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("trip.confirm")
                    }
                }
                .sheet(isPresented: $showScopes) { DiscoveryScopePicker(library: library, selected: scopes) { scopes = $0; result = nil } }
                .task { if scopes.isEmpty { scopes = initialScopes.isEmpty ? [DiscoveryResolver.current(library)] : initialScopes } }
                .onChange(of: channelID) { result = nil }
                .onDisappear { work?.cancel() }
        }.interactiveDismissDisabled(creating)
    }
    private func create() {
        var trip = OfflineTrip(name: name, videoIDs: selected.map(\.id), targetSeconds: Double(hours * 3600), maximumBytes: byteLimit)
        trip.videos = selected.map { PersonalVideo(video: $0.video).video }
        trip.expectedSizes = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.fileBytes ?? $0.bytes) })
        trip.sourceVersions = Dictionary(uniqueKeysWithValues: selected.compactMap { value in value.sourceVersionID.map { (value.id, $0) } })
        trip.accountBindings = result?.bindings ?? [:]
        do {
            try store.save(trip)
            store.start(trip, library: library)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
