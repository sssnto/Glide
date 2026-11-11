import Foundation
import CryptoKit

enum RotationSaveStage: String, Sendable {
    case permissions = "验证目录写入保护", downloading = "读取服务器原文件", checking = "校验视频与方向"
    case uploading = "上传临时文件", backup = "保存原文件备份", replacing = "替换服务器原文件", verifying = "验证保存结果"
}

enum RemoteRotationError: Error, LocalizedError {
    case http(Int), unsafeServer, changed, invalidFile, outsideDirectory, uncertain(String)
    var errorDescription: String? {
        switch self {
        case .http(let status): "WebDAV 操作失败（HTTP \(status)），请检查账号与目录写入权限。"
        case .unsafeServer: "此 WebDAV 未通过锁定或文件版本保护检查，暂不能安全替换原文件。"
        case .changed: "服务器原文件已变化，请重新读取并预览。"
        case .invalidFile: "文件或传输结果未通过校验，尚未确认保存完成。"
        case .outsideDirectory: "所选文件不在已连接的 WebDAV 目录内。"
        case .uncertain(let name): "保存状态尚未确认。原始备份为 \(name)，请保留备份并检查原文件。"
        }
    }
}

struct RotationRemoteVersion: Equatable, Sendable { var size: Int64; var etag: String }
struct PreparedVideoRotation: Sendable {
    let source: URL
    let file: URL
    let workspace: URL
    let version: RotationRemoteVersion
    let digest: String
    let width: Double
    let height: Double
}
struct VideoRotationReceipt: Codable, Identifiable, Sendable {
    let id: UUID
    let sourceID: UUID
    let original: URL
    let backup: URL
    let originalDigest: String
    let savedDigest: String
    let turn: VideoQuarterTurn
    let date: Date
    var savedETag: String?
    var state: String
}
#if DEBUG
/// Header categories only: never record addresses, authorization, ETags or lock tokens.
struct RotationHTTPDiagnostic: Codable, Sendable {
    let method: String
    let role: String
    let status: Int
    let etag: String
    let contentLength: Int64?
    let lockTokenPresent: Bool
}
#endif

private final class RotationRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

