import SwiftUI

struct MomentPlayback: Identifiable { var id = UUID(); var video: Video; var moment: MediaMoment }

struct MomentLibraryView: View {
    var library: LibraryStore
    var store = MomentStore.shared
    @State private var query = ""
    @State private var editing: MediaMoment?
    @State private var playing: MomentPlayback?
    @State private var error: String?
    private var entries: [MediaMoment] {
        store.moments.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.video.title.localizedStandardContains(query) }
    }
    var body: some View {
        List {
            if let message = store.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if entries.isEmpty {
                ContentUnavailableView(query.isEmpty ? "还没有时刻收藏" : "没有匹配的时刻", systemImage: "bookmark", description: Text("播放时打开“画面与时刻”，收藏当前位置。"))
            }
            ForEach(entries) { moment in
                Button {
                    do { playing = MomentPlayback(video: try MomentResolver.resolve(moment, library: library), moment: moment) }
                    catch { self.error = error.localizedDescription }
                } label: {
                    HStack(spacing: 14) {
                        VStack(spacing: 5) {
                            Image(systemName: "bookmark.fill").font(.title3)
                            Text(moment.position.mediaTime).font(.caption).monospacedDigit()
                        }.foregroundStyle(GlideTheme.accent).frame(width: 70, height: 64).background(GlideTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(moment.name).font(.headline).lineLimit(2)
                            Text(moment.video.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            Text(sourceName(moment)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0); Image(systemName: "play.fill").foregroundStyle(GlideTheme.accent)
                    }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("moments.item." + moment.id.uuidString)
                    .contextMenu {
                        Button("重命名", systemImage: "pencil") { editing = moment }
                        Button("删除时刻", systemImage: "trash", role: .destructive) { remove(moment) }
                    }
                    .swipeActions(edge: .trailing) { Button("删除", role: .destructive) { remove(moment) }; Button("重命名") { editing = moment }.tint(.blue) }
            }.onDelete { indices in indices.map { entries[$0] }.forEach(remove) }
        }.navigationTitle("时刻收藏").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索时刻名称或视频")
            .toolbar { EditButton().disabled(entries.isEmpty) }
            .sheet(item: $editing) { moment in MomentEditorView(store: store, draft: moment) }
            .fullScreenCover(item: $playing) { selection in
                PlayerView(library: library, queue: PlaybackQueue(videos: [selection.video], mode: .sequential), scopeName: "时刻收藏",
                           initialTracks: TrackSelection(mediaSourceID: selection.moment.reference.mediaSourceID), initialResumeAt: selection.moment.position,
                           initialMoment: selection.moment, momentStore: store, returnLabel: "返回时刻收藏")
            }
            .alert("无法打开时刻", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
    private func sourceName(_ moment: MediaMoment) -> String {
        if moment.reference.kind == .demo { return "离线演示" }
        return library.servers.first(where: { moment.reference.matches($0) })?.name ?? "原来源不可用"
    }
    private func remove(_ moment: MediaMoment) { do { try store.remove(moment.id) } catch { self.error = error.localizedDescription } }
}
