import SwiftUI

struct FileOperationPresentation: Identifiable {
    let id = UUID()
    let operation: FileOperation
    let videos: [Video]
}
private struct FileBatchReceipt: Identifiable {
    let batch: FileActionBatch
    var id: UUID { batch.id }
}
struct FileOperationComposer: View {
    let library: LibraryStore
    let server: MediaServer
    let operation: FileOperation
    let videos: [Video]
    @Environment(\.dismiss) private var dismiss
    @State private var inspection: [FileActionInspection] = []
    @State private var destination: FileDestination?
    @State private var choosingFolder = false
    @State private var loading = true
    @State private var submitting = false
    @State private var confirming = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var receipt: FileBatchReceipt?
    private var ready: Bool {
        !loading && !submitting && inspection.count == videos.count && inspection.allSatisfy { $0.errorCode == nil }
            && (operation != .move || destination != nil)
    }
    var body: some View {
        let lookup = Dictionary(inspection.map { ($0.itemId, $0) }, uniquingKeysWith: { first, _ in first })
        NavigationStack {
            List {
                Section {
                    Label(operation == .trash ? "原视频和同名外挂字幕将移入服务器回收目录，可从任务还原。" : "在 NAS 内移动原视频和同名外挂字幕，手机不下载、不上传。", systemImage: operation.symbol)
                        .font(.subheadline)
                    Text("同名文件不覆盖；一次最多 500 个。移动仅限同一媒体库根及磁盘。海报、NFO 和旧方向备份保留在原位置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if operation == .move {
                    Section("目标目录") {
                        Button { choosingFolder = true } label: {
                            HStack { Label(destination?.name ?? "选择目标目录", systemImage: "folder"); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                        }.accessibilityIdentifier("files.destination")
                    }
                }
                Section("已选 \(videos.count) 个视频") {
                    ForEach(videos) { video in
                        HStack(alignment: .top, spacing: 12) {
                            VideoPreviewArtwork(video: video, server: server).frame(width: 48, height: 68).clipShape(.rect(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 5) {
                                let check = video.remoteID.flatMap { lookup[$0] }
                                Text(check?.title.isEmpty == false ? check!.title : video.title).font(.subheadline).lineLimit(3)
                                if let code = check?.errorCode { Text(FileManagementFailure.message(code)).font(.caption).foregroundStyle(.orange) }
                                else if let check { Text("视频文件 · \(check.relatedFiles) 个外挂字幕").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.padding(.vertical, 3)
                    }
                }
                if loading { Section { ProgressView("核对原文件与权限…") } }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.orange)
                        if inspection.isEmpty { Button("重新核对") { Task { await prepare() } }.disabled(loading) }
                    }
                }
            }.navigationTitle(operation.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(submitting) } }
                .safeAreaInset(edge: .bottom) {
                    Button(submitting ? "正在提交…" : operation == .move ? "移动到此目录" : "删除到回收目录", role: operation == .trash ? .destructive : nil) { confirming = true }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: 44).padding().background(.bar)
                        .disabled(!ready).accessibilityIdentifier("files.confirm")
                }
        }.interactiveDismissDisabled(submitting)
            .task { await prepare() }
            .sheet(isPresented: $choosingFolder) { FileDestinationPicker(server: server, selection: $destination) }
            .confirmationDialog(operation == .move ? "移动这 \(videos.count) 个视频？" : "删除这 \(videos.count) 个原视频？", isPresented: $confirming, titleVisibility: .visible) {
                Button(operation == .move ? "在服务器移动" : "删除到服务器回收目录", role: .destructive) { Task { await submit() } }
            } message: { Text(operation == .move ? "目标：\(destination?.name ?? "")。同名不覆盖，失败项保留原文件。退出 Glide 后服务器继续处理。" : "原视频会从当前片库移走，仍占用 NAS 空间，不会永久清空。退出 Glide 后服务器继续处理。") }
            .sheet(item: $receipt, onDismiss: { dismiss() }) { value in
                NavigationStack { FileActionDetailView(library: library, server: server, initial: value.batch)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { receipt = nil } } }
                }
            }
    }
    private func prepare() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            _ = try await FileManagementClient(server: server).capability()
            inspection = try await FileManagementClient(server: server).inspect(videos)
        } catch { self.error = error.localizedDescription }
    }
    private func submit() async {
        guard ready else { return }; submitting = true; error = nil
        defer { submitting = false }
        do {
            let request = FileActionRequest(requestId: requestID, operation: operation, items: inspection.map(\.item), destinationId: destination?.id)
            let batch = try await library.fileActions.submit(request, server: server)
            receipt = FileBatchReceipt(batch: batch)
        } catch { self.error = error.localizedDescription }
    }
}

