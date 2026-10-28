import SwiftUI

struct ClipEditorView: View {
    var library: LibraryStore
    var store: ClipStore
    // The incoming clip seeds a new editing session; subsequent edits are local until Save.
    @State private var draft: MediaClip
    @State private var collectionID: UUID?
    @FocusState private var nameFocused: Bool
    @State private var newName = "精彩片段"
    @State private var preview: ClipPlaybackSelection?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @MainActor init(library: LibraryStore, store: ClipStore? = nil, clip: MediaClip) {
        self.library = library; let selectedStore = store ?? .shared; self.store = selectedStore; _draft = State(initialValue: clip)
        _collectionID = State(initialValue: selectedStore.snapshot.collections.first(where: { $0.clipIDs.contains(clip.id) })?.id ?? selectedStore.snapshot.collections.first?.id)
    }
    private var valid: Bool { (try? draft.validated()) != nil }
    var body: some View {
        NavigationStack {
            Form {
                Section("片段名称") { TextField("例如：山顶日落", text: $draft.moment.name).focused($nameFocused).submitLabel(.done).onSubmit { nameFocused = false }.accessibilityIdentifier("clip.name") }
                Section {
                    ClipArtwork(clip: draft, library: library).aspectRatio(16 / 9, contentMode: .fit).clipShape(.rect(cornerRadius: 10))
                    Text(draft.moment.video.title).font(.subheadline)
                    VStack(alignment: .leading) {
                        Text("起点 · " + draft.moment.position.mediaTime).monospacedDigit()
                        Slider(value: $draft.moment.position, in: 0...max(0.5, draft.moment.duration - 0.5), step: 0.1).accessibilityIdentifier("clip.startSlider")
                        HStack {
                            Button("起点 −1 秒") { draft.moment.position = max(0, draft.moment.position - 1) }
                            Spacer(); Button("起点 +1 秒") { draft.moment.position = min(draft.moment.duration - 0.5, draft.moment.position + 1) }
                        }.font(.caption).buttonStyle(.borderless)
                    }
                    VStack(alignment: .leading) {
                        Text("终点 · " + draft.end.mediaTime).monospacedDigit()
                        Slider(value: $draft.end, in: 0.5...max(0.5, draft.moment.duration), step: 0.1).accessibilityIdentifier("clip.endSlider")
                        HStack {
                            Button("终点 −1 秒") { draft.end = max(0.5, draft.end - 1) }
                            Spacer(); Button("终点 +1 秒") { draft.end = min(draft.moment.duration, draft.end + 1) }
                        }.font(.caption).buttonStyle(.borderless)
                    }
                    if valid { LabeledContent("片段时长", value: draft.length.mediaTime) }
                    else { Text("终点需晚于起点至少 0.5 秒。").font(.footnote).foregroundStyle(.red) }
                    Button("预览此片段", systemImage: "play.circle") {
                        do { preview = ClipPlaybackSelection(clips: [try draft.validated()]) } catch { self.error = error.localizedDescription }
                    }.disabled(!valid).accessibilityIdentifier("clip.preview")
                } header: { Text("选取区间") } footer: { Text("滑动调整范围，可用按钮按秒微调；预览只播放所选区间。") }
                Section("保存到合集") {
                    Picker("合集", selection: $collectionID) {
                        Text("新建合集").tag(UUID?.none)
                        ForEach(store.snapshot.collections) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if collectionID == nil { TextField("新合集名称", text: $newName).accessibilityIdentifier("clip.collectionName") }
                    Text("只保存文件版本和时间范围，不复制或修改原视频。片段回看进度单独保存。").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("收藏精彩片段").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { nameFocused = false } }
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        do { try store.save(draft, to: collectionID, newName: collectionID == nil ? newName : nil); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(!valid).accessibilityIdentifier("clip.save") }
                }
                .fullScreenCover(item: $preview) { ClipPlaybackView(library: library, store: store, selection: $0, preview: true) }
                .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
        }
    }
}

struct ClipPlaybackView: View {
    var library: LibraryStore
    var store: ClipStore
    var selection: ClipPlaybackSelection
    var preview = false
    @State private var index: Int
    @State private var resolvedClipID: UUID?
    @State private var video: Video?
    @State private var error: String?
    @State private var finished = false
    @State private var resume: Double?
    @State private var lastPosition: Double = 0
    @State private var fullVideo: MomentPlayback?
    @State private var epoch = 0
    @Environment(\.dismiss) private var dismiss
    @MainActor init(library: LibraryStore, store: ClipStore? = nil, selection: ClipPlaybackSelection, preview: Bool = false) {
        self.library = library; let selectedStore = store ?? .shared; self.store = selectedStore; self.selection = selection; self.preview = preview
        _index = State(initialValue: min(max(0, selection.index), max(0, selection.clips.count - 1)))
        _resume = State(initialValue: selection.resume)
    }
    private var clip: MediaClip? { selection.clips.indices.contains(index) ? selection.clips[index] : nil }
    var body: some View {
        ZStack {
            if let selected = fullVideo {
                PlayerView(library: library, queue: PlaybackQueue(videos: [selected.video], mode: .sequential),
                           initialTracks: TrackSelection(mediaSourceID: selected.moment.reference.mediaSourceID), initialResumeAt: selected.moment.position,
                           initialMoment: selected.moment, returnLabel: "返回精彩片段",
                           onExit: { resume = lastPosition; fullVideo = nil; epoch += 1 }).id(selected.id)
            } else if let clip {
                if finished {
                    VStack(spacing: 20) {
                        Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.tint)
                        Text(preview ? "预览完成" : "合集已刷完").font(.title3.bold())
                        Button(preview ? "再看一次" : "从第一段重新播放") { index = 0; resume = nil; finished = false; epoch += 1 }
                        Button("完成") { dismiss() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(GlideTheme.background)
                } else if let video, resolvedClipID == clip.id {
                    PlayerView(library: library, queue: PlaybackQueue(videos: [video], mode: .sequential), scopeName: "精彩片段集",
                               initialTracks: TrackSelection(mediaSourceID: clip.moment.reference.mediaSourceID), initialResumeAt: clip.resume(resume), initialMoment: clip.moment,
                               returnLabel: preview ? "返回片段编辑" : "返回片段集", clip: clip,
                               clipPosition: "片段 \(index + 1) / \(selection.clips.count) · " + clip.moment.name,
                               clipCanGoBack: index > 0, clipCanGoForward: index + 1 < selection.clips.count,
                               onClipMove: { move($0) }, onClipCompleted: complete,
                               onClipProgress: { position in record(clip, position: position) },
                               onFullVideo: preview ? nil : { position in
                                   record(clip, position: position)
                                   fullVideo = MomentPlayback(video: video, moment: MediaMoment(video: clip.moment.video, reference: clip.moment.reference, position: min(position, clip.moment.duration - 0.01), duration: clip.moment.duration, name: clip.moment.name))
                               }).id("\(clip.id):\(epoch)")
                } else {
                    VStack(spacing: 18) {
                        if let error { Image(systemName: "exclamationmark.triangle"); Text(error).font(.subheadline).multilineTextAlignment(.center); Button("重试") { epoch += 1 } }
                        else { ProgressView("正在确认原文件…") }
                        if index + 1 < selection.clips.count { Button("跳过此片段") { move(1) } }
                        Button("返回片段集") { dismiss() }
                    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(GlideTheme.background)
                }
            } else { ContentUnavailableView("没有可播放的片段", systemImage: "scissors").onAppear { dismiss() } }
        }
        .task(id: "\(index):\(epoch)") {
            video = nil; resolvedClipID = nil; error = nil
            guard let clip else { return }
            do {
                _ = try clip.validated(); video = try MomentResolver.resolve(clip.moment, library: library); resolvedClipID = clip.id
                lastPosition = clip.resume(resume)
                try store.record(collectionID: selection.collectionID, clipID: clip.id, position: lastPosition)
            } catch { self.error = error.localizedDescription }
        }
        .overlay(alignment: .top) {
            if error != nil, video != nil { Text(error ?? "").font(.caption).padding().background(.regularMaterial).padding() }
        }
    }
    private func record(_ expected: MediaClip, position: Double) {
        guard clip?.id == expected.id, !finished, position.isFinite else { return }
        lastPosition = expected.resume(position)
        do { try store.record(collectionID: selection.collectionID, clipID: expected.id, position: position) }
        catch { self.error = "浏览进度未能保存：" + error.localizedDescription }
    }
    private func move(_ delta: Int) {
        let next = index + delta
        guard selection.clips.indices.contains(next) else { return }
        resume = nil; index = next; epoch += 1
    }
    private func complete() {
        guard let clip else { return }
        if index + 1 < selection.clips.count { move(1) }
        else {
            do { try store.record(collectionID: selection.collectionID, clipID: clip.id, position: clip.end, finished: true) }
            catch { self.error = "浏览进度未能保存：" + error.localizedDescription }
            finished = true
        }
    }
}
