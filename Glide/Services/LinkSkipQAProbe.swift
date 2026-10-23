#if DEBUG
import SwiftUI

struct LinkSkipQAProbe: View {
    var library: LibraryStore
    @State private var playback = PlaybackController()
    @State private var checks: [String] = []
    @State private var stage = "链接与跳过验证准备中"
    @State private var failure: String?
    private var base: String { UserDefaults.standard.string(forKey: "glideLinkFixtureAddress") ?? "http://127.0.0.1:8770" }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(presentation: playback.presentation, onLayer: { playback.attachLayer($0) }, identity: playback.current?.id ?? "link-qa", title: "Link QA", frameReady: playback.frameReady, locked: true, filled: false, onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in })
            VStack { Text(stage).accessibilityIdentifier("link.probe.status"); Text("通过 \(checks.count) 项"); if let failure { Text(failure) }; Spacer() }.padding(36).foregroundStyle(.white)
        }.task { await run() }.onDisappear { playback.close(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    @MainActor private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw MediaError.message(message) }
    }
    @MainActor private func save(_ passed: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "stage": stage, "error": failure ?? "", "version": PlaybackPreferences.appVersion, "device": UIDevice.current.model, "os": UIDevice.current.systemVersion, "scope": "Production HTTP/STRM/Keychain/native playback/skip sessions and authored Jellyfin API", "timestamp": ISO8601DateFormatter().string(from: Date())], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("link-skip-probe.json"), options: .atomic)
    }
    @MainActor private func record(_ name: String) throws { checks.append(name); try save() }
    @MainActor private func wait(checkErrors: Bool = true, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while !condition() || playback.isSeeking {
            try Task.checkCancellation()
            if checkErrors, let error = playback.error { throw MediaError.message(error) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MediaError.message("等待超时：" + stage) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    @MainActor private func open(_ video: Video, autoplay: Bool = false) async throws {
        playback.open(video, library: library, autoplay: autoplay, recordsProgress: false)
        if case .native(let player) = playback.presentation { player.isMuted = true }
        try await wait { playback.frameReady && playback.duration > 10 }
    }
    @MainActor private func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        do {
            let store = StreamLinkStore.shared
            // Only remove this probe's authored records; leave user-added QA links alone.
            for record in store.links where record.name.hasPrefix("1.6 QA ") { try store.remove(record, library: library) }
            stage = "验证 STRM 与钥匙串"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("1.6-QA.strm")
            try Data((base + "/sample.mp4?token=fixture-secret").utf8).write(to: file)
            let strm = try await StreamLinkStore.readSTRM(file)
            try FileManager.default.removeItem(at: file)
            let plain = try store.save(name: "1.6 QA STRM", payload: strm)
            store.reload()
            try require(try store.payload(plain.id) == strm, "STRM 恢复失败")
            let metadata = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StreamLinks/links-v1.json")
            try require(!(try String(contentsOf: metadata, encoding: .utf8)).contains("fixture-secret"), "播放秘密写入了片库")
            try record("strm:managed-link-keychain-reload-no-plaintext-secret")
            let refreshed = try store.save(name: plain.name, payload: StreamLinkPayload.parse(base + "/sample.mp4?token=refreshed-fixture"), replacing: plain.id, keepIdentity: true)
            try require(refreshed.video.id == plain.video.id, "更新过期签名应保留媒体身份")
            let unconfirmed = try store.save(name: plain.name, payload: StreamLinkPayload.parse(base + "/sample.mp4?item=other"), replacing: plain.id)
            try require(unconfirmed.video.id != refreshed.video.id, "未确认的查询参数变化错误沿用旧身份")
            let secure = try store.save(name: "1.6 QA 请求头", payload: StreamLinkPayload.parse(base + "/protected.mp4", headers: "Authorization: Bearer fixture160"), replacing: plain.id)
            try require(secure.video.id != plain.video.id, "更换内容未更新媒体身份")
            do { _ = try StreamLinkStore.playback(plain.video); throw MediaError.message("旧媒体身份仍能打开新内容") }
            catch { try require(error.localizedDescription.contains("重新打开"), "旧身份校验失败") }
            try record("links:expired-url-refresh-and-replacement-identity")
            stage = "验证带认证的 HTTP 播放与暂停定位"
            try await open(secure.video)
            playback.seek(6)
            try await wait { abs(playback.time - 6) < 0.3 }
            try require(!playback.isPlaybackRequested, "暂停定位改变了播放意图")
            try record("http:authenticated-range-frame-and-paused-seek")
            stage = "验证手动片头片尾与规则恢复"
            var rule = PlaybackSkipRule(); rule.intro = 4; rule.outro = 2
            try playback.skips.save(rule, series: false, duration: playback.duration)
            playback.seek(1); try await wait { playback.time < 1.5 }
            let intro = try active()
            playback.skip(intro); try await wait { playback.time >= 3.8 }
            try require(!playback.isPlaybackRequested, "跳过片头破坏暂停")
            playback.seek(10.5); try await wait { playback.time >= 10.3 }
            playback.skip(try active()); try await wait { playback.time >= 11.6 }
            try require(!playback.isPlaybackRequested, "跳过片尾破坏暂停")
            try record("skip:manual-intro-outro-preserve-pause")
            try await open(secure.video)
            try require(playback.skips.rule.intro == 4 && playback.skips.rule.outro == 2, "规则未恢复")
            rule.automatic = true
            try playback.skips.save(rule, series: false, duration: playback.duration)
            try await Task.sleep(for: .milliseconds(600))
            try require(playback.time < 2, "暂停时自动跳过")
            playback.toggle()
            try await wait { playback.time >= 4 }
            playback.pause(); playback.seek(0.5)
            try await wait { playback.time < 1.5 }
            playback.toggle()
            try await Task.sleep(for: .milliseconds(900))
            try require(playback.time < 3.5, "回拖后自动反复跳过")
            playback.pause()
            try record("skip:restore-auto-only-playing-once-and-backseek")
            stage = "验证原生 HLS"
            let hls = try store.save(name: "1.6 QA HLS", payload: StreamLinkPayload.parse(base + "/hls/sample.m3u8"))
            try await open(hls.video)
            playback.seek(7); try await wait { abs(playback.time - 7) < 0.4 }
            try require(playback.skips.rule.intro == 0, "不同链接串用跳过规则")
            try record("hls:frame-paused-seek-and-link-rule-isolation")
            stage = "验证认证失败与跨来源重定向拒绝"
            for path in ["/protected.mp4", "/redirect.mp4"] {
                // A valid token makes the redirect case fail if credentials are incorrectly forwarded.
                let token = path == "/redirect.mp4" ? "fixture160" : "invalid-fixture"
                let payload = try StreamLinkPayload.parse(base + path, headers: "Authorization: Bearer " + token)
                let rejected = try store.save(name: "1.6 QA 拒绝", payload: payload)
                playback.open(rejected.video, library: library, recordsProgress: false)
                try await wait(checkErrors: false) { playback.error != nil }
                try store.remove(rejected, library: library)
            }
            try record("http:auth-failure-and-cross-origin-redirect-rejected")
            playback.close()
            stage = "验证 Jellyfin 真实片段请求"
            let address = try ServerURL.parse(base + "/jellyfin")
            let server = library.servers.first { $0.name == "1.6 QA Jellyfin" && $0.address == address }
                ?? MediaServer(name: "1.6 QA Jellyfin", kind: .jellyfin, address: address, username: "fixture", userID: "fixture-user")
            try Credentials.save("fixture160-token", for: server.id)
            if !library.servers.contains(where: { $0.id == server.id }) { library.servers.append(server); library.persist() }
            try PlaybackSkipSession.remove(sourceID: server.id)
            let a = Video(id: server.id.uuidString + "a", title: "Jellyfin 标记样例", subtitle: "原创验证", sourceID: server.id, remoteID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", duration: 12, mediaType: "Episode", seriesID: "fixture-series")
            try await open(a)
            try await wait { !playback.skips.loading }
            try require(playback.skips.serverSegments.count == 2 && playback.activeSkip?.kind == .intro, "服务器片段未正确关联")
            try record("jellyfin:authenticated-segment-endpoint-and-native-playback")
            var grouped = PlaybackSkipRule(); grouped.intro = 2
            try playback.skips.save(grouped, series: true, duration: 12)
            var b = a; b.id += "b"; b.remoteID = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            playback.skips.prepare(video: b, server: server)
            try await wait { !playback.skips.loading }
            try require(playback.skips.usesSeries && playback.skips.rule.intro == 2, "节目规则未跨集恢复")
            var otherAccount = server; otherAccount.username = "other-fixture"
            playback.skips.prepare(video: b, server: otherAccount)
            try require(playback.skips.rule.intro == 0, "规则跨账号串用")
            try record("skip:series-rule-and-account-isolation")
            var missing = a; missing.remoteID = "missing"
            playback.skips.prepare(video: missing, server: server)
            try await wait { !playback.skips.loading }
            try require(playback.skips.serverSegments.isEmpty && playback.skips.message != nil, "缺接口未回退手动规则")
            try record("jellyfin:missing-endpoint-nonblocking-fallback")
            var delayed = a; delayed.remoteID = "delayed"
            playback.skips.prepare(video: delayed, server: server)
            try await Task.sleep(for: .milliseconds(250))
            playback.skips.prepare(video: hls.video, server: nil)
            try await Task.sleep(for: .milliseconds(1400))
            try require(playback.skips.serverSegments.isEmpty && playback.skips.rule.intro == 0, "旧片段回调覆盖新视频")
            try record("cancel:old-segments-cannot-overwrite-new-video")
            try store.remove(secure, library: library)
            try require(Credentials.read(secure.id) == nil && !store.links.contains(where: { $0.id == secure.id }), "链接删除未清理钥匙串")
            try record("links:delete-removes-keychain-and-associated-state")
            playback.close(); stage = "链接与跳过验证通过"; try save(true)
        } catch { failure = error.localizedDescription + "；位置 \(playback.time) / \(playback.duration)；\(playback.currentState)"; playback.close(); stage = "链接与跳过验证未完成"; try? save() }
    }
    @MainActor private func active() throws -> SkipSegment {
        guard let segment = playback.activeSkip else { throw MediaError.message("当前时点没有跳过入口：" + String(playback.time)) }
        return segment
    }
}
#endif
