import SwiftUI
import Observation

private struct RotationQueueEnvironmentKey: EnvironmentKey {
    static let defaultValue: RotationQueueStore? = nil
}
extension EnvironmentValues {
    var rotationQueue: RotationQueueStore? {
        get { self[RotationQueueEnvironmentKey.self] }
        set { self[RotationQueueEnvironmentKey.self] = newValue }
    }
}

struct VideoRotationStatus: View {
    var server: MediaServer?
    var itemID: String?
    @Environment(\.rotationQueue) private var store
    var body: some View {
        if let store, let server, server.kind == .jellyfin, let itemID {
            RotationStatusBadge(record: store.record(server: server, itemID: itemID))
        }
    }
}

struct RotationStatusBadge: View {
    var record: RotationItemRecord
    var body: some View {
        if let value = record.value {
            Label(value.title, systemImage: value.state == "completed" ? "checkmark.circle.fill" : "rotate.right")
                .font(.caption2.weight(.medium)).foregroundStyle(value.state == "needs_verification" || value.state == "failed" ? .orange : .secondary)
                .lineLimit(1).accessibilityIdentifier("rotation.status." + value.itemId)
        }
    }
}

struct RotationStatusWatcher: ViewModifier {
    var store: RotationQueueStore
    var server: MediaServer?
    var ids: [String]
    @Environment(\.scenePhase) private var phase
    private var identity: String { (server?.id.uuidString ?? "") + ids.joined(separator: ",") + String(phase == .active) }
    func body(content: Content) -> some View {
        content.task(id: identity) {
            guard phase == .active, let server, server.kind == .jellyfin else { return }
            do { try await store.capability(server) } catch { return }
            // One bounded state request per page, rather than one request per tile.
            repeat {
                await store.refreshItems(server, ids: ids)
                let active = ids.contains { id in
                    guard let state = store.record(server: server, itemID: id).value?.state else { return false }
                    return ["queued", "running", "committing"].contains(state)
                }
                do { try await Task.sleep(for: .seconds(active ? 4 : 20)) } catch { return }
            } while !Task.isCancelled
        }
    }
}

struct RotationQueueView: View {
    var library: LibraryStore
    var server: MediaServer
    @Environment(\.scenePhase) private var phase
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Text(server.name).font(.subheadline.weight(.medium))
                Text("在服务器逐个处理大文件；离开页面或退出 Glide 不会中断。暂停或取消只影响尚未开始的视频，当前文件会完成保存与校验。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = error ?? library.rotationQueue.error { Text(error).font(.footnote).foregroundStyle(.orange) }
            if library.rotationQueue.batches.isEmpty && library.rotationQueue.available {
                ContentUnavailableView("暂无旋转任务", systemImage: "rectangle.stack", description: Text("在视频列表的更多菜单中选择“批量旋转”。"))
            }
            ForEach(library.rotationQueue.batches) { batch in
                NavigationLink { RotationBatchDetail(library: library, server: server, initial: batch) } label: {
                    RotationBatchSummary(batch: batch)
                }.accessibilityIdentifier("rotation.batch." + batch.batchId.uuidString)
            }
        }.navigationTitle("旋转任务").navigationBarTitleDisplayMode(.inline)
            .refreshable { await refresh() }
            .task(id: phase) {
                guard phase == .active else { return }
                repeat {
                    await refresh()
                    do { try await Task.sleep(for: .seconds(library.rotationQueue.batches.contains(where: \.active) ? 3 : 15)) } catch { return }
                } while !Task.isCancelled
            }
    }
    private func refresh() async {
        do { try await library.rotationQueue.reconcilePending(server); error = nil }
        catch { self.error = error.localizedDescription }
        await library.rotationQueue.refresh(server)
    }
}

private struct RotationBatchSummary: View {
    let batch: RotationBatch
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(batch.stateTitle).font(.headline); Spacer(); Text("\(batch.total) 个视频").font(.subheadline).foregroundStyle(.secondary) }
            ProgressView(value: Double(batch.finishedCount), total: Double(max(1, batch.total)))
            Text("已保存 \(batch.completed) · 剩余 \(batch.remaining) · 未完成 \(batch.failed)").font(.subheadline).monospacedDigit()
            if batch.cancelled > 0 || batch.needsVerification > 0 {
                Text("已取消 \(batch.cancelled) · 待核对 \(batch.needsVerification)").font(.caption).foregroundStyle(.secondary)
            }
            if let current = batch.current {
                Text(current.title).font(.caption).lineLimit(2)
                Text(stageTitle(current.stage) + " · \(current.progress)%").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
    private func stageTitle(_ stage: String?) -> String {
        switch stage {
        case "backing_up": "正在备份原片"
        case "preparing": "正在旋转"
        case "verifying": "正在校验"
        case "replacing": "正在保存"
        case "waiting_playback": "等待其他播放结束"
        default: "等待服务器处理"
        }
    }
}

