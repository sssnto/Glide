import Foundation
import Testing
@testable import GlideCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GLIDE_ROTATION_HTTP_FIXTURE"] == "1"))
struct RemoteVideoRotationTests {
    private let auth = "Basic " + Data("glide:rotation-fixture".utf8).base64EncodedString()
    private func setup(_ mode: String) -> (RemoteVideoRotation, URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = URL(string:"http://127.0.0.1:8828/\(mode)-\(UUID().uuidString)/")!
        return (RemoteVideoRotation(sourceID:UUID(),root:root,authorization:auth,journalDirectory:folder),root.appendingPathComponent("original.mp4"),folder)
    }
    private func data(_ file: URL, method: String = "GET", body: Data? = nil) async throws -> Data {
        var r=URLRequest(url:file);r.httpMethod=method;r.httpBody=body;r.setValue(auth,forHTTPHeaderField:"Authorization")
        let (data,response)=try await URLSession.shared.data(for:r)
        #expect((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true)
        return data
    }

    @Test func lockProtectedSaveAndExactBackupRestore() async throws {
        let (client,url,journal)=setup("lock")
        defer { try? FileManager.default.removeItem(at:journal) }
        let before=try await data(url), prepared=try await client.prepare(url)
        defer { try? FileManager.default.removeItem(at:prepared.workspace) }
        let receipt=try await client.save(prepared,turn:.clockwise)
        #expect(receipt.state == "saved")
        let after=try await data(url), backup=try await data(receipt.backup)
        #expect(after != before && after.count == before.count && backup == before)
        let restored=try await client.restore(receipt)
        #expect(restored.state == "saved")
        let original=try await data(url)
        #expect(original == before)
    }
    @Test func destinationVersionProtectionWorksWithoutLocks() async throws {
        let (client,url,journal)=setup("version")
        defer { try? FileManager.default.removeItem(at:journal) }
        let prepared=try await client.prepare(url)
        defer { try? FileManager.default.removeItem(at:prepared.workspace) }
        let receipt=try await client.save(prepared,turn:.counterclockwise)
        #expect(receipt.state == "saved")
        let verified=try await client.resolve(receipt)
        #expect(verified.savedDigest == receipt.savedDigest && verified.state == "saved")
    }
    @Test func brokenAdvertisedLocksCanUseIndependentlyProvenVersionProtection() async throws {
        let (client,url,journal)=setup("brokenlock")
        defer { try? FileManager.default.removeItem(at:journal) }
        let before=try await data(url),prepared=try await client.prepare(url)
        defer { try? FileManager.default.removeItem(at:prepared.workspace) }
        let receipt=try await client.save(prepared,turn:.clockwise)
        #expect(receipt.state == "saved")
        _=try await client.restore(receipt)
        let after=try await data(url)
        #expect(after == before)
    }
    @Test func brokenLocksAndIgnoredVersionConditionsStillRefuseOriginal() async throws {
        let (client,url,journal)=setup("brokenunsafe")
        defer { try? FileManager.default.removeItem(at:journal) }
        let before=try await data(url)
        do { _=try await client.prepare(url);Issue.record("Both protections broken must be rejected") }
        catch RemoteRotationError.unsafeServer {} catch { Issue.record("Unexpected rejection: \(error)") }
        let after=try await data(url)
        #expect(after == before)
    }
    @Test func abandonedValidationCleanupRequiresAuthoredNameAndExactBytes() async throws {
        let (client,url,journal)=setup("version")
        defer { try? FileManager.default.removeItem(at:journal) }
        let before=try await data(url)
        let local=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        try before.write(to:local);defer { try? FileManager.default.removeItem(at:local) }
        let owned=try await client.installValidationFixture(local)
        let changed=url.deletingLastPathComponent().appendingPathComponent("Glide-方向验证-"+UUID().uuidString+".mp4")
        let edited=Data(repeating:33,count:before.count)
        _=try await data(changed,method:"PUT",body:edited)
        let count=try await client.cleanAbandonedValidationFixtures([url,owned,changed],matching:local)
        #expect(count==1)
        let original=try await data(url),stillEdited=try await data(changed)
        #expect(original==before && stillEdited==edited)
    }
    @Test func serverIgnoringDestinationConditionsNeverTouchesOriginal() async throws {
        let (client,url,journal)=setup("unsafe")
        defer { try? FileManager.default.removeItem(at:journal) }
        let before=try await data(url)
        do { _=try await client.prepare(url);Issue.record("Unsafe server must be rejected") }
        catch RemoteRotationError.unsafeServer {} catch { Issue.record("Unexpected rejection: \(error)") }
        let after=try await data(url)
        #expect(after == before)
    }
    @Test func changedOriginalIsNotOverwritten() async throws {
        let (client,url,journal)=setup("version")
        defer { try? FileManager.default.removeItem(at:journal) }
        let prepared=try await client.prepare(url)
        defer { try? FileManager.default.removeItem(at:prepared.workspace) }
        let changed=Data("A different edit owns this filename".utf8)
        _=try await data(url,method:"PUT",body:changed)
        do { _=try await client.save(prepared,turn:.clockwise);Issue.record("Changed file must not be replaced") }
        catch RemoteRotationError.changed {} catch { Issue.record("Unexpected rejection: \(error)") }
        let after=try await data(url)
        #expect(after == changed)
    }
    @Test func backupFailureLeavesOriginalUntouched() async throws {
        let (client,url,journal)=setup("copyfail")
        defer { try? FileManager.default.removeItem(at:journal) }
        let before=try await data(url), prepared=try await client.prepare(url)
        defer { try? FileManager.default.removeItem(at:prepared.workspace) }
        do { _=try await client.save(prepared,turn:.upsideDown);Issue.record("Backup failure must stop replacement") }
        catch RemoteRotationError.http(507) {} catch { Issue.record("Unexpected rejection: \(error)") }
        let after=try await data(url)
        #expect(after == before)
    }
    @Test func lostMoveReplyIsRecoverableFromDurableReceipt() async throws {
        let (client,url,journal)=setup("lost")
        defer { try? FileManager.default.removeItem(at:journal) }
        let prepared=try await client.prepare(url)
        defer { try? FileManager.default.removeItem(at:prepared.workspace) }
        do { _=try await client.save(prepared,turn:.clockwise);Issue.record("Lost response must remain unconfirmed") }
        catch RemoteRotationError.uncertain {} catch { Issue.record("Unexpected rejection: \(error)") }
        let files=try FileManager.default.contentsOfDirectory(at:journal,includingPropertiesForKeys:nil).filter { $0.pathExtension == "json" }
        let file=try #require(files.first)
        let pending=try #require(RecoverableStore<VideoRotationReceipt>(file:file).load()?.value)
        #expect(pending.state == "needs-verification")
        let resolved=try await client.resolve(pending)
        #expect(resolved.state == "saved")
    }
    @Test func filesOutsideConnectedDirectoryAreRejected() async throws {
        let (client,url,journal)=setup("version")
        defer { try? FileManager.default.removeItem(at:journal) }
        let outside=url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("outside.mp4")
        do { _=try await client.prepare(outside);Issue.record("Outside path must be rejected") }
        catch RemoteRotationError.outsideDirectory {} catch { Issue.record("Unexpected rejection: \(error)") }
    }
}
