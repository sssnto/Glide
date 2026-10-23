import SwiftUI

struct TimePickView: View {
    var library: LibraryStore
    var store: DiscoveryStore
    @State private var scopes: [DiscoveryScope]
    @State private var minutes = 45
    @State private var preference = ViewingPreference.any
    @State private var videos: [Video] = []
    @State private var excluded = Set<String>()
    @State private var loading = true
    @State private var count = 0
    @State private var error: String?
    @State private var note: String?
    @State private var retry = 0
    @State private var playing: DiscoveryPlayback?
    private enum Sheet: String, Identifiable { case scopes; var id: String { rawValue } }
    private struct LoadKey: Equatable { var scopes: [DiscoveryScope]; var retry: Int }
    @State private var sheet: Sheet?
    init(library: LibraryStore, store: DiscoveryStore) {
        self.library = library; self.store = store
        _scopes = State(initialValue: store.timeScopes.isEmpty ? [DiscoveryResolver.current(library)] : store.timeScopes)
    }
    private var picks: [TimePick] { TimePickPlanner.recommendations(videos, minutes: minutes, preference: preference, positions: [:], excluding: excluded) }
    private var unknownCount: Int { videos.filter { !$0.duration.isFinite || $0.duration <= 0 }.count }
    var body: some View {
        List {
            Section("现在有多少时间") {
                Picker("可用时间", selection: $minutes) {
                    Text("20 分钟").tag(20); Text("45 分钟").tag(45); Text("90 分钟").tag(90)
                    if ![20, 45, 90].contains(minutes) { Text("\(minutes) 分钟").tag(minutes) }
                }.pickerStyle(.segmented).accessibilityIdentifier("discovery.time.minutes")
                Stepper("自定义：\(minutes) 分钟", value: $minutes, in: 5...240, step: 5).accessibilityIdentifier("discovery.time.custom")
                Picker("想看什么", selection: $preference) {
                    ForEach(ViewingPreference.allCases) { value in Text(value.title).tag(value) }
                }.accessibilityIdentifier("discovery.time.preference")
            }
            Section {
                Button { sheet = .scopes } label: { LabeledContent("内容范围", value: "\(scopes.count) 个") }
                    .accessibilityIdentifier("discovery.time.scopes")
                Text(scopes.map(\.name).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
            }
            if loading { Section { ProgressView("正在挑选 · 已读取 \(count) 条").accessibilityIdentifier("discovery.loading") } }
            if let error { Section { Text(error).foregroundStyle(.secondary); Button("重新读取") { retry += 1 } } }
            if !loading && error == nil {
                Section {
                    if picks.isEmpty {
                        ContentUnavailableView("当前没有合适的内容", systemImage: "clock", description: Text("试试增加时间、更换类型或扩大内容范围。已看完及片长未知的内容不参与推荐。"))
                    }
                    ForEach(picks) { pick in
                        Button { playing = DiscoveryPlayback(videos: [pick.video], title: "给我选一部", resumeAt: pick.resumeAt) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                DiscoveryVideoRow(video: pick.video, library: library, detail: (pick.resumeAt > 1 ? "剩余 " : "片长 ") + pick.remaining.mediaTime)
                                Text(pick.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("discovery.pick." + pick.id)
                    }
                    if !picks.isEmpty {
                        Button("换一组", systemImage: "arrow.triangle.2.circlepath") {
                            let next = excluded.union(picks.map(\.id))
                            if TimePickPlanner.recommendations(videos, minutes: minutes, preference: preference, positions: [:], excluding: next).isEmpty {
                                excluded = []; note = "符合条件的候选数量有限，已重新展示。"
                            } else { excluded = next; note = nil }
                        }.accessibilityIdentifier("discovery.time.refresh")
                    }
                } header: { Text("为你挑选") } footer: { Text("根据片长、观看进度和类型挑选；优先继续未看完的内容，剧集保持剧情顺序。") }
                if unknownCount > 0 { Section { Text("\(unknownCount) 条内容缺少可靠片长，暂未参与推荐。NAS 视频可加入私人频道；本地文件每次最多读取 200 条片长。").font(.footnote).foregroundStyle(.secondary) } }
                if let note { Section { Text(note).font(.footnote).foregroundStyle(.secondary) } }
            }
        }.navigationTitle("给我选一部").navigationBarTitleDisplayMode(.inline)
            .task(id: LoadKey(scopes: scopes, retry: retry)) {
                loading = true; videos = []; excluded = []; error = nil; count = 0; note = nil
                do {
                    let batches = try await DiscoveryResolver.batches(scopes, library: library, readDurations: true) { count = $0 }
                    try Task.checkCancellation()
                    var seen = Set<String>(); videos = batches.flatMap(\.videos).filter { seen.insert($0.id).inserted }; loading = false
                } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
            }
            .onChange(of: minutes) { _, _ in excluded = []; note = nil }
            .onChange(of: preference) { _, _ in excluded = []; note = nil }
            .sheet(item: $sheet) { _ in DiscoveryScopePicker(library: library, selected: scopes) { values in
                do { try store.setTimeScopes(values); scopes = values } catch { self.error = error.localizedDescription }
            } }
            .fullScreenCover(item: $playing, onDismiss: { retry += 1 }) { selection in DiscoveryPlayer(library: library, selection: selection, store: store) }
    }
}