private struct FileDestinationPicker: View {
    let server: MediaServer
    @Binding var selection: FileDestination?
    @Environment(\.dismiss) private var dismiss
    @State private var path: [FileDestination] = []
    @State private var page: FileFolderPage?
    @State private var loading = false
    @State private var error: String?
    private var location: String { path.last?.id ?? "root" }
    var body: some View {
        NavigationStack {
            List {
                if !path.isEmpty { Section {
                    Button("上一级", systemImage: "chevron.left") { path.removeLast() }.disabled(loading)
                    Text(path.map(\.name).joined(separator: " › ")).font(.caption).foregroundStyle(.secondary)
                } }
                if let page {
                    ForEach(page.folders) { folder in
                        Button { path.append(folder) } label: { Label(folder.name, systemImage: "folder") }
                            .disabled(loading).accessibilityIdentifier("files.folder." + folder.id)
                    }
                    if page.nextIndex < page.total { Button("加载更多目录") { Task { await load(more: true) } }.disabled(loading) }
                    if page.folders.isEmpty && !loading { Text("此目录没有已入库的子目录").foregroundStyle(.secondary) }
                }
                if loading { ProgressView("读取目录…") }
                if let error { Text(error).font(.footnote).foregroundStyle(.orange); Button("重试") { Task { await load() } } }
            }.navigationTitle("移动到").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .safeAreaInset(edge: .bottom) {
                    Button("选择当前目录") { selection = page?.current; dismiss() }.buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, minHeight: 44).padding().background(.bar)
                        .disabled(loading || page?.current?.canChoose != true).accessibilityIdentifier("files.chooseDestination")
                }
        }.task(id: location) { page = nil; await load() }
    }
    private func load(more: Bool = false) async {
        let expected = location; loading = true; error = nil
        defer { loading = false }
        do {
            let next = try await FileManagementClient(server: server).folders(path.last?.id, start: more ? page?.nextIndex ?? 0 : 0)
            guard !Task.isCancelled, location == expected else { return }
            page = FileFolderPage(current: next.current, folders: (more ? page?.folders ?? [] : []) + next.folders, nextIndex: next.nextIndex, total: next.total)
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

struct FileActionHistoryView: View {
    let library: LibraryStore
    let server: MediaServer
    @State private var batches: [FileActionBatch] = []
    @State private var pending: FileManagementStore.Pending?
    @State private var error: String?
    @State private var busy = false
    @Environment(\.scenePhase) private var phase
    var body: some View {
        List {
            Section { Text("服务器逐个处理，退出 Glide 后继续。删除采用回收目录，仍占用 NAS 空间；可在已完成任务中还原。").font(.footnote).foregroundStyle(.secondary) }
            if let pending { Section("未确认提交") {
                Text("\(pending.request.operation.title) · \(pending.request.items.count) 个")
                Button("核对未确认提交") { Task { await reconcile(pending) } }.disabled(busy)
            } }
            ForEach(batches) { batch in
                NavigationLink { FileActionDetailView(library: library, server: server, initial: batch) } label: { FileActionSummary(batch: batch) }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange); Button("重试") { Task { await refresh() } } } }
            if batches.isEmpty && error == nil { ContentUnavailableView("还没有整理任务", systemImage: "folder", description: Text("在原视频列表点“选择”，勾选后移动或删除。")) }
        }.navigationTitle("文件整理任务").navigationBarTitleDisplayMode(.inline)
            .refreshable { await refresh() }
            .task(id: phase) {
                guard phase == .active else { return }
                repeat { await refresh(); do { try await Task.sleep(for: .seconds(batches.contains(where: \.active) ? 3 : 20)) } catch { return } } while !Task.isCancelled
            }
    }
    private func refresh() async {
        do { pending = try library.fileActions.pending(server); batches = try await library.fileActions.list(server); error = nil } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func reconcile(_ value: FileManagementStore.Pending) async {
        busy = true; defer { busy = false }
        do { _ = try await library.fileActions.submit(value.request, server: server); await refresh() } catch { self.error = error.localizedDescription }
    }
}
struct FileActionSummary: View {
    let batch: FileActionBatch
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Label(batch.operation.title, systemImage: batch.operation.symbol).font(.subheadline.weight(.semibold)); Spacer(); Text(batch.stateTitle).font(.caption).foregroundStyle(.secondary) }
            Text(batch.destinationName).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(batch.finished), total: Double(max(1, batch.total)))
            Text("已完成 \(batch.completed) · 待处理 \(batch.remaining) · 失败 \(batch.failed) · 共 \(batch.total) 个").font(.caption).foregroundStyle(.secondary)
            if batch.needsVerification > 0 { Text("\(batch.needsVerification) 项需要核对，请保留文件和任务记录。").font(.caption).foregroundStyle(.orange) }
        }.padding(.vertical, 5)
    }
}
struct FileActionDetailView: View {
    let library: LibraryStore
    let server: MediaServer
    let initial: FileActionBatch
    @State private var updated: FileActionBatch?
    @State private var busy = false
    @State private var error: String?
    @State private var confirmRestore = false
    @Environment(\.scenePhase) private var phase
    private var batch: FileActionBatch { updated ?? initial }
    var body: some View {
        List {
            Section { FileActionSummary(batch: batch) }
            Section {
                if batch.active { Button("暂停后续") { act("pause") }; Button("取消未开始项", role: .destructive) { act("cancel") } }
                if batch.state == "paused" { Button("继续处理") { act("resume") }; Button("取消未开始项", role: .destructive) { act("cancel") } }
                if !batch.active && batch.failed > 0 && batch.needsVerification == 0 { Button("仅重试失败项") { act("retry") } }
                if batch.canRestore { Button("还原已完成项到原目录", systemImage: "arrow.uturn.backward") { confirmRestore = true }.accessibilityIdentifier("files.restore") }
                Text("暂停和取消会等待当前文件处理结束，不会中途打断。目标存在同名文件时不会覆盖。").font(.caption).foregroundStyle(.secondary)
                if batch.refreshPending { Text("文件已处理，媒体索引更新待重试；可在 Jellyfin 刷新对应媒体库。").font(.caption).foregroundStyle(.orange) }
            }.disabled(busy || batch.items.count != batch.total)
            Section("逐项结果") {
                if batch.items.count != batch.total { ProgressView("读取逐项结果…") }
                ForEach(batch.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.subheadline)
                        Text(FileActionBatch.title(item.state)).font(.caption).foregroundStyle(.secondary)
                        if let code = item.errorCode { Text(FileManagementFailure.message(code)).font(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical, 3)
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange); Button("刷新结果") { Task { await refresh() } } } }
        }.navigationTitle(batch.operation.title).navigationBarTitleDisplayMode(.inline)
            .task(id: phase) {
                guard phase == .active else { return }
                repeat { await refresh(); do { try await Task.sleep(for: .seconds(batch.active ? 2 : 10)) } catch { return } } while !Task.isCancelled
            }
            .refreshable { await refresh() }
            .confirmationDialog("将已完成的 \(batch.completed) 项还原到原目录？", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("在服务器还原", role: .destructive) { Task { await restore() } }
            } message: { Text("还原视频和一起处理的外挂字幕。原目录存在同名文件或文件已被修改时不会覆盖。") }
            .onDisappear { Task { await library.refreshAfterFileManagement(server) } }
    }
    private func refresh() async {
        do { updated = try await library.fileActions.detail(batch.id, server: server); error = nil } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func act(_ command: String) { Task {
        busy = true; defer { busy = false }
        do { updated = try await library.fileActions.change(command, batch: batch.id, server: server); error = nil } catch { self.error = error.localizedDescription }
    } }
    private func restore() async {
        busy = true; defer { busy = false }
        do {
            let request = FileActionRequest(requestId: UUID(), operation: .restore, items: batch.restoreItems, restoreBatchId: batch.id)
            updated = try await library.fileActions.submit(request, server: server)
        } catch { self.error = error.localizedDescription }
    }
}