/// A writer separate from normal read-only browsing. Secrets remain in memory, never in receipts/logs.
actor RemoteVideoRotation {
    private enum Protection { case lock, version }
    private let sourceID: UUID
    private let root: URL
    private let authorization: String
    private let session: URLSession
    private let journalDirectory: URL
    private var protection: Protection?
    private var busy = false
#if DEBUG
    private var httpDiagnostics: [RotationHTTPDiagnostic] = []
    func validationDiagnostics() -> [RotationHTTPDiagnostic] { httpDiagnostics }
    func resetValidationDiagnostics() { httpDiagnostics=[] }
    private func recordHTTP(_ method: String, _ file: URL, _ response: HTTPURLResponse) {
        let name=file.lastPathComponent
        let role=name.hasPrefix(".glide-write-check-") ? (name.hasSuffix("-a") ? "probe-a" : "probe-b") : name.hasPrefix("Glide-方向验证-") ? "authored" : name.hasSuffix(".part") ? "staged" : name.hasSuffix(".bak") ? "backup" : "original"
        let tag=response.value(forHTTPHeaderField:"ETag")
        let kind=tag == nil ? "absent" : tag!.hasPrefix("W/") ? "weak" : tag!.hasPrefix("\"") && tag!.hasSuffix("\"") ? "strong" : "unquoted"
        if httpDiagnostics.count<200 { httpDiagnostics.append(RotationHTTPDiagnostic(method:method,role:role,status:response.statusCode,etag:kind,contentLength:response.value(forHTTPHeaderField:"Content-Length").flatMap(Int64.init),lockTokenPresent:response.value(forHTTPHeaderField:"Lock-Token") != nil)) }
    }
    private var validationFiles = Set<URL>()
    func installValidationFixture(_ local: URL) async throws -> URL {
        let target=root.appendingPathComponent("Glide-方向验证-"+UUID().uuidString+".mp4")
        try await upload(local,to:target)
        validationFiles.insert(target)
        return target
    }
    /// Previous interrupted QA runs may have left only our unchanged authored clip.
    /// UUID name, exact size and full digest must all match before conditional deletion.
    func cleanAbandonedValidationFixtures(_ candidates: [URL], matching local: URL) async throws -> Int {
        let expected=try Self.digest(local),size=try local.resourceValues(forKeys:[.fileSizeKey]).fileSize
        var count=0
        for candidate in candidates.prefix(30) {
            let stem=candidate.deletingPathExtension().lastPathComponent
            guard candidate.pathExtension=="mp4",stem.hasPrefix("Glide-方向验证-"),UUID(uuidString:String(stem.dropFirst("Glide-方向验证-".count))) != nil else { continue }
            try scope(candidate)
            let info=try await version(candidate)
            guard info.size == Int64(size ?? -1) else { continue }
            let copy=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:copy) }
            try await download(candidate,to:copy,expected:info)
            guard try Self.digest(copy)==expected else { continue }
            try accepted(try await send("DELETE",candidate,headers:["If-Match":info.etag]).1,[200,204]);count+=1
        }
        return count
    }
    func cleanValidationFixture(_ original: URL, receipts: [VideoRotationReceipt]) async throws {
        guard validationFiles.contains(original), receipts.allSatisfy({ $0.original==original && $0.sourceID==sourceID && $0.state=="saved" }) else { throw RemoteRotationError.outsideDirectory }
        for receipt in receipts {
            let info=try await version(receipt.backup)
            let copy=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:copy) }
            try await download(receipt.backup,to:copy,expected:info)
            guard try Self.digest(copy)==receipt.originalDigest else { throw RemoteRotationError.changed }
            try accepted(try await send("DELETE",receipt.backup,headers:["If-Match":info.etag]).1,[200,204])
            try? FileManager.default.removeItem(at:journalDirectory.appendingPathComponent(receipt.id.uuidString+".json"))
        }
        let info=try await version(original)
        guard let last=receipts.last,info.etag==last.savedETag else { throw RemoteRotationError.changed }
        try accepted(try await send("DELETE",original,headers:["If-Match":info.etag]).1,[200,204])
        validationFiles.remove(original)
    }
