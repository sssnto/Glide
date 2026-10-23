#if DEBUG
import SwiftUI

/// Uses authored bundle videos and an isolated channel store, never the user's
/// channels, server credentials or watch history.
struct DiscoveryQAProbe: View {
    var library: LibraryStore
    @State private var store: DiscoveryStore
    private let file: URL
    @State private var selection: DiscoveryPlayback?
    @State private var finished = false
    @State private var stage = "私人频道验证准备中"
    @State private var checks: [String] = []
    @State private var failure: String?
    init(library: LibraryStore) {
        self.library = library
        file = FileManager.default.temporaryDirectory.appendingPathComponent("DiscoveryQA-" + UUID().uuidString).appendingPathComponent("channels.json")
        _store = State(initialValue: DiscoveryStore(file: file))
    }
    var body: some View {
        ZStack(alignment: .top) {
            if let selection { DiscoveryPlayer(library: library, selection: selection, store: store) { finished = true } }
            else { Color.black.ignoresSafeArea() }
            VStack(spacing: 6) {
                Text(stage).accessibilityIdentifier("discovery.probe.status")
                Text("通过 \(checks.count) 项").accessibilityIdentifier("discovery.probe.count")
                if let failure { Text(failure) }
            }.font(.caption).foregroundStyle(.white).padding(30).allowsHitTesting(false)
        }.task { await run() }.onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func record(_ value: Bool, _ name: String) throws {
        guard value else { throw MediaError.message(name) }
        checks.append(name)
    }
    private func save(passed: Bool) {
        let value: [String: Any] = ["passed": passed, "stage": stage, "checks": checks, "expectedChecks": 12,
            "error": failure ?? "", "version": PlaybackPreferences.appVersion,
            "timestamp": ISO8601DateFormatter().string(from: Date()), "system": UIDevice.current.systemVersion,
            "scope": "Authored bundle videos; production scope resolver, planners, isolated recoverable channel store and actual PlayerView/AVPlayer automatic queue; no personal servers or watch progress"]
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("discovery-qa-report.json")
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }
    @MainActor private func run() async {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { selection = nil; try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        do {
            let batches = try await DiscoveryResolver.batches([.demo], library: library, readDurations: true) { _ in }
            let authored = batches.flatMap(\.videos)
            try record(authored.count == 3 && authored.allSatisfy { $0.url?.isFileURL == true && $0.duration == 12 }, "resolver:authored-bundle-videos-with-real-duration")
            let picks = TimePickPlanner.recommendations(authored, minutes: 20, preference: .any, positions: [:])
            try record(picks.count == 3 && picks.allSatisfy { $0.remaining == 12 }, "time:known-duration-candidates-and-explanations")
            var resumed = authored[0]; resumed.duration = 12; resumed.resume = 5
            try record(TimePickPlanner.recommendations([resumed], minutes: 20, preference: .any, positions: [:]).first?.remaining == 7, "time:remaining-duration-preserves-resume")
            var a1 = authored[0], a2 = authored[1], b1 = authored[2]
            a1.id = "discovery-qa-a1"; a2.id = "discovery-qa-a2"; b1.id = "discovery-qa-b1"
            a1.title = "原创节目 A · 第 1 集"; a2.title = "原创节目 A · 第 2 集"; b1.title = "原创节目 B · 第 1 集"
            for index in 0..<3 {
                switch index {
                case 0: a1.mediaType = "Episode"; a1.seriesID = "A"; a1.seasonNumber = 1; a1.episodeNumber = 1
                case 1: a2.mediaType = "Episode"; a2.seriesID = "A"; a2.seasonNumber = 1; a2.episodeNumber = 2
                default: b1.mediaType = "Episode"; b1.seriesID = "B"; b1.seasonNumber = 1; b1.episodeNumber = 1
                }
            }
            let channel = PrivateChannel(name: "原创交替频道", scopes: [.demo])
            try store.save(channel)
            try record(DiscoveryStore(file: file).channels.first?.id == channel.id, "store:channel-survives-reload")
            let queue = ChannelPlanner.queue([DiscoveryBatch(scope: .demo, videos: [a2, b1, a1, a1])], channel: channel, positions: [:])
            try record(queue.map(\.id) == [a1.id, b1.id, a2.id], "channel:alternates-stories-with-numeric-episode-order-and-dedup")
            try record(store.channels.first?.lastStarted.isEmpty == true, "channel:preparation-does-not-count-as-playback")
            selection = DiscoveryPlayback(videos: queue, title: channel.name, channelID: channel.id)
            stage = "实际频道播放与自动下一条"; save(passed: false)
            let deadline = ProcessInfo.processInfo.systemUptime + 80
            while !finished && ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(100))
            }
            try record(finished, "player:actual-end-of-queue-after-three-videos")
            let starts = store.channels.first?.lastStarted ?? [:]
            try record(starts.count == 3 && queue.allSatisfy { starts[$0.id] != nil }, "player:all-three-native-first-frames-recorded")
            try record(starts[a1.id]! < starts[b1.id]! && starts[b1.id]! < starts[a2.id]!, "player:automatic-advance-follows-channel-order")
            try record(DiscoveryStore(file: file).channels.first?.lastStarted.count == 3, "store:actual-first-frame-history-survives-reload")
            var changed = channel; changed.avoidRecent = false; changed.name = "已编辑频道"; try store.save(changed)
            try record(store.channels.count == 1 && DiscoveryStore(file: file).channels.first?.name == changed.name, "store:editing-preserves-channel-identity")
            try store.remove(channel.id)
            try record(DiscoveryStore(file: file).channels.isEmpty, "store:remove-channel-keeps-source-media")
            stage = "私人频道与时间选片验证通过"; save(passed: true)
        } catch { failure = error.localizedDescription; stage = "私人频道验证未完成"; save(passed: false) }
    }
}
#endif
