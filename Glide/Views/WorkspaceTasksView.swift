import SwiftUI

/// A cross-source, read-only overview. Mutating queue actions stay in the existing detail flow.
struct WorkspaceTasksView:View {
    let library:LibraryStore
    @State private var downloads=DownloadStore.shared
    @State private var rotations:[WorkspaceRotationTask]=[]
    @State private var filter=WorkspaceTaskFilter.active
    @State private var errors:[String]=[]
    @State private var refreshing=false
    @State private var visible=false
    @State private var settingsOpen=false
    @Environment(\.scenePhase) private var phase
    private var serverKey:String { library.servers.filter { $0.kind == .jellyfin }.map { $0.id.uuidString }.joined(separator:",") }
    private var downloadTasks:[OfflineDownload] {
        downloads.entries.filter { filter.includes(active:Self.isActive($0),attention:Self.needsAttention($0)) }
    }
    private var rotationTasks:[WorkspaceRotationTask] {
        rotations.filter { filter.includes(active:$0.batch.active,attention:$0.batch.failed>0 || $0.batch.needsVerification>0 || $0.batch.state == "paused") }
    }
    private var activeCount:Int { downloads.entries.filter(Self.isActive).count + rotations.filter { $0.batch.active }.count }
    private var attentionCount:Int { downloads.entries.filter(Self.needsAttention).count + rotations.filter { $0.batch.failed>0 || $0.batch.needsVerification>0 || $0.batch.state == "paused" }.count }
    var body:some View {
        List {
            Section {
                HStack(spacing:0) {
                    metric("进行中",value:activeCount,symbol:"arrow.triangle.2.circlepath")
                    Divider().frame(height:38)
                    metric("需处理",value:attentionCount,symbol:"exclamationmark.circle")
                }.padding(.vertical,5)
                NavigationLink { DownloadsView(library:library) } label: {
                    Label {
                        VStack(alignment:.leading,spacing:3) {
                            Text("离线片库").font(.subheadline.weight(.semibold))
                            Text("已下载的视频、随身行程和空间管理").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical,4)
                    } icon: { Image(systemName:"arrow.down.circle") }
                }.accessibilityIdentifier("workspace.offline")
            }
            Section {
                Picker("任务筛选",selection:$filter) {
                    ForEach(WorkspaceTaskFilter.allCases) { value in Text(value.rawValue).tag(value) }
                }.pickerStyle(.segmented).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top:4,leading:0,bottom:4,trailing:0))
            }
            if downloadTasks.isEmpty && rotationTasks.isEmpty && !refreshing {
                Section {
                    ContentUnavailableView(filter == .active ? "当前没有进行中的任务":filter == .attention ? "当前没有待处理任务":"还没有任务",systemImage:filter == .attention ? "checkmark.circle":"tray",description:Text("下载和服务器旋转任务会集中显示在这里。"))
                }.listRowBackground(Color.clear)
            }
            if !downloadTasks.isEmpty {
                Section("下载 · \(downloadTasks.count)") {
                    ForEach(downloadTasks) { entry in
                        NavigationLink { DownloadsView(library:library) } label: { WorkspaceDownloadRow(entry:entry,library:library) }
                            .accessibilityIdentifier("workspace.download."+entry.id)
                    }
                }
            }
            if !rotationTasks.isEmpty {
                Section("服务器旋转 · \(rotationTasks.count)") {
                    ForEach(rotationTasks) { task in
                        NavigationLink { RotationBatchDetail(library:library,server:task.server,initial:task.batch) } label: {
                            WorkspaceRotationRow(task:task)
                        }.accessibilityIdentifier("workspace.rotation."+task.batch.batchId.uuidString)
                    }
                }
            }
            if !errors.isEmpty {
                Section("连接状态") { ForEach(errors,id:\.self) { Text($0).font(.footnote).foregroundStyle(.secondary) } }
            }
            if let message=downloads.storageError { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }.navigationTitle("任务").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { WorkspaceSettingsButton { settingsOpen=true } } }
            .overlay(alignment:.bottom) { if refreshing && rotations.isEmpty { ProgressView().padding(12).background(.regularMaterial,in:Capsule()).padding() } }
            .sheet(isPresented:$settingsOpen) { WorkspaceSettingsSheet(library:library) }
            .refreshable { await downloads.reconcile();await refresh() }
            .task { await downloads.reconcile() }
            .onAppear { visible=true }.onDisappear { visible=false }
            .task(id:"\(visible && phase == .active):"+serverKey) {
                guard visible,phase == .active else { return }
                repeat {
                    await refresh()
                    do { try await Task.sleep(for:.seconds(rotations.contains { $0.batch.active } ? 5:30)) } catch { return }
                } while !Task.isCancelled
            }
    }
    private func metric(_ title:String,value:Int,symbol:String)->some View {
        VStack(alignment:.leading,spacing:6) {
            Text(value,format:.number).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
            Label(title,systemImage:symbol).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).accessibilityElement(children:.combine)
    }
    private func refresh() async {
        guard !refreshing else { return };refreshing=true
        defer { refreshing=false }
        var result:[WorkspaceRotationTask]=[],failures:[String]=[],seen=Set<UUID>()
        // Bounded sequential GETs: no media scan, POST retry, source switching, or thumbnail work.
        for server in library.servers where server.kind == .jellyfin {
            guard !Task.isCancelled else { return }
            do {
                let capability:JellyfinRotationCapability=try await JellyfinRotationClient.request(server:server,path:"Capabilities")
                guard capability.protocolVersion == 1 else { throw JellyfinRotationFailure.code("protocol_unsupported") }
                guard capability.available else { throw JellyfinRotationFailure.code(capability.reason ?? "permission_denied") }
                guard capability.supportsBatchRotation else { continue }
                let batches:[RotationBatch]=try await JellyfinRotationClient.request(server:server,path:"Batches")
                for batch in batches where seen.insert(batch.batchId).inserted { result.append(WorkspaceRotationTask(server:server,batch:batch)) }
            } catch {
                guard !Task.isCancelled else { return }
                if case JellyfinRotationFailure.code("plugin_missing")=error { continue }
                failures.append(server.name+"：暂时无法更新旋转任务，下拉可重试。")
                // Keep the last known state when a source is temporarily unavailable.
                result.append(contentsOf:rotations.filter { $0.server.id == server.id && seen.insert($0.batch.batchId).inserted })
            }
        }
        guard !Task.isCancelled else { return }
        rotations=result.sorted { $0.batch.updatedAt > $1.batch.updatedAt };errors=failures
    }
    private static func isActive(_ entry:OfflineDownload)->Bool { ["准备资料","等待下载","下载中","校验中"].contains(entry.state) }
    private static func needsAttention(_ entry:OfflineDownload)->Bool { ["已暂停","下载失败","已中断","文件已移除"].contains(entry.state) }
}
private enum WorkspaceTaskFilter:String,CaseIterable,Identifiable {
    case active="进行中",attention="需处理",all="全部"
    var id:String { rawValue }
    func includes(active:Bool,attention:Bool)->Bool { self == .all || (self == .active && active) || (self == .attention && attention) }
}
private struct WorkspaceRotationTask:Identifiable {
    let server:MediaServer
    let batch:RotationBatch
    var id:UUID { batch.batchId }
}
private struct WorkspaceDownloadRow:View {
    let entry:OfflineDownload
    let library:LibraryStore
    var body:some View {
        HStack(spacing:12) {
            VideoArtwork(video:entry.video,server:library.servers.first { $0.id == entry.serverID }).frame(width:48,height:68).clipShape(.rect(cornerRadius:7))
            VStack(alignment:.leading,spacing:5) {
                Text(RecommendationMediaIdentity(entry.video).title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let episode=RecommendationMediaIdentity(entry.video).episode { Text(episode).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                HStack { Text(entry.state);Spacer();Text(entry.progress,format:.percent.precision(.fractionLength(0))).monospacedDigit() }.font(.caption).foregroundStyle(.secondary)
                ProgressView(value:max(0,min(1,entry.progress)))
                if let message=entry.message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        }.padding(.vertical,4).accessibilityElement(children:.combine)
    }
}
private struct WorkspaceRotationRow:View {
    let task:WorkspaceRotationTask
    var body:some View {
        HStack(alignment:.top,spacing:12) {
            Image(systemName:"rotate.right").font(.title3).foregroundStyle(.tint).frame(width:44,height:44).background(Color.accentColor.opacity(0.08),in:.rect(cornerRadius:10))
            VStack(alignment:.leading,spacing:6) {
                HStack { Text("批量旋转").font(.subheadline.weight(.semibold));Spacer();Text(task.batch.stateTitle).font(.caption).foregroundStyle(.secondary) }
                Text(task.server.name).font(.caption).foregroundStyle(.secondary)
                ProgressView(value:Double(task.batch.finishedCount),total:Double(max(1,task.batch.total)))
                Text("已保存 \(task.batch.completed) · 待处理 \(task.batch.remaining) · 共 \(task.batch.total) 个").font(.caption).foregroundStyle(.secondary)
                if let item=task.batch.current { Text(item.title).font(.caption).lineLimit(1) }
                if task.batch.needsVerification>0 || task.batch.failed>0 { Text("需核对 \(task.batch.needsVerification) · 未完成 \(task.batch.failed)").font(.caption).foregroundStyle(.orange) }
            }
        }.padding(.vertical,5).accessibilityElement(children:.combine)
    }
}