#endif

    init(sourceID: UUID, root: URL, authorization: String, journalDirectory: URL, session: URLSession? = nil) {
        self.sourceID = sourceID; self.root = root; self.authorization = authorization; self.journalDirectory = journalDirectory
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 3600
        self.session = session ?? URLSession(configuration: config, delegate: RotationRedirectGuard(), delegateQueue: nil)
    }

    func prepare(_ file: URL, progress: @Sendable (RotationSaveStage) -> Void = { _ in }) async throws -> PreparedVideoRotation {
        guard !busy else { throw MediaError.message("另一项保存操作尚未完成。") }
        try scope(file)
        guard ["mp4","mov","m4v"].contains(file.pathExtension.lowercased()) else { throw VideoFileRotationError.unsupportedFile }
        progress(.permissions)
        if protection == nil { protection = try await probe(file.deletingLastPathComponent()) }
        progress(.downloading)
        let before = try await version(file)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Glide-Rotation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        do {
            let available = try temp.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            if let available, !OfflineMediaFiles.canReserve(bytes: before.size, availableBytes: available, reservations: [before.size,before.size]) {
                throw MediaError.message("本机空间不足，需为原文件与校验副本预留空间。")
            }
            let target = temp.appendingPathComponent(file.lastPathComponent)
            try await download(file, to: target, expected: before)
            guard try await version(file) == before else { throw RemoteRotationError.changed }
            progress(.checking)
            let parsed = try VideoFileRotation.inspect(target, turn: .original)
            let digest = try Self.digest(target)
            // Read-range support is required before any replacement, not discovered after it.
            guard try await range(file, offset: parsed.matrixOffset, count: 36, version: before) == parsed.original else { throw RemoteRotationError.changed }
            return PreparedVideoRotation(source: file, file: target, workspace: temp, version: before, digest: digest, width: parsed.width, height: parsed.height)
        } catch { try? FileManager.default.removeItem(at: temp); throw error }
    }

    func save(_ prepared: PreparedVideoRotation, turn: VideoQuarterTurn,
              progress: @Sendable (RotationSaveStage) -> Void = { _ in }) async throws -> VideoRotationReceipt {
        guard turn != .original else { throw MediaError.message("请先选择需要修正的方向。") }
        guard !busy, protection != nil else { throw RemoteRotationError.unsafeServer }
        busy = true; defer { busy = false }
        try scope(prepared.source)
        guard try Self.digest(prepared.file) == prepared.digest else { throw RemoteRotationError.changed }
        let corrected = prepared.workspace.appendingPathComponent("corrected." + prepared.file.pathExtension)
        try? FileManager.default.removeItem(at: corrected)
        try FileManager.default.copyItem(at: prepared.file, to: corrected)
        let patch = try VideoFileRotation.inspect(corrected, turn: turn)
        try VideoFileRotation.apply(patch, toStagedFile: corrected)
        guard try Self.digest(prepared.file, excluding: patch.matrixOffset..<patch.matrixOffset+36) == Self.digest(corrected, excluding: patch.matrixOffset..<patch.matrixOffset+36) else { throw RemoteRotationError.invalidFile }
        return try await publish(prepared, corrected: corrected, turn: turn, progress: progress)
    }

    private func publish(_ prepared: PreparedVideoRotation, corrected: URL, turn: VideoQuarterTurn,
                         progress: @Sendable (RotationSaveStage) -> Void) async throws -> VideoRotationReceipt {
        guard let protection else { throw RemoteRotationError.unsafeServer }
        let id = UUID(), directory = prepared.source.deletingLastPathComponent()
        let staged = directory.appendingPathComponent(".glide-rotation-" + id.uuidString + ".part")
        let backup = directory.appendingPathComponent(".glide-rotation-original-" + id.uuidString + ".bak")
        let patch = try VideoFileRotation.inspect(corrected, turn: .original)
        let savedDigest = try Self.digest(corrected)
        var lockToken: String?
        var stagedETag: String?
        var attemptedMove = false
        var receipt = VideoRotationReceipt(id: id, sourceID: sourceID, original: prepared.source, backup: backup,
                                          originalDigest: prepared.digest, savedDigest: savedDigest, turn: turn, date: Date(), state: "prepared")
        do {
            progress(.uploading)
            try await upload(corrected, to: staged)
            let stagedVersion = try await version(staged); stagedETag = stagedVersion.etag
            guard stagedVersion.size == prepared.version.size else { throw RemoteRotationError.invalidFile }
            let validation = prepared.workspace.appendingPathComponent("uploaded-copy")
            try await download(staged, to: validation, expected: stagedVersion)
            guard try Self.digest(validation) == savedDigest else { throw RemoteRotationError.invalidFile }
            try? FileManager.default.removeItem(at: validation)
            progress(.backup)
            guard try await version(prepared.source) == prepared.version else { throw RemoteRotationError.changed }
            let copied = try await send("COPY", prepared.source, headers: ["Destination": backup.absoluteString, "Overwrite": "F", "If-Match": prepared.version.etag])
            try accepted(copied.1, [201,204])
            let backupVersion = try await version(backup)
            guard backupVersion.size == prepared.version.size else { throw RemoteRotationError.invalidFile }
            let originalCopy = prepared.workspace.appendingPathComponent("backup-check")
            try await download(backup, to: originalCopy, expected: backupVersion)
            guard try Self.digest(originalCopy) == prepared.digest else { throw RemoteRotationError.changed }
            try? FileManager.default.removeItem(at: originalCopy)
            try Task.checkCancellation()
            if case .lock = protection { lockToken = try await acquireLock(prepared.source) }
            guard try await version(prepared.source) == prepared.version else { throw RemoteRotationError.changed }
            try persist(receipt)
            progress(.replacing)
            var headers = ["Destination": prepared.source.absoluteString, "Overwrite": "T", "If-Match": stagedVersion.etag]
            headers["If"] = condition(prepared.source, token: lockToken, etag: lockToken == nil ? prepared.version.etag : nil)
            try Task.checkCancellation()
            attemptedMove = true
            let moved = try await send("MOVE", staged, headers: headers)
            try accepted(moved.1, [201,204])
            progress(.verifying)
            let final = try await version(prepared.source)
            guard final.size == prepared.version.size,
                  try await range(prepared.source, offset: patch.matrixOffset, count: 36, version: final) == patch.replacement else { throw RemoteRotationError.invalidFile }
            receipt.savedETag = final.etag; receipt.state = "saved"; try persist(receipt)
            if let lockToken { await unlock(prepared.source, token: lockToken) }
            return receipt
        } catch {
            if let lockToken { await unlock(prepared.source, token: lockToken) }
            if !attemptedMove, let stagedETag { await removeOwned(staged, etag: stagedETag) }
            if attemptedMove {
                receipt.state = "needs-verification"; try? persist(receipt)
                throw RemoteRotationError.uncertain(backup.lastPathComponent)
            }
            throw error
        }
    }

    func restore(_ receipt: VideoRotationReceipt, progress: @Sendable (RotationSaveStage) -> Void = { _ in }) async throws -> VideoRotationReceipt {
        guard receipt.sourceID == sourceID, receipt.state == "saved" else { throw RemoteRotationError.changed }
        try scope(receipt.backup); try scope(receipt.original)
        let prepared = try await prepare(receipt.original, progress: progress)
        defer { try? FileManager.default.removeItem(at: prepared.workspace) }
        guard prepared.digest == receipt.savedDigest else { throw RemoteRotationError.changed }
        let saved = prepared.workspace.appendingPathComponent("restore-check")
        let backupVersion = try await version(receipt.backup)
        try await download(receipt.backup, to: saved, expected: backupVersion)
        guard try Self.digest(saved) == receipt.originalDigest else { throw RemoteRotationError.invalidFile }
        let original = saved.appendingPathExtension(prepared.file.pathExtension)
        try FileManager.default.moveItem(at: saved, to: original)
        guard !busy else { throw MediaError.message("另一项保存操作尚未完成。") }
        busy = true; defer { busy = false }
        return try await publish(prepared, corrected: original, turn: .original, progress: progress)
    }

    func resolve(_ previous: VideoRotationReceipt) async throws -> VideoRotationReceipt {
        guard previous.sourceID == sourceID else { throw RemoteRotationError.changed }
        try scope(previous.original); try scope(previous.backup)
        let info = try await version(previous.original)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try await download(previous.original, to: file, expected: info)
        let digest = try Self.digest(file)
        var receipt = previous
        if digest == receipt.savedDigest { receipt.state = "saved"; receipt.savedETag = info.etag }
        else if digest == receipt.originalDigest { receipt.state = "unchanged" }
        else { receipt.state = "needs-verification" }
        try persist(receipt); return receipt
    }

    private func scope(_ file: URL) throws {
        guard ["http","https"].contains(file.scheme?.lowercased() ?? ""), DirectoryScope.contains(root: root, child: file),
              file.user == nil, file.password == nil, file.query == nil, file.fragment == nil else { throw RemoteRotationError.outsideDirectory }
    }
    private func request(_ method: String, _ file: URL, headers: [String:String] = [:], body: Data? = nil) throws -> URLRequest {
        try scope(file)
        var value = URLRequest(url: file); value.httpMethod = method; value.httpBody = body
        value.setValue(authorization, forHTTPHeaderField: "Authorization"); value.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        value.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (key,text) in headers { value.setValue(text, forHTTPHeaderField: key) }
        return value
    }
    private func send(_ method: String, _ file: URL, headers: [String:String] = [:], body: Data? = nil) async throws -> (Data,HTTPURLResponse) {
        let (data,response) = try await session.data(for: request(method,file,headers:headers,body:body))
        guard let response = response as? HTTPURLResponse, data.count <= 1_000_000 else { throw RemoteRotationError.invalidFile }
#if DEBUG
        recordHTTP(method,file,response)
#endif
        return (data,response)
    }
    private func accepted(_ response: HTTPURLResponse, _ statuses: [Int]) throws {
        guard statuses.contains(response.statusCode) else {
            if response.statusCode == 412 { throw RemoteRotationError.changed }
            throw RemoteRotationError.http(response.statusCode)
        }
    }
    private func version(_ file: URL) async throws -> RotationRemoteVersion {
        let (_,response) = try await send("HEAD",file); try accepted(response,[200])
        guard let size = response.value(forHTTPHeaderField:"Content-Length").flatMap(Int64.init), size > 0,
              let tag = response.value(forHTTPHeaderField:"ETag"), tag.hasPrefix("\""), tag.hasSuffix("\""), tag.count <= 512,
              !tag.contains("\r"), !tag.contains("\n") else { throw RemoteRotationError.unsafeServer }
        return RotationRemoteVersion(size:size,etag:tag)
    }
    private func download(_ file: URL, to target: URL, expected: RotationRemoteVersion) async throws {
        let (temporary,response) = try await session.download(for: request("GET",file,headers:["If-Match":expected.etag]))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse else { throw RemoteRotationError.invalidFile }; try accepted(response,[200])
#if DEBUG
        recordHTTP("GET-download",file,response)
#endif
        let size = try temporary.resourceValues(forKeys:[.fileSizeKey]).fileSize
        guard Int64(size ?? -1) == expected.size else { throw RemoteRotationError.invalidFile }
        try? FileManager.default.removeItem(at:target); try FileManager.default.moveItem(at:temporary,to:target)
    }
    private func upload(_ file: URL, to target: URL) async throws {
        var value = try request("PUT",target,headers:["If-None-Match":"*","Content-Type":"application/octet-stream"])
        value.httpBody = nil
        let (_,response) = try await session.upload(for:value,fromFile:file)
        guard let response = response as? HTTPURLResponse else { throw RemoteRotationError.invalidFile }
#if DEBUG
        recordHTTP("PUT-upload",target,response)
#endif
        try accepted(response,[201,204])
    }
    private func range(_ file: URL, offset: UInt64, count: Int, version: RotationRemoteVersion) async throws -> Data {
        let end = offset + UInt64(count) - 1
        let (stream,response) = try await session.bytes(for: request("GET",file,headers:["If-Match":version.etag,"Range":"bytes=\(offset)-\(end)"]))
#if DEBUG
        if let response=response as? HTTPURLResponse { recordHTTP("GET-range",file,response) }
#endif
        guard let response = response as? HTTPURLResponse, response.statusCode == 206,
              response.value(forHTTPHeaderField:"Content-Range") == "bytes \(offset)-\(end)/\(version.size)" else {
            for task in await session.allTasks where task.currentRequest?.url == file { task.cancel() }
            throw RemoteRotationError.unsafeServer
        }
        var data = Data(); for try await byte in stream { data.append(byte); if data.count > count { throw RemoteRotationError.invalidFile } }
        guard data.count == count else { throw RemoteRotationError.invalidFile }; return data
    }
    private func condition(_ file: URL, token: String? = nil, etag: String? = nil) -> String {
        "<" + file.absoluteString + "> (" + [token.map { "<"+$0+">" },etag.map { "["+$0+"]" }].compactMap { $0 }.joined(separator:" ") + ")"
    }
    private func acquireLock(_ file: URL) async throws -> String {
        let xml = Data("<?xml version=\"1.0\"?><d:lockinfo xmlns:d=\"DAV:\"><d:lockscope><d:exclusive/></d:lockscope><d:locktype><d:write/></d:locktype><d:owner>Glide video direction</d:owner></d:lockinfo>".utf8)
        let (_,response) = try await send("LOCK",file,headers:["Depth":"0","Timeout":"Second-120","Content-Type":"application/xml"],body:xml)
        try accepted(response,[200,201])
        guard let raw = response.value(forHTTPHeaderField:"Lock-Token"), raw.hasPrefix("<"), raw.hasSuffix(">"),
              raw.count < 1024, !raw.contains("\r"), !raw.contains("\n") else { throw RemoteRotationError.unsafeServer }
        return String(raw.dropFirst().dropLast())
    }
    private func unlock(_ file: URL, token: String) async {
        let cleanup = Task { _ = try? await self.send("UNLOCK",file,headers:["Lock-Token":"<"+token+">"]) }
        await cleanup.value
    }
    private func removeOwned(_ file: URL, etag: String) async {
        let cleanup = Task { _ = try? await self.send("DELETE",file,headers:["If-Match":etag]) }
        await cleanup.value
    }
    private func probe(_ directory: URL, testLock: Bool = true) async throws -> Protection {
        let stem = ".glide-write-check-" + UUID().uuidString
        let a = directory.appendingPathComponent(stem+"-a"), b = directory.appendingPathComponent(stem+"-b")
        let aData = Data("Glide permission A".utf8), bData = Data("Glide permission B".utf8)
        do {
            try accepted(try await send("PUT",a,headers:["If-None-Match":"*"],body:aData).1,[201,204])
            try accepted(try await send("PUT",b,headers:["If-None-Match":"*"],body:bData).1,[201,204])
            let refusal = try await send("MOVE",b,headers:["Destination":a.absoluteString,"Overwrite":"F"])
            guard refusal.1.statusCode == 412, try await send("GET",a).0 == aData, try await send("GET",b).0 == bData else { throw RemoteRotationError.unsafeServer }
            if testLock, let token = try? await acquireLock(a) {
                var protected=false
                do {
                    let withoutToken = try await send("MOVE",b,headers:["Destination":a.absoluteString,"Overwrite":"T"])
                    let remaining = try await send("GET",a).0
                    protected = [412,423].contains(withoutToken.1.statusCode) && remaining == aData
                    if protected { protected = try await send("GET",b).0 == bData }
                    if protected {
                        let bv=try await version(b)
                        let authorized=try await send("MOVE",b,headers:["Destination":a.absoluteString,"Overwrite":"T","If":condition(a,token:token),"If-Match":bv.etag])
                        let result=try await send("GET",a).0
                        protected = [201,204].contains(authorized.1.statusCode) && result == bData
                    }
                } catch { await unlock(a,token:token); throw error }
                await unlock(a,token:token)
                if let av = try? await version(a) { await removeOwned(a,etag:av.etag) }
                if let bv = try? await version(b) { await removeOwned(b,etag:bv.etag) }
                if protected { return .lock }
                // A server may advertise LOCK but ignore it. Independently prove
                // destination-version conditions using fresh owned files.
                return try await probe(directory,testLock:false)
            }
            let incorrect = condition(a,etag:"\"glide-invalid-"+UUID().uuidString+"\"")
            let refusal2 = try await send("MOVE",b,headers:["Destination":a.absoluteString,"Overwrite":"T","If":incorrect])
            guard refusal2.1.statusCode == 412, try await send("GET",a).0 == aData, try await send("GET",b).0 == bData else { throw RemoteRotationError.unsafeServer }
            let av = try await version(a), bv = try await version(b)
            let moved = try await send("MOVE",b,headers:["Destination":a.absoluteString,"Overwrite":"T","If":condition(a,etag:av.etag),"If-Match":bv.etag])
            try accepted(moved.1,[201,204]); guard try await send("GET",a).0 == bData else { throw RemoteRotationError.unsafeServer }
            await removeOwned(a,etag:try await version(a).etag)
            return .version
        } catch {
            if let v = try? await version(a) { await removeOwned(a,etag:v.etag) }
            if let v = try? await version(b) { await removeOwned(b,etag:v.etag) }
            throw error
        }
    }
    private func persist(_ receipt: VideoRotationReceipt) throws {
        try RecoverableStore<VideoRotationReceipt>(file:journalDirectory.appendingPathComponent(receipt.id.uuidString+".json")).save(receipt)
    }
    static func digest(_ file: URL, excluding range: Range<UInt64>? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom:file); defer { try? handle.close() }
        var hash = SHA256(), offset: UInt64 = 0
        while let data = try handle.read(upToCount:1024*1024), !data.isEmpty {
            try Task.checkCancellation()
            if let range, range.overlaps(offset..<offset+UInt64(data.count)) {
                let start = Int(max(offset,range.lowerBound)-offset), end = Int(min(offset+UInt64(data.count),range.upperBound)-offset)
                hash.update(data:data.prefix(start)); hash.update(data:data.suffix(from:end))
            } else { hash.update(data:data) }
            offset += UInt64(data.count)
        }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
