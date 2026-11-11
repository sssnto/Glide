import Foundation
import Observation
import AVFoundation

@MainActor @Observable final class VideoRotationEditorModel {
    var server: MediaServer?
    var directory: URL?
    var entries: [DAVEntry] = []
    var selected: DAVEntry?
    var prepared: PreparedVideoRotation?
    var turn = VideoQuarterTurn.original
    var confirmedFile = false
    var loading = false
    var saving = false
    var stage = ""
    var message: String?
    var error: String?
    var receipt: VideoRotationReceipt?
    var history: [VideoRotationReceipt] = []
    var previewReady = false
#if DEBUG
    var validationResult = "尚未验证"
    func validateDirectory() async {
        guard let client,!saving,!loading,let fixture=Bundle.main.url(forResource:"demo0",withExtension:"mp4") else { return }
        resetPreview();saving=true;validationResult="正在验证";error=nil;message=nil
        var checks: [String:Bool] = [:]
        var failure: [String:Any] = [:]
        await client.resetValidationDiagnostics()
        defer { saving=false;stage="" }
        do {
            let remote=try await client.installValidationFixture(fixture)
            let prepared=try await client.prepare(remote)
            defer { try? FileManager.default.removeItem(at:prepared.workspace) }
            checks["authoredUpload"]=prepared.digest == (try RemoteVideoRotation.digest(fixture))
            let before=try VideoFileRotation.inspect(prepared.file,turn:.clockwise)
            let receipt=try await client.save(prepared,turn:.clockwise,progress:{ [weak self] stage in Task { @MainActor in self?.stage=stage.rawValue } })
            let saved=try await client.prepare(remote)
            defer { try? FileManager.default.removeItem(at:saved.workspace) }
            let after=try VideoFileRotation.inspect(saved.file,turn:.original)
            checks["savedMatrix"]=after.original==before.replacement
            checks["otherBytesPreserved"]=try RemoteVideoRotation.digest(prepared.file,excluding:before.matrixOffset..<before.matrixOffset+36) == RemoteVideoRotation.digest(saved.file,excluding:before.matrixOffset..<before.matrixOffset+36)
            let asset=AVURLAsset(url:saved.file)
            let track=try await asset.loadTracks(withMediaType:.video).first
            guard let track else { throw RemoteRotationError.invalidFile }
            let transform=try await track.load(.preferredTransform),size=try await track.load(.naturalSize)
            let rect=CGRect(origin:.zero,size:size).applying(transform).standardized
            checks["nativeRotatedDimensions"]=abs(rect.width-prepared.height)<1 && abs(rect.height-prepared.width)<1
            checks["nativePlayable"]=try await asset.load(.isPlayable)
            let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true
            let frame=try await generator.image(at:CMTime(seconds:0.5,preferredTimescale:600)).image
            checks["nativeDecodedFrame"]=abs(Double(frame.width)-prepared.height)<1 && abs(Double(frame.height)-prepared.width)<1
            let restored=try await client.restore(receipt)
            let final=try await client.prepare(remote)
            defer { try? FileManager.default.removeItem(at:final.workspace) }
            checks["exactRestore"]=final.digest==prepared.digest
            guard checks.values.allSatisfy({ $0 }) else { throw RemoteRotationError.invalidFile }
            try await client.cleanValidationFixture(remote,receipts:[receipt,restored]);checks["ownedFilesCleaned"]=true
            if let server {
                let entries=try await MediaClient.shared.webDAV(server:server,directory:server.address)
                _=try await client.cleanAbandonedValidationFixtures(entries.filter { !$0.isDirectory && $0.name.hasPrefix("Glide-方向验证-") }.map(\.url),matching:fixture)
                checks["previousAuthoredRunsCleaned"]=true
            }
            validationResult="验证通过";message="原创短片的上传、旋转替换、系统解码、原样还原均通过，测试文件已清理。";await loadHistory()
        } catch {
            validationResult="验证失败";self.error=error.localizedDescription
            failure=["type":String(reflecting:type(of:error)),"domain":(error as NSError).domain,"code":(error as NSError).code]
        }
        let diagnostics=await client.validationDiagnostics()
        let trace=(try? JSONEncoder().encode(diagnostics)).flatMap { try? JSONSerialization.jsonObject(with:$0) } ?? []
        let report: [String:Any] = ["version":2,"result":validationResult,"checks":checks,"failure":failure,"httpTrace":trace,"time":ISO8601DateFormatter().string(from:Date()),"build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""]
        if let bytes=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
            let target=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("rotation-qa.json")
            try? bytes.write(to:target,options:.atomic)
        }
    }
#endif
    let player = AVPlayer()
    private var client: RemoteVideoRotation?
    private var generation = UUID()
    private var workspace: URL?
    @ObservationIgnored private var layerObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private weak var previewLayer: AVPlayerLayer?
    private static var journal: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VideoRotation/Transactions",isDirectory:true)
    }
    init() { player.isMuted = true }
    func connect(_ value: MediaServer) async {
        guard !saving else { return }
        resetPreview(); server=value; directory=value.address; receipt=nil; message=nil; error=nil
        client=RemoteVideoRotation(sourceID:value.id,root:value.address,authorization:MediaClient.shared.basic(server:value),journalDirectory:Self.journal)
        await browse(value.address); await loadHistory()
    }
    func browse(_ url: URL) async {
        guard let server, !saving, DirectoryScope.contains(root:server.address,child:url) else { return }
        let token=UUID();generation=token;loading=true;error=nil
        do {
            let values=try await MediaClient.shared.webDAV(server:server,directory:url)
            guard !Task.isCancelled,generation==token else { return }
            directory=url;entries=values.filter { DirectoryScope.contains(root:server.address,child:$0.url) && !$0.url.lastPathComponent.hasPrefix(".glide-") }
        } catch { if generation==token { self.error=error.localizedDescription } }
        if generation==token { loading=false }
    }
    func choose(_ entry: DAVEntry) async {
        guard !saving,let client else { return }
        resetPreview();selected=entry;receipt=nil;message=nil;error=nil;loading=true
        let token=UUID();generation=token
        do {
            let value=try await client.prepare(entry.url,progress:{ [weak self] stage in Task { @MainActor in if self?.generation==token { self?.stage=stage.rawValue } } })
            guard !Task.isCancelled,generation==token else { try? FileManager.default.removeItem(at:value.workspace);return }
            workspace=value.workspace;prepared=value;preview(value.file)
        } catch { if generation==token { self.error=error.localizedDescription } }
        if generation==token { loading=false;stage="" }
    }
    private func preview(_ url: URL) {
        previewReady=false
        let item=AVPlayerItem(url:url)
        itemObservation=item.observe(\.status,options:[.initial,.new]) { [weak self] item,_ in
            let failed=item.status == .failed
            Task { @MainActor in
                guard self?.player.currentItem === item else { return }
                if failed { self?.previewReady=false;self?.error="此视频编码无法在系统播放器预览，尚未修改原文件。" }
            }
        }
        player.replaceCurrentItem(with:item);player.play()
    }
    func attachLayer(_ layer: AVPlayerLayer?) {
        guard previewLayer !== layer else { return }
        layerObservation=nil;previewLayer=layer
        layerObservation=layer?.observe(\.isReadyForDisplay,options:[.initial,.new]) { [weak self] layer,_ in
            let ready=layer.isReadyForDisplay
            Task { @MainActor in
                guard self?.previewLayer === layer else { return }
                self?.previewReady=ready
            }
        }
    }
    func save(willReplace: () -> Void) async -> Bool {
        guard let client,let prepared,turn != .original,confirmedFile,!saving,previewReady,player.currentItem?.status == .readyToPlay else { return false }
        saving=true;error=nil;message=nil;player.pause();willReplace()
        defer { saving=false;stage="" }
        do {
            let result=try await client.save(prepared,turn:turn,progress:{ [weak self] stage in Task { @MainActor in self?.stage=stage.rawValue } })
            receipt=result
            let corrected=prepared.workspace.appendingPathComponent("corrected."+prepared.file.pathExtension)
            preview(corrected);turn = .original;confirmedFile=false
            self.prepared=nil
            message="已替换所选目录中的原文件，原始备份已保留。"
            await loadHistory();return true
        } catch { self.error=error.localizedDescription;await loadHistory();return false }
    }
    func restore(_ value: VideoRotationReceipt,willReplace: () -> Void) async -> Bool {
        guard let client,!saving else { return false }
        saving=true;error=nil;player.pause();willReplace()
        defer { saving=false;stage="" }
        do {
            _=try await client.restore(value,progress:{ [weak self] stage in Task { @MainActor in self?.stage=stage.rawValue } })
            resetPreview();receipt=nil;message="原文件已从备份还原；此次还原前的文件也已备份。"
            await loadHistory();return true
        } catch { self.error=error.localizedDescription;await loadHistory();return false }
    }
    func resolve(_ value: VideoRotationReceipt) async {
        guard let client,!saving else { return };loading=true;error=nil
        defer { loading=false }
        do {
            let result=try await client.resolve(value)
            message=result.state == "saved" ? "已确认文件保存完成，可以从备份还原。" : result.state == "unchanged" ? "原文件未被替换，原始备份仍保留。" : "文件与保存前后版本都不一致，请保留备份并人工核对。"
            await loadHistory()
        } catch { self.error=error.localizedDescription }
    }
    func loadHistory() async {
        guard let server else { history=[];return }
        let directory=Self.journal,id=server.id
        let work=Task.detached {
            ((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []).filter { $0.pathExtension == "json" }.compactMap {
                try? RecoverableStore<VideoRotationReceipt>(file:$0).load()?.value
            }.filter { $0.sourceID==id }.sorted { $0.date>$1.date }
        }
        let values=await work.value
        guard self.server?.id == id else { return }
        history=Array(values.prefix(50))
    }
    func resetPreview() {
        generation=UUID();player.pause();player.replaceCurrentItem(with:nil);previewReady=false
        itemObservation=nil
        if let workspace { try? FileManager.default.removeItem(at:workspace) }
        workspace=nil
        prepared=nil;selected=nil;receipt=nil;turn = .original;confirmedFile=false
    }
    func close() { if !saving { resetPreview() } }
}