struct RotationBatchDetail: View {
    var library: LibraryStore
    var server: MediaServer
    var initial: RotationBatch
    @Environment(\.scenePhase) private var phase
    @State private var batch: RotationBatch?
    @State private var error: String?
    @State private var changing = false
    @State private var confirmAction: String?
    private var current: RotationBatch { batch ?? initial }
    var body: some View {
        List {
            Section { RotationBatchSummary(batch: current) }
            Section {
                if ["queued", "running"].contains(current.state) { Button("暂停后续任务", systemImage: "pause") { Task { await change("pause") } } }
                if current.state == "paused" { Button("继续队列", systemImage: "play") { Task { await change("resume") } } }
                if current.remaining > 0 { Button("取消尚未开始的任务", systemImage: "xmark.circle", role: .destructive) { confirmAction = "cancel" } }
                if current.failed > 0 && current.remaining == 0 && current.needsVerification == 0 {
                    Button("重试未完成的视频", systemImage: "arrow.clockwise") { confirmAction = "retry" }
                }
                if current.needsVerification > 0 {
                    Text("有文件的保存结果尚需核对。队列已暂停，请先在服务器核对原文件与备份；不要重复旋转这些视频。")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let error { Text(error).foregroundStyle(.orange).font(.footnote) }
            }.disabled(changing)
            Section("视频") {
                ForEach(current.items ?? []) { stored in
                    let entry = current.current?.itemId == stored.itemId ? current.current! : stored
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.title).font(.subheadline).lineLimit(2)
                        HStack {
                            Text(entry.stateTitle)
                            if entry.state == "running" { Text("\(entry.progress)%").monospacedDigit() }
                        }.font(.caption).foregroundStyle(entry.state == "failed" || entry.state == "needs_verification" ? .orange : .secondary)
                        if let code = entry.errorCode { Text(JellyfinRotationFailure.code(code).localizedDescription).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 3)
                }
            }
        }.navigationTitle("旋转任务详情").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(confirmAction == "retry" ? "重试未完成的视频？" : "取消尚未开始的任务？", isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }), titleVisibility: .visible) {
                Button(confirmAction == "retry" ? "重试未完成的视频" : "取消后续任务", role: .destructive) {
                    let action = confirmAction ?? "cancel"; confirmAction = nil; Task { await change(action) }
                }
            } message: { Text("已保存的视频不会重复处理；正在保存的视频会完成当前操作。") }
            .refreshable { await refresh() }
            .task(id: phase) {
                guard phase == .active else { return }
                repeat {
                    await refresh()
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                } while !Task.isCancelled
            }
    }
    private func refresh() async {
        do {
            let prior = current
            let brief = try await library.rotationQueue.detail(server, id: initial.batchId, includeItems: false)
            let result: RotationBatch
            if prior.items == nil || prior.countsKey != brief.countsKey {
                result = try await library.rotationQueue.detail(server, id: initial.batchId)
                let old = Dictionary((prior.items ?? []).map { ($0.itemId, $0.state) }, uniquingKeysWith: { _, last in last })
                let changed = (result.items ?? []).filter { old[$0.itemId] != $0.state }.map(\.itemId)
                await library.rotationQueue.refreshItems(server, ids: changed)
            } else { result = brief.carryingItems(prior.items) }
            if batch != result { batch = result }
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func change(_ action: String) async {
        changing = true
        do { batch = try await library.rotationQueue.change(server, batch: initial.batchId, action: action); error = nil }
        catch { self.error = error.localizedDescription }
        changing = false
    }
}

/// Selection stays in the owning media grid; no second list or eager library scan.
@MainActor @Observable final class RotationInlineSelection {
    private(set) var active=false
    private(set) var selected:[String:Video]=[:]
    var turns=1
    var submitting=false
    var error:String?
    private(set) var requestID=UUID()
    func begin(_ video:Video?=nil) {
        active=true;selected=[:];turns=1;error=nil;requestID=UUID()
        if let video { selected[video.id]=video }
    }
    func end() { guard !submitting else { return };active=false;selected=[:];error=nil }
    func contains(_ video:Video)->Bool { selected[video.id] != nil }
    func toggle(_ video:Video) {
        if selected[video.id] != nil { selected[video.id]=nil }
        else if selected.count<1000 { selected[video.id]=video }
        else { error="每个队列最多选择 1,000 个视频，请分批处理。" }
    }
    func selectLoaded(_ videos:[Video]) {
        let merged=Set(selected.keys).union(videos.map(\.id))
        guard merged.count<=1000 else { error="已加载的视频超过 1,000 个，请筛选或手动选择后分批处理。";return }
        for video in videos where video.remoteID != nil && video.offlineOnly != true && video.streamLinkID == nil { selected[video.id]=video }
    }
    func clear() { selected=[:] }
}

struct RotationSelectionMark: View {
    let selected:Bool
    var body: some View {
        Image(systemName:selected ? "checkmark.circle.fill":"circle")
            .font(.system(size:24,weight:.semibold))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .background(.white,in:Circle()).shadow(color:.black.opacity(0.18),radius:2,y:1)
            .padding(8).accessibilityHidden(true).allowsHitTesting(false)
    }
}

private struct RotationBatchReceipt:Identifiable {
    let server:MediaServer
    let batch:RotationBatch
    var id:UUID { batch.batchId }
}
struct RotationInlineControls: ViewModifier {
    var library:LibraryStore
    var server:MediaServer?
    var selection:RotationInlineSelection
    var loaded:[Video]
    @State private var confirming=false
    @State private var receipt:RotationBatchReceipt?
    func body(content:Content)->some View {
        content.disabled(selection.submitting)
            .safeAreaInset(edge:.bottom,spacing:0) {
                if selection.active {
                    VStack(spacing:8) {
                        HStack {
                            Text("已选 \(selection.selected.count) 个").font(.subheadline.weight(.medium)).monospacedDigit()
                            Spacer(minLength:8)
                            Button("全选已加载") { selection.selectLoaded(loaded) }.font(.caption).frame(minHeight:44)
                                .disabled(loaded.isEmpty).accessibilityLabel("全选已加载的 \(loaded.count) 个视频").accessibilityIdentifier("rotation.inline.selectAll")
                            Button("清空") { selection.clear() }.font(.caption).frame(minWidth:44,minHeight:44).disabled(selection.selected.isEmpty)
                            Button("取消") { selection.end() }.font(.caption).frame(minWidth:44,minHeight:44).accessibilityIdentifier("rotation.inline.cancelBottom")
                        }
                        HStack(spacing:10) {
                            Picker("旋转方向",selection:Binding(get:{selection.turns},set:{selection.turns=$0})) {
                                Text("顺时针 90°").tag(1);Text("旋转 180°").tag(2);Text("逆时针 90°").tag(3)
                            }.pickerStyle(.menu).labelsHidden().frame(minHeight:44).accessibilityIdentifier("rotation.inline.direction")
                            Spacer(minLength:0)
                            Button(selection.submitting ? "正在提交…":"旋转并保存") { confirming=true }
                                .font(.subheadline.weight(.semibold)).frame(minHeight:44).buttonStyle(.borderedProminent)
                                .disabled(selection.selected.isEmpty || selection.submitting || server == nil)
                                .accessibilityIdentifier("rotation.batch.submit")
                        }
                    }.padding(.horizontal,16).padding(.vertical,10).background(.bar)
                        .disabled(selection.submitting)
                }
            }
            .toolbar(selection.active ? .hidden:.visible,for:.tabBar)
            .confirmationDialog("将选中的 \(selection.selected.count) 个视频旋转并保存？",isPresented:$confirming,titleVisibility:.visible) {
                Button("在服务器旋转并保存",role:.destructive) { Task { await submit() } }
            } message: { Text("服务器将逐个替换原文件并保留备份。已保存过的视频仍会再旋转，请根据当前缩略图确认方向。退出 Glide 后队列继续执行。") }
            .alert("无法加入旋转队列",isPresented:Binding(get:{selection.error != nil},set:{if !$0 {selection.error=nil}})) {
                Button("知道了") { selection.error=nil }
            } message: { Text(selection.error ?? "") }
            .sheet(item:$receipt) { value in
                NavigationStack {
                    RotationBatchDetail(library:library,server:value.server,initial:value.batch)
                        .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { receipt=nil } } }
                }
            }
    }
    @MainActor private func submit() async {
        guard let server,!selection.submitting,!selection.selected.isEmpty else { return }
        let videos=selection.selected.values.sorted { $0.id<$1.id },turns=selection.turns,requestID=selection.requestID
        selection.submitting=true;selection.error=nil
        do {
            let result=try await library.rotationQueue.submit(server,videos:videos,turns:turns,requestID:requestID)
            selection.submitting=false;selection.end();receipt=RotationBatchReceipt(server:server,batch:result)
        } catch { selection.submitting=false;selection.error=error.localizedDescription }
    }
}
