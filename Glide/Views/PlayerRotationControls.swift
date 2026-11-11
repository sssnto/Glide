import SwiftUI
import Observation

@MainActor @Observable final class PlayerRotationSave {
    var busy=false
    var stage=""
    var message: String?
    var error: String?
    var receipt: VideoRotationReceipt?
    var needsVerification=false
    var isServerJob=false
    var checkingServer=false
    var serverAvailable=false
    var serverJob:JellyfinRotationJob?
    var serverHasPending=false
    private var serverCapability:JellyfinRotationCapability?
    var serverFileName:String? { serverCapability?.fileName }
    var canRestore:Bool { isServerJob ? serverJob?.canRestore == true && !serverHasPending : receipt != nil }
    var canSave:Bool { !isServerJob || (serverAvailable && !serverHasPending && serverJob?.isActive != true && !needsVerification) }
    private var writer: RemoteVideoRotation?
    private var target: WebDAVRotationTarget?
    func prepare(_ target:PlayerRotationTarget) async {
        guard case .jellyfin(let value)=target else { return }
        isServerJob=true;checkingServer=true;error=nil
        defer { checkingServer=false }
        do {
            let client=JellyfinRotationClient(target:value)
            let pending=try JellyfinRotationJournal.pending(value)
            // A missing media item must not hide a previously accepted job.
            if let id=pending?.jobID { serverJob=try await client.job(id) }
            else {
                let jobs=try await client.jobs()
                if let pending { serverJob=jobs.first { $0.requestId==pending.request.requestId } }
                else { serverJob=jobs.first { $0.isActive || $0.state == "needs_verification" } ?? jobs.first }
            }
            serverHasPending=pending != nil || serverJob?.isActive == true || serverJob?.state == "needs_verification"
            if let job=serverJob {
                needsVerification=job.state == "needs_verification"
                if job.completed { message=job.stageTitle;try JellyfinRotationJournal.remove(value);serverHasPending=false }
                else if job.state == "failed" {
                    try JellyfinRotationJournal.remove(value);serverHasPending=false
                    error=JellyfinRotationFailure.code(job.errorCode ?? "processing_failed").localizedDescription
                }
            }
            serverCapability=try await client.capability();serverAvailable=true
        } catch { self.error=error.localizedDescription;serverAvailable=false }
    }
    func save(_ target:PlayerRotationTarget,turn:VideoQuarterTurn,willReplace:()->Void) async -> Bool {
        switch target {
        case .webDAV(let value):return await save(value,turn:turn,willReplace:willReplace)
        case .jellyfin(let value):return await runServer(value,turn:turn,restoring:false,willReplace:willReplace)
        }
    }
    func restore(_ target:PlayerRotationTarget,willReplace:()->Void) async -> Bool {
        switch target {
        case .webDAV(let value):return await restore(value,willReplace:willReplace)
        case .jellyfin(let value):return await runServer(value,turn:.original,restoring:true,willReplace:willReplace)
        }
    }
    private func runServer(_ target:JellyfinRotationTarget,turn:VideoQuarterTurn,restoring:Bool,willReplace:()->Void) async -> Bool {
        guard !busy else { return false }
        isServerJob=true;busy=true;error=nil;message=nil
        defer { busy=false;stage="" }
        let client=JellyfinRotationClient(target:target)
        do {
            // Reuse the durable request after an interrupted POST; never invent
            // a new rotation just because a response did not reach this device.
            var pending=try JellyfinRotationJournal.pending(target)
            if pending == nil,serverJob?.isActive != true,!needsVerification {
                let capability=try await client.capability()
                guard capability.version == serverCapability?.version else { throw JellyfinRotationFailure.code("file_changed") }
                guard let version=capability.version,turn != .original || restoring else { return false }
                let request=JellyfinRotationRequest(requestId:UUID(),itemId:target.itemID,mediaSourceId:target.mediaSourceID,
                    expectedVersion:version,quarterTurns:turn.rawValue,restoreJobId:restoring ? serverJob?.jobId : nil)
                if restoring,request.restoreJobId == nil { throw JellyfinRotationFailure.code("restore_conflict") }
                pending=JellyfinRotationPending(sourceID:target.server.id,videoID:target.videoID,request:request)
                try JellyfinRotationJournal.save(pending!)
            }
            serverHasPending=true
            willReplace()
            var job:JellyfinRotationJob
            if var record=pending {
                if let id=record.jobID { job=try await client.job(id) }
                else { job=try await client.submit(record.request);record.jobID=job.jobId;try JellyfinRotationJournal.save(record) }
            } else if let active=serverJob { job=try await client.job(active.jobId) }
            else { throw JellyfinRotationFailure.code("job_missing") }
            if job.state == "needs_verification" { job=try await client.verify(job.jobId) }
            while true {
                try Task.checkCancellation();serverJob=job;stage=job.stageTitle
                if !job.isActive { break }
                try await Task.sleep(for:.seconds(1));job=try await client.job(job.jobId)
            }
            needsVerification=job.state == "needs_verification"
            if job.completed {
                try JellyfinRotationJournal.remove(target)
                serverHasPending=false
                message=restoring ? "已在服务器从备份还原原文件。" : "已保存到服务器原文件，原始备份已保留。"
                if job.refreshPending { message! += "服务器资料需要手动刷新。" }
                serverCapability=try? await client.capability()
                serverAvailable=serverCapability != nil
                return true
            }
            if !needsVerification { try JellyfinRotationJournal.remove(target);serverHasPending=false }
            throw JellyfinRotationFailure.code(job.errorCode ?? "processing_failed")
        } catch is CancellationError {
            message="服务器任务会继续处理，重新打开此视频可查看结果。";return false
        } catch {
            // A known rejection did not enqueue a task; a network error is
            // ambiguous and must retain the same request identity for retry.
            if let failure=error as? JellyfinRotationFailure,case .code(let code)=failure,
               ["permission_denied","file_changed","source_changed","restore_conflict","unsupported_format","invalid_request","outside_library","symbolic_link","remote_source"].contains(code),serverJob == nil {
                try? JellyfinRotationJournal.remove(target);serverHasPending=false
            }
            self.error=error.localizedDescription;return false
        }
    }
    private func client(_ value: WebDAVRotationTarget) -> RemoteVideoRotation {
        if let writer,target==value { return writer }
        let journal=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VideoRotation/Transactions",isDirectory:true)
        let result=RemoteVideoRotation(sourceID:value.server.id,root:value.server.address,authorization:MediaClient.shared.basic(server:value.server),journalDirectory:journal)
        target=value;writer=result;return result
    }
    func save(_ target: WebDAVRotationTarget, turn: VideoQuarterTurn, willReplace: () -> Void) async -> Bool {
        guard !busy,turn != .original,!needsVerification else { return false }
        busy=true;error=nil;message=nil
        defer { busy=false;stage="" }
        do {
            let writer=client(target)
            let prepared=try await writer.prepare(target.file,progress:{ [weak self] stage in Task { @MainActor in self?.stage=stage.rawValue } })
            defer { try? FileManager.default.removeItem(at:prepared.workspace) }
            try Task.checkCancellation();willReplace()
            receipt=try await writer.save(prepared,turn:turn,progress:{ [weak self] stage in Task { @MainActor in self?.stage=stage.rawValue } })
            message="已保存到原文件，原始备份已保留。";return true
        } catch {
            if case RemoteRotationError.uncertain = error { needsVerification=true }
            self.error=error.localizedDescription;return false
        }
    }
    func restore(_ target: WebDAVRotationTarget, willReplace: () -> Void) async -> Bool {
        guard !busy,let receipt,!needsVerification else { return false }
        busy=true;error=nil;message=nil
        defer { busy=false;stage="" }
        do {
            willReplace()
            _=try await client(target).restore(receipt,progress:{ [weak self] stage in Task { @MainActor in self?.stage=stage.rawValue } })
            self.receipt=nil;message="已从备份还原原文件。";return true
        } catch {
            if case RemoteRotationError.uncertain = error { needsVerification=true }
            self.error=error.localizedDescription;return false
        }
    }
}

