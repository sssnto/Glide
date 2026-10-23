#if DEBUG
import SwiftUI

/// Opt-in authored loopback fixture. Runs production provider/controller/rendering.
struct SMBQAProbe: View {
    let library: LibraryStore
    @State private var playback = PlaybackController()
    @State private var stage = "SMB 验证"
    @State private var checks: [String] = []
    @State private var measurements: [String: Double] = [:]
    @State private var failedMessage: String?
    @State private var runID = UUID()
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(presentation: playback.presentation, onLayer: { playback.attachLayer($0) },
                identity: playback.current?.id ?? "smb", title: "SMB QA", frameReady: playback.frameReady,
                locked: true, filled: false, onSwipe: { _ in }, onToggle: {}, onSeek: { _ in }, onSpeedPreset: { _ in }, onHUD: { _ in })
            VStack {
                Text(stage).accessibilityIdentifier("smb.probe.status"); Text("通过 \(checks.count) 项")
                if let failedMessage {
                    Text(failedMessage)
                    Button("重新验证") { runID = UUID() }
                    Button("打开应用设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
                Spacer(); Text(playback.time.mediaTime)
            }
                .font(.caption).foregroundStyle(.white).padding(36)
        }.task(id: runID) { await run() }
            .onDisappear { playback.stop(); UIApplication.shared.isIdleTimerDisabled = false }
    }
    @MainActor private func save(passed: Bool = false, error: String? = nil) throws {
        let report: [String: Any] = ["passed": passed, "stage": stage, "checks": checks,
            "measurements": measurements, "error": error ?? "", "version": PlaybackPreferences.appVersion,
            "os": UIDevice.current.systemVersion, "device": UIDevice.current.model,
            "scope": ProcessInfo.processInfo.arguments.contains("--glide-smb-lan-probe") ? "Authored Samba over LAN; production provider, controller and rendered VideoSurface" : "Authored loopback Samba; production provider, controller and rendered VideoSurface",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "diagnostic": (try? JSONSerialization.jsonObject(with: Data(playback.diagnostic.export.utf8))) ?? [:]]
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("smb-probe.json"), options: .atomic)
    }
    @MainActor private func record(_ name: String) throws { checks.append(name); try save() }
    @MainActor private func wait(_ name: String, seconds: Double = 25, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try Task.checkCancellation()
            if let error = playback.error { throw MediaError.message(name + ": " + error) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MediaError.message(name + " 超时：" + playback.currentState) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    @MainActor private func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        failedMessage = nil; checks = []; measurements = [:]
        do {
            try save()
            try await wait("等待应用进入前台", seconds: 10) { UIApplication.shared.applicationState == .active }
            if ProcessInfo.processInfo.arguments.contains("--glide-smb-lan-probe") { try await lanOnly(); return }
            if ProcessInfo.processInfo.arguments.contains("--glide-smb-seek-probe") { try await precisionOnly(); return }
            var server = MediaServer(name: "SMB QA", kind: .smb, address: try SMBLocation.parse(address: "127.0.0.1:1445", share: "media"), username: "glide")
            server.smb = SMBOptions()
            let entries = try await SMBSourceProvider.entries(server: server, directory: nil, password: "glide150-fixture")
            guard entries.contains(where: { $0.name == "中文 空格 #%.mp4" }) else { throw MediaError.message("特殊文件名枚举失败") }
            try record("list:unicode-space-percent-hash")
            let access = try SMBAccess(server: server, password: "glide150-fixture")
            let data = try await access.perform { try $0.read("range.txt", offset: 6, length: 9) }
            guard String(data: data, encoding: .utf8) == "SMB range" else { throw MediaError.message("指定范围读取失败") }
            let eof = try await access.perform { try $0.read("range.txt", offset: 99999, length: 10) }
            guard eof.isEmpty else { throw MediaError.message("EOF 读取失败") }
            try record("read:offset-short-read-eof")
            let deep = server.address.appendingPathComponent("家庭 视频/第二层/第三层")
            let large = try await SMBSourceProvider.entries(server: server, directory: deep, password: "glide150-fixture")
            guard large.count == 1000 else { throw MediaError.message("大目录条目不完整：\(large.count)") }
            try record("list:1000-entries-three-levels")
            do {
                _ = try await SMBSourceProvider.entries(server: server, directory: nil, password: "wrong-fixture-password")
                throw MediaError.message("错误密码被接受")
            } catch let error as MediaError {
                guard error.localizedDescription.contains("认证") else { throw error }
            }
            try record("auth:wrong-password-rejected")
            do {
                _ = try await access.perform { try $0.size("does-not-exist.mp4").uint64Value }
                throw MediaError.message("缺失文件未被拒绝")
            } catch let error as MediaError {
                guard error.localizedDescription.contains("不存在") else { throw error }
            }
            try record("error:missing-file")
            var denied = server
            denied.address = try SMBLocation.parse(address: "127.0.0.1:1447", share: "private")
            do {
                _ = try await SMBSourceProvider.entries(server: denied, directory: nil, password: "glide150-fixture")
                throw MediaError.message("无权限共享未被拒绝")
            } catch let error as MediaError {
                guard error.localizedDescription.contains("权限") else { throw error }
            }
            try record("error:permission-distinct-from-auth")
            var blocked = server
            blocked.address = try SMBLocation.parse(address: "127.0.0.1:15445", share: "media")
            let blockedSource = blocked
            let tasks = (0..<8).map { _ in Task { try await SMBSourceProvider.entries(server: blockedSource, directory: nil, password: "glide150-fixture") } }
            try await Task.sleep(for: .milliseconds(300))
            let cancelledAt = ProcessInfo.processInfo.systemUptime
            tasks.forEach { $0.cancel() }
            for task in tasks {
                do { _ = try await task.value; throw MediaError.message("取消后操作仍返回成功") }
                catch is CancellationError { }
            }
            measurements["cancelEightOperationsSeconds"] = ProcessInfo.processInfo.systemUptime - cancelledAt
            _ = try await SMBSourceProvider.entries(server: server, directory: nil, password: "glide150-fixture")
            try record("cancel:eight-active-and-queued-then-reconnect")
            var guest = server; guest.address = try SMBLocation.parse(address: "127.0.0.1:1445", share: "guest"); guest.username = ""; guest.smb = SMBOptions(guest: true)
            _ = try await SMBSourceProvider.entries(server: guest, directory: nil, password: "")
            try record("auth:guest")
            for port in [1446, 1447, 1448] {
                var candidate = server
                candidate.address = try SMBLocation.parse(address: "127.0.0.1:\(port)", share: "media")
                candidate.smb = SMBOptions(encrypted: port == 1448)
                _ = try await SMBSourceProvider.entries(server: candidate, directory: nil, password: "glide150-fixture")
                try record("protocol-fixture:\(port)")
            }
            if let previous = library.servers.first(where: { $0.name == "SMB QA" }) { library.remove(previous) }
            try await library.add(name: "SMB QA", kind: .smb, address: server.address.absoluteString, username: "glide", password: "glide150-fixture")
            try record("source:save-browse-keychain")
            let sameNames = library.videos.filter { $0.title == "相同名称.mp4" }
            guard sameNames.count == 2, Set(sameNames.map(\.id)).count == 2 else { throw MediaError.message("不同目录下的同名媒体身份冲突") }
            try record("identity:same-name-different-directories")
            for name in ["1080p.mp4", "11-hd-dual-ass.mkv", "中文 空格 #%.mp4", "特殊 @+ &%#.mp4", "4k-hevc.mp4"] {
                guard let video = library.videos.first(where: { $0.title == name }) else { throw MediaError.message("缺少原创片源：" + name) }
                stage = name; playback.stop()
                let start = ProcessInfo.processInfo.systemUptime
                playback.open(video, library: library, autoplay: true, recordsProgress: false)
                try await wait("首帧") { playback.frameReady }
                measurements["firstFrame:" + name] = ProcessInfo.processInfo.systemUptime - start
                if let bytes = playback.diagnostic.accessLogBytesTransferred { measurements["readBytesAtFirstFrame:" + name] = Double(bytes) }
                if name == "1080p.mp4" || name.hasSuffix(".mkv") {
                    let fileSize = try await SMBAccess(server: library.selectedServer!, password: "glide150-fixture").perform { try $0.size(name).doubleValue }
                    guard let bytes = playback.diagnostic.accessLogBytesTransferred, bytes > 0, Double(bytes) < fileSize else {
                        throw MediaError.message("首帧按需读取证据不足")
                    }
                    measurements["fileBytes:" + name] = fileSize
                }
                guard playback.engineDescriptor.id == .vlc else { throw MediaError.message("SMB 内核路由错误") }
                playback.pause()
                let target = playback.duration * 0.7
                playback.seek(target)
                try await wait("70% 暂停定位") { abs(playback.time - target) < 1 }
                guard !playback.isPlaying else { throw MediaError.message("定位后暂停意图丢失") }
                if name.hasSuffix(".mkv") {
                    try await wait("双音轨与 ASS") { playback.audioOptions.count == 2 && !playback.subtitleOptions.isEmpty }
                }
                try record("play-seek-pause:" + name)
            }
            for (port, options) in [(1446, SMBOptions()), (1447, SMBOptions()), (1448, SMBOptions(encrypted: true)), (1445, SMBOptions(encrypted: true)), (1445, SMBOptions(guest: true)), (1445, SMBOptions())] {
                var candidate = server; candidate.id = UUID(); candidate.smb = options
                let host = port == 1445 && !options.guest && !options.encrypted ? "localhost" : "127.0.0.1"
                candidate.address = try SMBLocation.parse(address: "\(host):\(port)", share: options.guest ? "guest" : "media")
                candidate.username = options.guest ? "" : "glide"
                try Credentials.save(options.guest ? "" : "glide150-fixture", for: candidate.id)
                library.servers.append(candidate)
                let video = Video(id: candidate.id.uuidString + ":protocol", title: "Protocol", subtitle: "", sourceID: candidate.id, url: candidate.address.appendingPathComponent("1080p.mp4"))
                playback.open(video, library: library, autoplay: true, recordsProgress: false)
                try await wait("协议播放 \(port)") { playback.frameReady }
                playback.pause(); playback.seek(42)
                try await wait("协议定位 \(port)") { abs(playback.time - 42) < 1 && !playback.isPlaying }
                playback.stop(); library.remove(candidate)
                try record("protocol-play-seek:\(port)-sealed:\(options.encrypted)-guest:\(options.guest)")
            }
            guard let video = library.videos.first(where: { $0.title == "1080p.mp4" }) else { throw MediaError.message("缺少长播样例") }
            for index in 0..<20 {
                let target = index % 2 == 0 ? 10.0 : 42.0
                playback.open(video, library: library, autoplay: false, recordsProgress: false)
                try await wait("定位准备") { playback.frameReady }
                playback.seek(5); playback.seek(50); playback.seek(target)
                try await wait("最后一次定位") { abs(playback.time - target) < 1 && !playback.isPlaying }
                playback.stop()
            }
            try record("seek:20-rapid-last-intent-paused")
            if ProcessInfo.processInfo.arguments.contains("--glide-smb-stress") || ProcessInfo.processInfo.arguments.contains("--glide-smb-recovery") {
                guard let longVideo = library.videos.first(where: { $0.title == "longplay.mp4" }) else { throw MediaError.message("缺少长播原创片源") }
                if ProcessInfo.processInfo.arguments.contains("--glide-smb-stress") {
                for index in 0..<50 {
                    stage = "切片 \(index + 1)/50"; try save()
                    playback.open(video, library: library, autoplay: true, recordsProgress: false)
                    try await wait("反复打开首帧") { playback.frameReady }
                    playback.stop()
                }
                try record("lifecycle:50-open-stop")
                }
                for index in 0..<5 {
                    playback.open(longVideo, library: library, resumeAt: 15, autoplay: true, recovering: true, recordsProgress: false)
                    try await wait("断网测试准备") { playback.frameReady && playback.time > 15 }
                    stage = "await-network-stop-\(index)"; try save()
                    try await wait("等待网络中断", seconds: 90) { playback.error != nil }
                    let position = playback.time
                    measurements["interruptedPosition:\(index)"] = position
                    stage = "await-network-return-\(index)"; try save()
                    try await Task.sleep(for: .seconds(5))
                    playback.retry()
                    try await wait("恢复播放", seconds: 35) { playback.frameReady && playback.error == nil && playback.isPlaying }
                    measurements["resumedPosition:\(index)"] = playback.time
                    guard playback.time >= position - 1, playback.time < position + 8 else { throw MediaError.message("恢复位置丢失") }
                    try record("network:reconnect-\(index)")
                }
                stage = "longplay-30-minutes"; try save()
                playback.open(longVideo, library: library, autoplay: true, recordsProgress: false)
                try await wait("长播准备") { playback.frameReady }
                let started = ProcessInfo.processInfo.systemUptime
                let initialTime = playback.time
                let deadline = started + 1800
                while ProcessInfo.processInfo.systemUptime < deadline {
                    try Task.checkCancellation()
                    if let error = playback.error { throw MediaError.message(error) }
                    try await Task.sleep(for: .seconds(2))
                }
                measurements["continuousPlaybackSeconds"] = ProcessInfo.processInfo.systemUptime - started
                measurements["continuousMediaSeconds"] = playback.time - initialTime
                guard playback.isPlaying, playback.time - initialTime >= 1770 else { throw MediaError.message("长播期间媒体时间未持续推进") }
                try record("playback:30-minutes")
            }
            playback.stop(); stage = "SMB 合成服务验收通过"; try save(passed: true)
        } catch {
            measurements["failedPlaybackTime"] = playback.time
            measurements["failedPlaybackDuration"] = playback.duration
            let failure = error as NSError
            measurements["failureCode"] = Double(failure.code)
            if ProcessInfo.processInfo.arguments.contains("--glide-smb-lan-probe") {
                // A fixed authored endpoint only; never export URL or request headers.
                var current: NSError? = failure
                for _ in 0..<5 {
                    guard let value = current else { break }
                    let path = String(describing: value.userInfo["_NSURLErrorNWPathKey"] ?? value.userInfo["NSURLErrorNWPathKey"] ?? "").lowercased()
                    if !path.isEmpty { measurements["networkPathDescriptionPresent"] = 1 }
                    if path.contains("local network prohibited") { measurements["localNetworkProhibited"] = 1 }
                    if path.contains("unsatisfied") { measurements["networkPathUnsatisfied"] = 1 }
                    current = value.userInfo[NSUnderlyingErrorKey] as? NSError
                }
            }
            playback.stop(); stage = "SMB 验证未通过"; failedMessage = error.localizedDescription; try? save(error: error.localizedDescription)
        }
    }
    @MainActor private func lanOnly() async throws {
        guard let host = UserDefaults.standard.string(forKey: "glideSMBFixtureAddress") else { throw MediaError.message("缺少局域网合成服务地址") }
        let address = try SMBLocation.parse(address: host, share: "media")
        var davParts = URLComponents(url: address, resolvingAgainstBaseURL: false)!
        davParts.scheme = "http"; davParts.port = 8769; davParts.path = "/dav/"
        let davName = "Glide 局域网 WebDAV 验证"
        if let previous = library.servers.first(where: { $0.name == davName }) { library.remove(previous) }
        stage = "局域网 WebDAV 连接"; try save()
        try await library.add(name: davName, kind: .webDAV, address: davParts.url!.absoluteString, username: "demo", password: "demo")
        guard let davVideo = library.videos.first else { throw MediaError.message("局域网 WebDAV 未返回视频") }
        let davStarted = ProcessInfo.processInfo.systemUptime
        playback.open(davVideo, library: library, autoplay: true, recordsProgress: false)
        try await wait("局域网 WebDAV 首帧") { playback.frameReady }
        guard playback.engineDescriptor.id == .avPlayer else { throw MediaError.message("WebDAV 未使用系统播放路线") }
        measurements["firstFrame:WebDAV"] = ProcessInfo.processInfo.systemUptime - davStarted
        playback.pause(); let davTarget = playback.duration * 0.5; playback.seek(davTarget)
        try await wait("WebDAV 暂停定位") { abs(playback.time - davTarget) < 1 && !playback.isPlaying }
        playback.stop()
        try record("lan:webdav-save-browse-native-play-seek")
        let name = "Glide 局域网验证"
        if let previous = library.servers.first(where: { $0.name == name }) { library.remove(previous) }
        try await library.add(name: name, kind: .smb, address: address.absoluteString, username: "glide", password: "glide150-fixture", remembersPlayback: true)
        guard let server = library.selectedServer else { throw MediaError.message("局域网来源未保存") }
        try record("lan:source-save-browse-keychain")
        let entries = try await SMBSourceProvider.entries(server: server, directory: address.appendingPathComponent("家庭 视频/第二层/第三层"), password: "glide150-fixture")
        guard entries.count == 1000 else { throw MediaError.message("局域网大目录结果不完整") }
        try record("lan:1000-entries-three-levels")
        let access = try SMBAccess(server: server, password: "glide150-fixture")
        let bytes = try await access.perform { try $0.read("range.txt", offset: 6, length: 9) }
        guard String(data: bytes, encoding: .utf8) == "SMB range" else { throw MediaError.message("局域网范围读取错误") }
        try record("lan:range-read")
        for file in ["1080p.mp4", "11-hd-dual-ass.mkv", "4k-hevc.mp4", "特殊 @+ &%#.mp4"] {
            guard let video = library.videos.first(where: { $0.title == file }) else { throw MediaError.message("局域网素材缺失") }
            stage = "局域网播放 " + file; try save()
            let started = ProcessInfo.processInfo.systemUptime
            playback.open(video, library: library, resumeAt: 0, autoplay: true, recovering: true, recordsProgress: true)
            try await wait("局域网首帧", seconds: 30) { playback.frameReady }
            measurements["firstFrame:" + file] = ProcessInfo.processInfo.systemUptime - started
            if let bytes = playback.diagnostic.accessLogBytesTransferred { measurements["readBytesAtFirstFrame:" + file] = Double(bytes) }
            let size = try await access.perform { try $0.size(file).doubleValue }
            measurements["fileBytes:" + file] = size
            if size > 1_000_000 {
                guard let bytes = playback.diagnostic.accessLogBytesTransferred, bytes > 0, Double(bytes) < size else { throw MediaError.message("局域网按需读取证据不足") }
            }
            guard playback.engineDescriptor.id == .vlc else { throw MediaError.message("局域网 SMB 内核错误") }
            playback.pause(); let target = playback.duration * 0.7; playback.seek(target)
            try await wait("局域网暂停定位", seconds: 25) { abs(playback.time - target) < 1 && !playback.isPlaying }
            measurements["seekTime:" + file] = playback.time
            if file.hasSuffix(".mkv") {
                try await wait("局域网多轨") { playback.audioOptions.count == 2 && !playback.subtitleOptions.isEmpty }
            }
            playback.save(); playback.stop()
            try record("lan:play-seek-pause:" + file)
        }
        stage = "SMB 局域网真机验证通过"; try save(passed: true)
    }
    @MainActor private func precisionOnly() async throws {
        let address = try SMBLocation.parse(address: "127.0.0.1:1445", share: "media").absoluteString
        if let previous = library.servers.first(where: { $0.name == "SMB QA" }) { library.remove(previous) }
        try await library.add(name: "SMB QA", kind: .smb, address: address, username: "glide", password: "glide150-fixture", remembersPlayback: true)
        guard let video = library.videos.first(where: { $0.title == "longplay.mp4" }) else { throw MediaError.message("缺少长播片源") }
        for target in [55.231, 71.5, 300.75] {
            stage = "非关键帧定位 \(target)"; try save()
            playback.open(video, library: library, resumeAt: target, autoplay: false, recovering: true, recordsProgress: true)
            try await wait("精确暂停定位", seconds: 30) { playback.frameReady && abs(playback.time - target) < 0.8 && !playback.isPlaying }
            measurements["pausedTime:\(target)"] = playback.time
            playback.save(); playback.stop()
            try record("precision:\(target)")
        }
        let restored = LibraryStore()
        guard let position = restored.positions[video.id], abs(position - 300.75) < 0.8 else { throw MediaError.message("重建媒体库后进度未恢复") }
        try record("progress:opt-in-persist-reload")
        for target in [54.88, 71.5, 300.75] {
            playback.open(video, library: library, resumeAt: target, autoplay: true, recovering: true, recordsProgress: false)
            try await wait("继续播放定位", seconds: 30) { playback.frameReady && abs(playback.time - target) < 1 && playback.isPlaying }
            measurements["playingTime:\(target)"] = playback.time
            playback.stop()
            try record("precision-playing:\(target)")
        }
        stage = "SMB 非关键帧定位验证通过"; try save(passed: true)
    }
}
#endif
