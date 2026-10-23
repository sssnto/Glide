import SwiftUI
import UniformTypeIdentifiers

struct StreamLinkDraft: Identifiable {
    let id = UUID()
    var record: SavedStreamLink?
    var payload: StreamLinkPayload?
    var name = ""
}
struct StreamLinksView: View {
    var library: LibraryStore
    private var store: StreamLinkStore { .shared }
    @State private var draft: StreamLinkDraft?
    @State private var selection: PlaySelection?
    @State private var importing = false
    @State private var reading = false
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Button("打开视频链接", systemImage: "link.badge.plus") { draft = StreamLinkDraft() }
                    .accessibilityIdentifier("links.add")
                Button("导入 STRM 文件", systemImage: "doc.badge.arrow.up") { importing = true }
                    .accessibilityIdentifier("links.import")
                if reading { ProgressView("正在读取 STRM…") }
            }.disabled(reading)
            Section("已保存的链接") {
                if store.links.isEmpty {
                    ContentUnavailableView("还没有视频链接", systemImage: "link", description: Text("添加 HTTP(S) 地址，或导入只含一条地址的 STRM 文件。"))
                }
                ForEach(store.links) { record in
                    Button {
                        do {
                            _ = try store.payload(record.id)
                            selection = PlaySelection(queue: PlaybackQueue(videos: [record.video], mode: .sequential), scopeName: "链接播放", initialResumeAt: library.resumePosition(record.video))
                        } catch { self.error = error.localizedDescription }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "play.rectangle").font(.title2).foregroundStyle(GlideTheme.accent).frame(width: 44, height: 54)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.name).font(GlideTheme.Typography.itemTitle).foregroundStyle(.primary).lineLimit(2)
                                Text(record.host).font(GlideTheme.Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }.accessibilityIdentifier("links.video." + record.id.uuidString)
                    .swipeActions {
                        Button("删除", role: .destructive) { remove(record) }
                        Button("编辑") { draft = StreamLinkDraft(record: record) }.tint(.blue)
                    }
                    .contextMenu {
                        Button("编辑链接", systemImage: "pencil") { draft = StreamLinkDraft(record: record) }
                        Button("删除链接", systemImage: "trash", role: .destructive) { remove(record) }
                    }
                }
            }
            Section {
                Text("使用系统播放器；支持的编码取决于设备。带自定义请求头的 HLS 暂不支持。")
                Text("完整地址及请求头保存在此设备钥匙串中。链接过期时可编辑更新；删除链接同时清除对应本机记录。")
                if let message = store.message { Text(message).foregroundStyle(.orange) }
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("链接与 STRM").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(GlideTheme.background).tint(GlideTheme.accent)
        .navigationDestination(isPresented: Binding(get: { draft != nil }, set: { if !$0 { draft = nil } })) {
            if let draft { StreamLinkEditor(library: library, draft: draft).id(draft.id) }
        }
        .fullScreenCover(item: $selection) { item in
            PlayerView(library: library, queue: item.queue, scopeName: item.scopeName, cinematic: true, initialResumeAt: item.initialResumeAt)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "strm") ?? .data, .plainText]) { result in
            if case .success(let file) = result {
                reading = true
                Task {
                    defer { reading = false }
                    do {
                        let payload = try await StreamLinkStore.readSTRM(file)
                        draft = StreamLinkDraft(payload: payload, name: file.deletingPathExtension().lastPathComponent)
                    } catch { self.error = error.localizedDescription }
                }
            } else if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .alert("链接未能完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func remove(_ record: SavedStreamLink) {
        do { try store.remove(record, library: library) } catch { self.error = error.localizedDescription }
    }
}

private struct StreamLinkEditor: View {
    var library: LibraryStore
    let draft: StreamLinkDraft
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var headers = ""
    @State private var keepSettings = false
    @State private var error: String?
    var body: some View {
            Form {
                Section("视频链接") {
                    TextField("名称（可选）", text: $name).accessibilityIdentifier("links.name")
                    TextField("https://example.com/video.mp4", text: $address, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive().accessibilityIdentifier("links.address")
                    Text("仅接受 HTTP(S)。网站详情页不是视频地址；HTTP 仅用于可信局域网。").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("可选请求头") {
                        TextEditor(text: $headers).frame(minHeight: 120).font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().accessibilityIdentifier("links.headers")
                        Text("每行「名称: 值」，例如 User-Agent 或 Referer。最多 10 个；Range 等传输字段由播放器管理。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if draft.record != nil {
                    Section {
                        Toggle("更新地址时保留观看设置", isOn: $keepSettings).accessibilityIdentifier("links.keepSettings")
                        Text("地址或请求头变化时默认重新记录。仅确认仍是同一视频时，保留观看进度、字幕和跳过规则。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("links.error") } }
            }
            .font(GlideTheme.Typography.body)
            .navigationTitle(draft.record == nil ? "添加视频链接" : "编辑视频链接").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.accessibilityIdentifier("links.save").disabled(address.isEmpty) }
            }
            .onAppear {
                name = draft.record?.name ?? draft.name
                do {
                    let value = try draft.payload ?? draft.record.map { try StreamLinkStore.shared.payload($0.id) }
                    address = value?.url.absoluteString ?? ""
                    headers = value?.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n") ?? ""
                } catch { self.error = error.localizedDescription }
            }
        .tint(GlideTheme.accent)
    }
    private func save() {
        do {
            let value = try StreamLinkPayload.parse(address, headers: headers)
            let saved = try StreamLinkStore.shared.save(name: name, payload: value, replacing: draft.record?.id, keepIdentity: keepSettings)
            if let original = draft.record, original.video.id != saved.video.id {
                library.removeStreamLinkRecords(original.video.id)
                try? SubtitleSource.store.remove(videoID: original.video.id)
                try? PlaybackSkipSession.remove(videoID: original.video.id)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
