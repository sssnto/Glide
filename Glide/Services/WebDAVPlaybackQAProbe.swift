#if DEBUG
import SwiftUI

/// Uses the production controller and surface. The live mode reads exactly the
/// URL supplied at launch using an already saved source; exports no URL/auth.
struct WebDAVPlaybackQAProbe: View {
    let library: LibraryStore
    @State private var playback = PlaybackController()
    @State private var stage = "准备 WebDAV 播放验证"
    @State private var checks: [String] = []
    @State private var passed = false
    @State private var diagnostics: [PlaybackDiagnostic] = []
    private var live: Bool { ProcessInfo.processInfo.arguments.contains("--glide-webdav-playback-investigate") }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(presentation: playback.presentation, onLayer: { playback.attachLayer($0) },
                identity: playback.current?.id ?? "webdav-probe", title: "WebDAV 验证", frameReady: playback.frameReady,
                locked: true, filled: false, onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in })
            VStack { Text(stage).font(.caption).accessibilityIdentifier("dav.playback.status"); Text("已完成 \(checks.count) 项").font(.caption); Spacer() }
                .foregroundStyle(.white).padding(30)
        }.task { await run() }.onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { playback.close(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    @MainActor private func wait(_ description: String, seconds: Double = 35, until condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            try Task.checkCancellation()
            if let error = playback.error { throw MediaError.message(description + "：" + error) }
            guard Date() < end else { throw MediaError.message(description + "超时") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    @MainActor private func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw MediaError.message(name) }; checks.append(name)
    }
    @MainActor private func save(_ error: Error? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let report: [String: Any] = ["version": PlaybackPreferences.appVersion, "passed": passed, "stage": stage,
            "checks": checks, "error": error?.localizedDescription ?? "", "live": live,
            "os": UIDevice.current.systemVersion, "timestamp": ISO8601DateFormatter().string(from: Date())]
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: root.appendingPathComponent("WebDAVPlaybackQA.json"), options: .atomic) }
        if let data = try? JSONEncoder().encode(diagnostics) { try? data.write(to: root.appendingPathComponent("WebDAVPlaybackDiagnostics.json"), options: .atomic) }
    }
    @MainActor private func open(_ file: URL, server: MediaServer, resume: Double = 3) async throws {
        playback.close(); playback = PlaybackController(); playback.inspectionMode = true
        let video = Video(id: "webdav-qa-" + UUID().uuidString, title: "原创 WebDAV 验证", subtitle: "", sourceID: server.id, url: file)
        playback.open(video, library: library, resumeAt: resume, autoplay: true, recordsProgress: false)
        try await wait("首帧") { playback.frameReady }
        try check(playback.diagnostic.outputWidth ?? 0 > 0, "实际解码画面尺寸非零")
    }
    @MainActor private func bridgeChecks(root: URL) async throws {
        let headers = ["Authorization": "Basic " + Data("glide:playback-fixture".utf8).base64EncodedString()]
        for (file, range, status) in [("binary.bin", "bytes=131072-196607", 206), ("binary.bin", "bytes=-32", 206), ("same-origin.bin", "bytes=0-31", 206), ("bad-range.bin", "bytes=100-199", 502), ("ignored-range.bin", "bytes=100-199", 502), ("redirect.bin", "bytes=0-31", 502)] {
            let bridge = WebDAVPlaybackBridge(url: root.appendingPathComponent(file), headers: headers, allowsCellular: false)
            defer { bridge.stop() }
            let local = try await bridge.start()
            var request = URLRequest(url: local); request.setValue(range, forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request); bridge.stop()
            try check((response as? HTTPURLResponse)?.statusCode == status, "认证分段读取 " + file + " " + range)
            if status == 206 {
                let start = range == "bytes=-32" ? 224 : 0
                try check(data.enumerated().allSatisfy { $0.element == UInt8((start + $0.offset) % 256) }, "分段内容逐字节匹配")
            }
        }
        let bridge = WebDAVPlaybackBridge(url: root.appendingPathComponent("binary.bin"), headers: headers, allowsCellular: false)
        defer { bridge.stop() }
        let local = try await bridge.start()
        var head = URLRequest(url: local); head.httpMethod = "HEAD"
        let (data, response) = try await URLSession.shared.data(for: head)
        try check(data.isEmpty && (response as? HTTPURLResponse)?.expectedContentLength == 2 * 1024 * 1024, "HEAD 返回真实长度且没有正文")
        var wrong = URLComponents(url: local, resolvingAgainstBaseURL: false)!; wrong.path = "/wrong"
        let (_, rejected) = try await URLSession.shared.data(from: wrong.url!)
        try check((rejected as? HTTPURLResponse)?.statusCode == 400, "其他路径不可访问上游")
        bridge.stop()
    }
    @MainActor private func run() async {
        do {
            if live {
                guard let value = UserDefaults.standard.string(forKey: "glideWebDAVPlaybackInvestigateURL"), let file = URL(string: value),
                      let server = library.servers.first(where: { $0.kind == .webDAV && WebDAVPlaybackPolicy.accepts(file: file, root: $0.address) }) else { throw MediaError.message("没有匹配所选文件的已保存 WebDAV 连接") }
                stage = "读取原片并验证实际视频画面"
                try await open(file, server: server, resume: 0)
                try await wait("持续播放", seconds: 20) { playback.time >= 8 }
                try check(playback.frameReady, "原片持续输出画面")
                let target = min(15, max(0, playback.duration - 3))
                playback.seek(target)
                try await wait("原片定位") { !playback.isSeeking && abs(playback.time - target) < 2 && playback.frameReady }
                try check(true, "原片定位后继续输出画面")
                diagnostics.append(playback.diagnostic)
            } else {
                let root = URL(string: UserDefaults.standard.string(forKey: "glideWebDAVPlaybackFixtureAddress") ?? "http://127.0.0.1:8827/")!
                stage = "检查认证、Range 与读取边界"
                try await bridgeChecks(root: root)
                let server = MediaServer(name: "原创 WebDAV 播放", kind: .webDAV, address: root, username: "glide")
                try Credentials.save("playback-fixture", for: server.id); defer { Credentials.delete(server.id) }
                library.servers = [server]
                stage = "系统原画播放与暂停切换"
                try await open(root.appendingPathComponent("native.mp4"), server: server)
                try check(playback.engineDescriptor.id == .avPlayer, "兼容 MP4 保留系统内核")
                playback.pause(); let position = playback.time
                playback.switchEngine(to: .vlc)
                try await wait("手动兼容首帧") { playback.engineDescriptor.id == .vlc && playback.frameReady }
                try check(!playback.isPlaybackRequested && abs(playback.time - position) < 1.5, "切换内核保留暂停与进度")
                playback.play(); playback.seek(12)
                try await wait("兼容定位") { !playback.isSeeking && playback.time >= 11 && playback.frameReady }
                try check(playback.audioOptions.count >= 2, "兼容流识别多个音轨")
                if let other = playback.audioOptions.first(where: { $0.id != playback.selectedAudio?.id }) {
                    playback.selectAudio(other)
                    try await wait("音轨切换") { playback.selectedAudio?.id == other.id }
                    try check(true, "兼容流切换音轨")
                }
                diagnostics.append(playback.diagnostic)
                stage = "AVC High 10 自动回退"
                try await open(root.appendingPathComponent("high10.mp4"), server: server)
                try check(playback.engineDescriptor.id == .vlc && playback.diagnostic.events.contains("webdav_recovery_vlc"), "系统无画面自动切换兼容且只回退一次")
                try check(playback.diagnostic.recoveryCount == 1, "自动回退次数为一")
                try await wait("回退后持续播放") { playback.time >= 6 }
                diagnostics.append(playback.diagnostic)
                stage = "MKV 直接兼容与取消旧播放"
                try await open(root.appendingPathComponent("compat.mkv"), server: server)
                try check(playback.engineDescriptor.id == .vlc && playback.diagnostic.recoveryCount == 0, "MKV 直接使用兼容内核")
                diagnostics.append(playback.diagnostic)
                playback.close()
                try await open(root.appendingPathComponent("native.mp4"), server: server)
                try check(playback.engineDescriptor.id == .avPlayer && playback.diagnostic.recoveryCount == 0, "旧兼容会话不影响新视频")
            }
            passed = true; stage = "验证通过"; save(); playback.close()
        } catch { diagnostics.append(playback.diagnostic); stage = "验证失败"; save(error); playback.close() }
    }
}
#endif
