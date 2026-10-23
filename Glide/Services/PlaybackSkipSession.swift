import Foundation
import Observation

@MainActor @Observable final class PlaybackSkipSession {
    private(set) var rule = PlaybackSkipRule()
    private(set) var serverSegments: [SkipSegment] = []
    private(set) var usesSeries = false
    private(set) var hasMemory = false
    private(set) var supportsServerMarkers = false
    private(set) var loading = false
    var message: String?
    private var consumed = Set<String>()
    private var video: Video?
    private var videoKey: String?
    private var seriesKey: String?
    private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    private static var store: RecoverableStore<[String: PlaybackSkipMemory]> {
        RecoverableStore(file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PlaybackRules/skip-v1.json"))
    }
    var canUseSeries: Bool { seriesKey != nil }
    func prepare(video: Video, server: MediaServer?, preservingSession: Bool = false) {
        let keep = preservingSession && self.video?.id == video.id
        cancel(); self.video = video
        supportsServerMarkers = server?.kind == .jellyfin
        if !keep { consumed = [] }
        rule = PlaybackSkipRule(); hasMemory = false; usesSeries = false; message = nil; serverSegments = []
        videoKey = nil; seriesKey = nil
        do {
            videoKey = try SubtitleSource.key(video: video, server: server)
            if server?.kind.isCatalogSource == true, let series = video.seriesID {
                var group = video; group.remoteID = series
                seriesKey = "series:" + (try SubtitleSource.key(video: group, server: server))
            }
            let saved = try Self.store.load()
            if let key = videoKey, let memory = saved?.value[key] { rule = memory.rule; hasMemory = true }
            else if let key = seriesKey, let memory = saved?.value[key] { rule = memory.rule; hasMemory = true; usesSeries = true }
            if saved?.recovered == true { message = "跳过规则已从备份恢复。" }
        } catch { message = "跳过规则无法恢复，已保留原文件。" }
        guard let server, server.kind == .jellyfin, let item = video.remoteID else { return }
        let token = generation
        loading = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let segments = try await MediaClient.shared.mediaSegments(server: server, itemID: item)
                guard token == generation, !Task.isCancelled else { return }
                serverSegments = segments
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                message = "服务器未提供可用片段，可继续手动设置。"
            }
            if token == generation { loading = false }
        }
    }
    func save(_ rule: PlaybackSkipRule, series: Bool, duration: Double) throws {
        try rule.validate(duration: duration)
        guard let video, let videoKey, let key = series ? seriesKey : videoKey else { throw MediaError.message("无法确定跳过规则的作用范围。") }
        var values = try Self.store.load()?.value ?? [:]
        values[key] = PlaybackSkipMemory(sourceID: video.sourceID, videoID: series ? "series:" + (video.seriesID ?? "") : video.id, rule: rule)
        if series { values[videoKey] = nil }
        try Self.store.save(values)
        self.rule = rule; usesSeries = series; hasMemory = true; message = nil; consumed = []
    }
    func clear() throws {
        guard let key = usesSeries ? seriesKey : videoKey else { return }
        var values = try Self.store.load()?.value ?? [:]; values[key] = nil
        try Self.store.save(values)
        if let group = seriesKey, let saved = values[group] { rule = saved.rule; usesSeries = true; hasMemory = true }
        else { rule = PlaybackSkipRule(); usesSeries = false; hasMemory = false }
        consumed = []; message = "已清除所选范围的规则。"
    }
    func active(time: Double, duration: Double) -> SkipSegment? {
        rule.segments(duration: duration, server: serverSegments).first { !consumed.contains($0.id) && $0.contains(time) }
    }
    func consume(_ segment: SkipSegment) { consumed.insert(segment.id) }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; loading = false }
    static func remove(sourceID: UUID) throws {
        let values = try store.load()?.value ?? [:]
        try store.save(values.filter { $0.value.sourceID != sourceID })
    }
    static func remove(videoID: String) throws {
        let values = try store.load()?.value ?? [:]
        try store.save(values.filter { $0.value.videoID != videoID })
    }
}
