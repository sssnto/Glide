import SwiftUI

@main
struct GlideApp: App {
    @UIApplicationDelegateAdaptor(GlideAppDelegate.self) private var appDelegate
    @State private var library = LibraryStore()
    var body: some Scene {
        WindowGroup {
            root
                .preferredColorScheme(.dark)
                .tint(GlideTheme.accent)
                .foregroundStyle(GlideTheme.text)
                #if DEBUG
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--glide-jellyfin-fixture") {
                        do { try await library.prepareJellyfinFixture() }
                        catch { library.error = "服务器验证准备失败：" + error.localizedDescription }
                    } else if ProcessInfo.processInfo.arguments.contains("--glide-format-fixtures") {
                        do { try await library.prepareFormatFixtures() }
                        catch { library.error = "格式验证准备失败：" + error.localizedDescription }
                    } else if ProcessInfo.processInfo.arguments.contains("--glide-local-fixture") {
                        do { try await library.prepareLocalFixture() }
                        catch { library.error = "本地验证准备失败：" + error.localizedDescription }
                    }
                }
                #endif
        }
    }
    @ViewBuilder private var root: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--glide-network-buffer-probe") {
            NetworkBufferQAProbe(library: library)
        } else if ProcessInfo.processInfo.arguments.contains("--glide-compatibility-probe") {
            CompatibilityQAProbe(library: library)
        } else { AdaptiveLibraryRoot(library: library) }
#else
        AdaptiveLibraryRoot(library: library)
#endif
    }
}

#if DEBUG
extension LibraryStore {
    /// The project's loopback-only synthetic server, using production authentication and storage.
    func prepareJellyfinFixture() async throws {
        let address = "http://127.0.0.1:8768/mock/jellyfin"
        let fixture = servers.first { $0.name == "Glide Recovery Fixture" && $0.address.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == address }
        if let fixture {
            // Reinstalling an unsigned simulator build can retain its snapshot
            // without retaining Keychain entries. Reauthenticate this fixed
            // local fixture rather than reusing an unusable test credential.
            let (token, _) = try await MediaClient.shared.signIn(server: fixture, password: "demo")
            try Credentials.save(token, for: fixture.id)
            // The synthetic server changes its catalog between recovery scenarios.
            await MediaCache.shared.clear(server: fixture)
            let key = "glide.learnedVideoConversion.v1"
            var learned = UserDefaults.standard.dictionary(forKey: key) ?? [:]
            for sample in ["broken", "buffer4k"] { learned.removeValue(forKey: fixture.id.uuidString + sample) }
            UserDefaults.standard.set(learned, forKey: key)
            // Prove that the explicit "from beginning" request wins over saved progress.
            positions[fixture.id.uuidString + "buffered"] = 30
            await select(fixture.id)
        }
        else { try await add(name: "Glide Recovery Fixture", kind: .jellyfin, address: address, username: "demo", password: "demo") }
    }
    /// Fixed synthetic QA directory in the simulator sandbox; no external path argument.
    func prepareFormatFixtures() async throws {
        UIApplication.shared.isIdleTimerDisabled = true
        UserDefaults.standard.set("videos", forKey: "homeBrowseView")
        UserDefaults.standard.set("sequential", forKey: "playbackMode")
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FormatFixtures")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) else {
            throw MediaError.message("请先生成并安装合成验证样例。")
        }
        if let existing = servers.first(where: { $0.name == "FormatFixtures" }) {
            UserDefaults.standard.removeObject(forKey: "localPath." + existing.id.uuidString)
            await select(existing.id)
        } else { try await mountLocalDirectory(root) }
    }
    /// Only bundled demos in an isolated simulator fixture; never touches user-selected files.
    func prepareLocalFixture() async throws {
        UserDefaults.standard.set("videos", forKey: "homeBrowseView")
        UserDefaults.standard.set("sequential", forKey: "playbackMode")
        if let existing = servers.first(where: { $0.name == "本地验证目录" }) {
            favorites = favorites.filter { !$0.hasPrefix(existing.id.uuidString + ":local:") }
            guard persist() else { throw MediaError.message("无法重置验证目录的收藏状态。") }
            if let imported = servers.first(where: { $0.kind == .local && $0.localBookmark == nil }),
               !FileManager.default.fileExists(atPath: LocalMediaStore.managedDirectory(imported.id).appendingPathComponent("demo0 (2).mp4").path) {
                _ = try await importLocalVideos([Bundle.main.url(forResource: "demo0", withExtension: "mp4")!])
            }
            UserDefaults.standard.removeObject(forKey: "localPath." + existing.id.uuidString)
            await select(existing.id); return
        }
        let manager = FileManager.default
        let root = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalFixture/本地验证目录")
        try manager.createDirectory(at: root.appendingPathComponent("子目录"), withIntermediateDirectories: true)
        let first = Bundle.main.url(forResource: "demo0", withExtension: "mp4")!
        let second = Bundle.main.url(forResource: "demo1", withExtension: "mp4")!
        for (source, name) in [(first, "本地片段.mp4"), (second, "子目录/第二片段.mp4")] {
            let target = root.appendingPathComponent(name)
            if !manager.fileExists(atPath: target.path) { try manager.copyItem(at: source, to: target) }
        }
        _ = try await importLocalVideos([first, second])
        _ = try await importLocalVideos([first]) // Exercise collision-safe names through the production path.
        // A rejected selection must not publish the valid first file of the same batch.
        let invalid = root.appendingPathComponent("notes.txt")
        try Data("fixture".utf8).write(to: invalid)
        do {
            _ = try await importLocalVideos([second, invalid])
            throw MediaError.message("混合导入未被拒绝。")
        } catch let error as MediaError {
            if error.localizedDescription == "混合导入未被拒绝。" { throw error }
        }
        try await mountLocalDirectory(root)
    }
}
#endif
