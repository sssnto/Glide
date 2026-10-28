import SwiftUI
import AVFoundation

struct ClipPlaybackSelection: Identifiable {
    var id = UUID()
    var clips: [MediaClip]
    var index = 0
    var collectionID: UUID?
    var resume: Double?
}

struct ClipLibraryView: View {
    var library: LibraryStore
    var store = ClipStore.shared
    @State private var query = ""
    @State private var creating = false
    @State private var name = ""
    @State private var editing: MediaClip?
    @State private var playing: ClipPlaybackSelection?
    @State private var error: String?
    private var clips: [MediaClip] { store.snapshot.clips.filter { query.isEmpty || $0.moment.name.localizedStandardContains(query) || $0.moment.video.title.localizedStandardContains(query) } }
    var body: some View {
        List {
            if let message = store.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if store.snapshot.clips.isEmpty {
                ContentUnavailableView("把喜欢的那一段留下来", systemImage: "scissors", description: Text("播放视频时，在播放设置中选择“收藏精彩片段”。也可以从时刻收藏补充终点。"))
            }
            Section("我的合集") {
                ForEach(store.snapshot.collections.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { collection in
                    NavigationLink { ClipCollectionView(library: library, store: store, collectionID: collection.id) } label: {
                        HStack(spacing: 12) {
                            if let cover = store.snapshot.entries(collection).first(where: { $0.id == collection.coverID }) ?? store.snapshot.entries(collection).first {
                                ClipArtwork(clip: cover, library: library).frame(width: 88, height: 56).clipShape(.rect(cornerRadius: 8))
                            } else { Image(systemName: "rectangle.stack").frame(width: 88, height: 56).background(.quaternary, in: .rect(cornerRadius: 8)) }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(collection.name).font(.headline).lineLimit(2)
                                Text("\(collection.clipIDs.count) 个片段").font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(minHeight: 64)
                    }.accessibilityIdentifier("clips.collection." + collection.id.uuidString)
                }
                Button("新建合集", systemImage: "plus") { name = ""; creating = true }.accessibilityIdentifier("clips.createCollection")
            }
            Section("全部片段") {
                ForEach(clips) { clip in
                    Button { playing = ClipPlaybackSelection(clips: [clip]) } label: { ClipRow(clip: clip, library: library) }
                        .buttonStyle(.plain).accessibilityIdentifier("clips.item." + clip.id.uuidString)
                        .contextMenu {
                            Button("编辑／加入合集", systemImage: "pencil") { editing = clip }
                            Button("删除片段", systemImage: "trash", role: .destructive) { perform { try store.change { $0.removeClip(clip.id) } } }
                        }
                        .swipeActions { Button("编辑") { editing = clip }.tint(.blue) }
                }
            }
        }.navigationTitle("精彩片段集").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索片段、视频或合集")
            .alert("新建合集", isPresented: $creating) {
                TextField("合集名称", text: $name)
                Button("取消", role: .cancel) {}
                Button("创建") { perform {
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { throw MediaError.message("请填写合集名称。") }
                    try store.change { value in
                        guard value.collections.count < 100 else { throw MediaError.message("最多保存 100 个合集。") }
                        value.collections.insert(ClipCollection(name: String(title.prefix(80))), at: 0)
                    }
                } }
            }
            .sheet(item: $editing) { ClipEditorView(library: library, store: store, clip: $0) }
            .fullScreenCover(item: $playing) { ClipPlaybackView(library: library, store: store, selection: $0) }
            .alert("暂时无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
    private func perform(_ work: () throws -> Void) { do { try work() } catch { self.error = error.localizedDescription } }
}

struct ClipCollectionView: View {
    var library: LibraryStore
    var store: ClipStore
    var collectionID: UUID
    @State private var adding = false
    @State private var renaming = false
    @State private var deleting = false
    @State private var name = ""
    @State private var playing: ClipPlaybackSelection?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var collection: ClipCollection? { store.snapshot.collections.first { $0.id == collectionID } }
    private var clips: [MediaClip] { collection.map { store.snapshot.entries($0) } ?? [] }
    var body: some View {
        List {
            if let collection {
                Section {
                    if let cover = clips.first(where: { $0.id == collection.coverID }) ?? clips.first {
                        ClipArtwork(clip: cover, library: library).aspectRatio(16 / 9, contentMode: .fit).clipShape(.rect(cornerRadius: 12))
                    }
                    Text("\(clips.count) 个片段 · 合计 \(clips.reduce(0) { $0 + $1.length }.mediaTime)").font(.subheadline).foregroundStyle(.secondary)
                    Button(collection.cursor?.finished == true ? "重新刷看" : collection.cursor == nil ? "播放合集" : "接着刷") { play(resume: true) }
                        .disabled(clips.isEmpty).accessibilityIdentifier("clips.playCollection")
                    if collection.cursor != nil { Button("从第一段播放") { play(resume: false) }.disabled(clips.isEmpty) }
                }
                Section {
                    ForEach(clips) { clip in
                        Button {
                            playing = ClipPlaybackSelection(clips: clips, index: clips.firstIndex { $0.id == clip.id } ?? 0, collectionID: collectionID)
                        } label: { ClipRow(clip: clip, library: library) }.buttonStyle(.plain)
                            .accessibilityIdentifier("clips.entry." + clip.id.uuidString)
                            .accessibilityValue(collection.coverID == clip.id ? "合集封面" : "")
                            .contextMenu {
                                Button("上移", systemImage: "arrow.up") { shift(clip.id, by: -1) }.disabled(clips.first?.id == clip.id)
                                Button("下移", systemImage: "arrow.down") { shift(clip.id, by: 1) }.disabled(clips.last?.id == clip.id)
                                Button("设为合集封面", systemImage: "photo") { update { $0.coverID = clip.id } }
                                Button("从合集中移除", systemImage: "minus.circle", role: .destructive) { update { $0.clipIDs.removeAll { $0 == clip.id } } }
                            }
                    }.onMove { from, to in update { $0.clipIDs.move(fromOffsets: from, toOffset: to) } }
                        .onDelete { offsets in let ids = offsets.map { clips[$0].id }; update { $0.clipIDs.removeAll { ids.contains($0) } } }
                    Button("添加已有片段", systemImage: "plus") { adding = true }.accessibilityIdentifier("clips.addExisting")
                } header: { Text("片段顺序") } footer: { Text("播放到终点后进入下一段；移除条目保留片段与原视频。跨文件切换可能需要加载。") }
            } else { ContentUnavailableView("合集已删除", systemImage: "rectangle.stack") }
        }.navigationTitle(collection?.name ?? "合集").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("重命名", systemImage: "pencil") { name = collection?.name ?? ""; renaming = true }
                        Button("删除合集", systemImage: "trash", role: .destructive) { deleting = true }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("合集选项")
                }
            }
            .sheet(isPresented: $adding) {
                NavigationStack {
                    List(store.snapshot.clips.filter { !clips.map(\.id).contains($0.id) }) { clip in
                        Button { update { $0.clipIDs.append(clip.id) }; adding = false } label: { ClipRow(clip: clip, library: library) }
                    }.overlay { if store.snapshot.clips.allSatisfy({ clips.map(\.id).contains($0.id) }) { ContentUnavailableView("暂无其他片段", systemImage: "scissors") } }
                        .navigationTitle("添加片段").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { adding = false } } }
                }
            }
            .alert("重命名合集", isPresented: $renaming) { TextField("合集名称", text: $name); Button("取消", role: .cancel) {}; Button("保存") { update { $0.name = name } } }
            .confirmationDialog("删除此合集？片段和原视频会保留。", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除合集", role: .destructive) { do { try store.change { $0.collections.removeAll { $0.id == collectionID } }; dismiss() } catch { self.error = error.localizedDescription } }
            }
            .fullScreenCover(item: $playing) { ClipPlaybackView(library: library, store: store, selection: $0) }
            .alert("暂时无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
    private func shift(_ id: UUID, by delta: Int) {
        update { value in
            guard let i = value.clipIDs.firstIndex(of: id), value.clipIDs.indices.contains(i + delta) else { return }
            value.clipIDs.swapAt(i, i + delta)
        }
    }
    private func update(_ work: (inout ClipCollection) -> Void) {
        guard var value = collection else { return }; work(&value)
        do { try store.change { try $0.update(value) } } catch { self.error = error.localizedDescription }
    }
    private func play(resume: Bool) {
        guard !clips.isEmpty else { return }
        let cursor = resume ? collection?.cursor : nil
        let index = cursor?.finished == false ? clips.firstIndex { $0.id == cursor?.clipID } ?? 0 : 0
        playing = ClipPlaybackSelection(clips: clips, index: index, collectionID: collectionID, resume: cursor?.finished == false ? cursor?.position : nil)
    }
}

struct ClipRow: View {
    var clip: MediaClip
    var library: LibraryStore
    var body: some View {
        HStack(spacing: 12) {
            ClipArtwork(clip: clip, library: library).frame(width: 88, height: 56).clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.moment.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                Text(clip.moment.video.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(clip.moment.position.mediaTime + "–" + clip.end.mediaTime + " · " + clip.length.mediaTime).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 0); Image(systemName: "play.fill").font(.caption).foregroundStyle(.tint)
        }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).contentShape(Rectangle())
    }
}

struct ClipArtwork: View {
    var clip: MediaClip
    var library: LibraryStore
    @State private var image: UIImage?
    var body: some View {
        Color.black.opacity(0.08).overlay {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if clip.moment.reference.kind == .catalog,
                    let server = library.servers.first(where: { clip.moment.reference.matches($0) }), let id = clip.moment.video.remoteID {
                CatalogArtwork(item: CatalogItem(Id: id, Name: clip.moment.video.title, Type: clip.moment.video.mediaType), server: server)
            } else { Image(systemName: "play.rectangle").foregroundStyle(.secondary) }
        }.clipped().accessibilityHidden(true)
            .task(id: "\(clip.id):\(clip.moment.reference.revision):\(clip.moment.position)") {
                image = nil
                image = try? await ClipThumbnailLoader.image(clip, library: library)
            }
    }
}

@MainActor private enum ClipThumbnailLoader {
    static let cache: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.totalCostLimit = 16 * 1024 * 1024; c.countLimit = 100; return c }()
    static var active = 0
    static func image(_ clip: MediaClip, library: LibraryStore) async throws -> UIImage? {
        guard [.demo, .local, .offline].contains(clip.moment.reference.kind) else { return nil }
        let key = "\(clip.id):\(clip.moment.reference.revision):\(clip.moment.position)" as NSString
        if let value = cache.object(forKey: key) { return value }
        while active >= 2 { try await Task.sleep(for: .milliseconds(50)) }; try Task.checkCancellation()
        active += 1; defer { active -= 1 }
        let video = try MomentResolver.resolve(clip.moment, library: library)
        let server = library.servers.first { $0.id == video.sourceID }
        let resource = video.offlineOnly == true ? try DownloadStore.shared.offlineResource(video) : try await MediaClient.shared.playback(video: video, server: server, quality: .original, tracks: TrackSelection())
        defer { withExtendedLifetime(resource) {} }
        try await MomentResolver.verify(clip.moment.reference, video: video, library: library, resource: resource)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: resource.url)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 480, height: 320)
        let frame = try await withTaskCancellationHandler { try await generator.image(at: CMTime(seconds: clip.moment.position, preferredTimescale: 600)) } onCancel: { generator.cancelAllCGImageGeneration() }
        try Task.checkCancellation()
        let image = UIImage(cgImage: frame.image); cache.setObject(image, forKey: key, cost: frame.image.width * frame.image.height * 4); return image
    }
}