struct PlayerRotationControls: View {
    let target: PlayerRotationTarget
    @Binding var turn: VideoQuarterTurn
    let save: PlayerRotationSave
    let apply: () -> Void
    let restore: () -> Void
    let close: () -> Void
    let leave: () -> Void
    @State private var confirming=false
    @State private var restoring=false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            if verticalSizeClass == .compact {
                HStack {
                    leftButton.labelStyle(.iconOnly)
                    rightButton.labelStyle(.iconOnly)
                    Spacer(minLength:4)
                    saveButton
                    Button("完成",action:close).frame(minHeight:44).disabled(save.busy).accessibilityIdentifier("player.rotation.close")
                }.buttonStyle(.bordered).disabled(save.busy)
            } else {
            HStack {
                Text("视频方向").font(.subheadline.weight(.semibold))
                Spacer()
                Button("完成",action:close).disabled(save.busy).accessibilityIdentifier("player.rotation.close")
            }
            HStack(spacing:12) {
                leftButton
                rightButton
                Spacer(minLength:0)
                Text(turn.title).font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.bordered).controlSize(.regular).disabled(save.busy)
            saveButton.frame(maxWidth:.infinity)
            }
            if save.checkingServer { ProgressView("检查服务器旋转能力…").font(.caption) }
            else if save.busy { ProgressView(save.stage.isEmpty ? "正在处理当前视频…" : save.stage).font(.caption).accessibilityIdentifier("player.rotation.progress") }
            else if let error=save.error { Text(error).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("player.rotation.error") }
            else if let message=save.message { Text(message).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("player.rotation.result") }
            else if verticalSizeClass != .compact { Text(target.isServerTask ? "在服务器内处理并保留备份，无需下载或上传原片；退出播放器后任务继续。" : "只旋转画面；保存后会替换当前视频，保留备份。原有音轨和字幕不重新编码。").font(.caption).foregroundStyle(.secondary) }
            if save.isServerJob,save.busy,save.serverJob?.isActive == true {
                Button("退出播放器，后台继续",action:leave).font(.caption).accessibilityIdentifier("player.rotation.leave")
            }
            if save.isServerJob,save.serverHasPending,!save.busy {
                Button(save.needsVerification ? "核对服务器保存结果" : "查看服务器任务",action:apply).accessibilityIdentifier("player.rotation.resume")
            }
            if save.canRestore,!save.busy,!save.needsVerification {
                Button("从备份还原",systemImage:"arrow.uturn.backward") { restoring=true }.font(.caption).accessibilityIdentifier("player.rotation.restore")
            }
        }.padding(.horizontal,16).padding(.vertical,10).background(.ultraThinMaterial)
            .confirmationDialog("将方向保存到当前视频？",isPresented:$confirming,titleVisibility:.visible) {
                Button("备份并保存",role:.destructive,action:apply).accessibilityIdentifier("player.rotation.confirm")
            } message: { Text((save.serverFileName ?? target.fileName)+(target.isServerTask ? "\n由 Jellyfin 服务器备份、处理并替换当前媒体版本的原文件。" : "\n使用当前 WebDAV 连接，校验备份后替换原文件。")) }
            .confirmationDialog("从备份还原当前视频？",isPresented:$restoring,titleVisibility:.visible) {
                Button("还原原文件",role:.destructive,action:restore).accessibilityIdentifier("player.rotation.restore.confirm")
            } message: { Text(target.fileName+"\n当前文件未被其他人修改时才会还原；还原前也会备份。") }
            .task { await save.prepare(target) }
    }
    private var leftButton: some View {
        Button { rotate(-1) } label: { Label("左转",systemImage:"rotate.left").frame(minWidth:44,minHeight:44) }.accessibilityIdentifier("player.rotation.left")
    }
    private var rightButton: some View {
        Button { rotate(1) } label: { Label("右转",systemImage:"rotate.right").frame(minWidth:44,minHeight:44) }.accessibilityIdentifier("player.rotation.right")
    }
    private var saveButton: some View {
        Button { confirming=true } label: { Label(target.isServerTask ? "保存到服务器原文件" : verticalSizeClass == .compact ? "保存原文件" : "保存到当前视频原文件",systemImage:"square.and.arrow.down").frame(minHeight:44) }
            .buttonStyle(.borderedProminent).disabled(turn == .original || save.needsVerification || save.busy || save.checkingServer || !save.canSave).accessibilityIdentifier("player.rotation.save")
    }
    private func rotate(_ delta: Int) { turn=VideoQuarterTurn(rawValue:(turn.rawValue+delta+4)%4)! }
}