#if DEBUG
/// Fixed loopback fixture. Never connects to a saved account or production server.
struct FileManagementQAView: View {
    let library: LibraryStore
    var folderName = "source"
    @State private var ready = false
    @State private var failure: String?
    var body: some View {
        Group {
            if ready { LibraryView(library: library) }
            else if let failure { Text(failure).accessibilityIdentifier("files.qa.error") }
            else { ProgressView("准备原创文件管理片库") }
        }.task {
            guard !ready else { return }
            do {
                var server = MediaServer(id: UUID(uuidString: "F1160000-0000-0000-0000-000000008840")!, name: "Glide File QA", kind: .jellyfin,
                    address: URL(string: "http://127.0.0.1:8840")!, username: "glide-file-admin")
                let (token, user) = try await MediaClient.shared.signIn(server: server, password: "Glide-Authored-File-QA-8840")
                server.userID = user; try Credentials.save(token, for: server.id)
                if folderName == "size-sort" {
                    let roots = try await MediaClient.shared.browse(server:server,parentID:nil)
                    guard !roots.folders.isEmpty else { throw MediaError.message("原创 Jellyfin 原生媒体库入口没有返回内容") }
                }
                var pending: [[FileDestination]] = [[]]
                var found: [FileDestination]?
                while !pending.isEmpty, found == nil {
                    let path = pending.removeFirst()
                    let page = try await FileManagementClient(server: server).folders(path.last?.id)
                    for folder in page.folders {
                        if folder.name == folderName { found = path + [folder]; break }
                        if path.count < 4 { pending.append(path + [folder]) }
                    }
                }
                guard let found else { throw MediaError.message("原创 \(folderName) 目录未入库") }
                library.servers.removeAll { $0.id == server.id }; library.servers.append(server)
                library.selectedID = server.id
                library.jellyPath = found.map { MediaFolder(id: $0.id, name: $0.name, collectionType: "homevideos") }
                var options = library.browseOptions; options.includesDescendants = false; options.sort = .nameAscending
                await library.setBrowseOptions(options)
                await library.reload(); ready = true
            } catch { failure = error.localizedDescription }
        }
    }
}
#endif
