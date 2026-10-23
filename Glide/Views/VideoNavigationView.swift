import SwiftUI

struct VideoNavigationPresentation: Identifiable {
    var id = UUID()
    var video: Video
    var resource: PlaybackResource
    var duration: Double
    var position: Double
    var createMoment = false
}

struct VideoNavigationView: View {
    var library: LibraryStore
    var selection: VideoNavigationPresentation
    var store: MomentStore
    var onSelect: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var session = VideoNavigationSession()
    @State private var mode = 0
    @State private var ranges: [MapSegment] = []
    @State private var editing: MediaMoment?
    @State private var error: String?
    @State private var saving = false
    @State private var reload = 0
    private var matchingMoments: [MediaMoment] { store.moments.filter { $0.video.id == selection.video.id && $0.reference == session.reference }.sorted { $0.position < $1.position } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selection.video.title).font(.headline).lineLimit(2)
                        Text("\(selection.duration.mediaTime) · 当前 \(selection.position.mediaTime)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Picker("视频导航", selection: $mode) {
                        Text("内容地图").tag(0); Text("章节").tag(1); Text("时刻").tag(2)
                    }.pickerStyle(.segmented).accessibilityIdentifier("map.mode")
                    if !session.ready { ProgressView("正在准备导航…").frame(maxWidth: .infinity).padding() }
                    else if mode == 0 { mapContent }
                    else if mode == 1 { chapterContent }
                    else { momentContent }
                }.padding()
            }.background(GlideTheme.background)
                .navigationTitle("画面与时刻").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("清理内容地图缓存", systemImage: "trash") {
                                Task { do { try await ContentMapCache.shared.clear(); reload += 1 } catch { self.error = error.localizedDescription } }
                            }
                            Text("缩略图缓存上限 64 MB")
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("内容地图选项")
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("map.done") }
                }
                .safeAreaInset(edge: .bottom) {
                    Button { Task { await createMoment() } } label: {
                        Label("收藏当前时刻 · " + selection.position.mediaTime, systemImage: "bookmark")
                            .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.borderedProminent).disabled(!session.ready || saving)
                        .accessibilityIdentifier("map.saveMoment").padding(.horizontal).padding(.vertical, 8).background(.bar)
                }
                .sheet(item: $editing) { moment in MomentEditorView(store: store, draft: moment) }
                .alert("暂时无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
                .task {
                    await session.prepare(video: selection.video, library: library, resource: selection.resource, duration: selection.duration)
                    if selection.createMoment, !Task.isCancelled { mode = 2; await createMoment() }
                }
                .onDisappear { session.cancel() }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
    @ViewBuilder private var mapContent: some View {
        Text(session.status).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("map.status")
        if session.hasMap {
            if let range = ranges.last {
                HStack {
                    Button("返回上一层", systemImage: "chevron.left") { ranges.removeLast() }.accessibilityIdentifier("map.zoom.back")
                    Spacer()
                    Text(range.start.mediaTime + "–" + range.end.mediaTime).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 18) {
                ForEach(Array(ContentMapPlan.segments(duration: selection.duration, range: ranges.last).enumerated()), id: \.element.id) { index, segment in
                    ContentMapCell(session: session, segment: segment, index: index, reload: reload, canRefine: ranges.count < 3 && segment.end - segment.start > 0.5,
                                   onSelect: play, onRefine: { ranges.append(segment) })
                }
            }.id("\(ranges.last?.id ?? "all"):\(reload)")
        } else {
            ContentUnavailableView("暂无内容地图", systemImage: "rectangle.split.3x3", description: Text("本地与离线视频按需取图；Jellyfin 需要服务器已生成当前版本的 Trickplay 缩略图。"))
        }
    }
    @ViewBuilder private var chapterContent: some View {
        if session.chapters.isEmpty {
            ContentUnavailableView("暂无章节", systemImage: "list.bullet.rectangle", description: Text("视频或来源尚未提供当前版本的章节信息。"))
        } else {
            ForEach(session.chapters) { chapter in
                Button { play(chapter.time) } label: {
                    HStack {
                        Image(systemName: "play.circle")
                        Text(chapter.name).lineLimit(2)
                        Spacer(); Text(chapter.time.mediaTime).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }.frame(minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("map.chapter." + chapter.id)
                Divider()
            }
        }
    }
    @ViewBuilder private var momentContent: some View {
        if matchingMoments.isEmpty { ContentUnavailableView("还没有收藏时刻", systemImage: "bookmark", description: Text("保存当前位置并起个名字，下次直接回到这一段。")) }
        ForEach(matchingMoments) { moment in
            Button { play(moment.position) } label: {
                HStack { Image(systemName: "bookmark.fill"); Text(moment.name); Spacer(); Text(moment.position.mediaTime).font(.caption).monospacedDigit() }
                    .frame(minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain).contextMenu {
                Button("重命名", systemImage: "pencil") { editing = moment }
                Button("删除时刻", systemImage: "trash", role: .destructive) { do { try store.remove(moment.id) } catch { self.error = error.localizedDescription } }
            }.accessibilityIdentifier("map.moment." + moment.id.uuidString)
        }
    }
    private func play(_ time: Double) { onSelect(time); dismiss() }
    @MainActor private func createMoment() async {
        saving = true; defer { saving = false }
        do {
            let reference: MomentReference
            if let prepared = session.reference { reference = prepared }
            else { reference = try await MomentResolver.reference(video: selection.video, library: library, resource: selection.resource) }
            try Task.checkCancellation()
            let video = try MomentResolver.storedVideo(selection.video, library: library)
            editing = try MediaMoment(video: video, reference: reference, position: selection.position, duration: selection.duration, name: "").validated()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct ContentMapCell: View {
    var session: VideoNavigationSession
    var segment: MapSegment
    var index: Int
    var reload: Int
    var canRefine: Bool
    var onSelect: (Double) -> Void
    var onRefine: () -> Void
    @State private var frame: ContentMapFrame?
    @State private var failed = false
    @State private var retry = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if let frame { onSelect(frame.time) } else if failed { retry += 1 }
            } label: {
                Color.black.opacity(0.08).aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if let frame { Image(uiImage: frame.image).resizable().scaledToFit() }
                        else if failed { Label("重试预览", systemImage: "arrow.clockwise").font(.caption) }
                        else { ProgressView() }
                    }.clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(frame == nil && !failed)
                .accessibilityLabel(frame == nil ? failed ? "重试画面预览" : "正在读取画面" : "从 \((frame?.time ?? segment.start).mediaTime) 播放")
                .accessibilityIdentifier("map.frame.\(index)")
            HStack {
                Text((frame?.time ?? segment.start).mediaTime).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if canRefine { Button(action: onRefine) { Image(systemName: "plus.magnifyingglass").frame(width: 44, height: 44).contentShape(Rectangle()) }.buttonStyle(.plain)
                    .accessibilityLabel("细看 " + segment.start.mediaTime + " 到 " + segment.end.mediaTime).accessibilityIdentifier("map.zoom.\(index)") }
            }.frame(minHeight: 44)
        }.task(id: "\(segment.id):\(retry):\(reload)") {
            frame = nil; failed = false
            do { let value = try await session.frame(at: segment.start); try Task.checkCancellation(); frame = value }
            catch is CancellationError {} catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct MomentEditorView: View {
    var store: MomentStore
    @State var draft: MediaMoment
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("时刻名称") { TextField("给这个时刻起个名字", text: $draft.name).accessibilityIdentifier("moment.name") }
                Section {
                    LabeledContent("视频", value: draft.video.title)
                    LabeledContent("位置", value: draft.position.mediaTime)
                    Text("保存此视频版本与时间点，可在“我的 → 时刻收藏”再次打开。").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("收藏时刻").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { do { try store.save(draft); dismiss() } catch { self.error = error.localizedDescription } }.accessibilityIdentifier("moment.save") }
                }
                .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
        }.presentationDetents([.medium, .large])
    }
}
