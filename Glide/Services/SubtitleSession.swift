import Foundation
import Observation
import UIKit

struct PGSSubtitleFrame {
    struct Layer { var rect: PGSSubtitle.Rect; var image: CGImage }
    var width: Int; var height: Int; var layers: [Layer]
}

/// One active video owns all async subtitle work. Tokens also guard manual choices
/// made while discovery or restoration is still running.
@MainActor @Observable final class SubtitleSession {
    let lane: SubtitleLane
    init(lane: SubtitleLane = .primary) { self.lane = lane }
    private(set) var cues: [SubtitleCue] = []
    private(set) var ass: ASSSubtitle?
    var hasASS: Bool { ass != nil }
    var overlayCues: [SubtitleCue] { hasASS ? [] : cues }
    func reloadASSFonts() { guard let old = ass else { return }; ass = ASSSubtitle(document: old.document, fonts: old.fonts, fontWarning: old.fontWarning) }
    private(set) var candidates: [SidecarSubtitle] = []
    private(set) var choice: SubtitleChoice?
    private(set) var delay = 0.0
    private(set) var discovering = false
    private(set) var reading = false
    private(set) var hasMemory = false
    private(set) var importedCopy: ImportedSubtitleCopy?
    private(set) var serverName: String?
    private(set) var serverTrack: SubtitleServerTrack?
    @ObservationIgnored private(set) var bitmap: PGSSubtitle?
    private(set) var bitmapFrame: PGSSubtitleFrame?
    @ObservationIgnored private var bitmapTask: Task<Void, Never>?
    private var bitmapIndex: Int?
    private var bitmapGeneration = UUID()
    var hasBitmap: Bool { bitmap != nil }
    private func clearBitmap() {
        ass = nil
        bitmapGeneration = UUID(); bitmapTask?.cancel(); bitmapTask = nil
        bitmap = nil; bitmapIndex = nil; bitmapFrame = nil
    }
    func updateBitmap(at time: Double) {
        guard let bitmap else { return }
        let index = bitmap.index(at: time, delay: delay)
        guard index != bitmapIndex else { return }
        bitmapTask?.cancel(); bitmapTask = nil; bitmapIndex = index; bitmapFrame = nil
        guard let index else { return }
        let cue = bitmap.cues[index], token = bitmapGeneration
        bitmapTask = Task { [weak self] in
            do {
                let work = Task.detached(priority: .userInitiated) { try PGSSubtitle.rasterize(cue) }
                let rasters = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, let self, bitmapGeneration == token, bitmapIndex == index else { return }
                let layers = rasters.compactMap { raster -> PGSSubtitleFrame.Layer? in
                    guard let provider = CGDataProvider(data: raster.rgba as CFData),
                          let image = CGImage(width: raster.rect.width, height: raster.rect.height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: raster.rect.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
                    return PGSSubtitleFrame.Layer(rect: raster.rect, image: image)
                }
                guard layers.count == rasters.count else { throw PGSSubtitle.Failure.invalid }
                bitmapFrame = PGSSubtitleFrame(width: cue.width, height: cue.height, layers: layers)
            } catch {
                guard !Task.isCancelled, let self, bitmapGeneration == token, bitmapIndex == index else { return }
                message = error.localizedDescription
            }
        }
    }
    @discardableResult func finishServerBitmap(_ value: PGSSubtitle, track: SubtitleServerTrack, token: UUID) -> Bool {
        guard token == intent, !Task.isCancelled, !value.cues.isEmpty else { return false }
        clearBitmap(); bitmap = value; cues = []; reading = false; choice = .server(track)
        serverTrack = track; serverName = track.name; delay = 0
        persist(); onSelection?(); return true
    }
    func installServerBitmap(_ value: PGSSubtitle, track: SubtitleServerTrack, videoID: String) async -> Bool {
        let token = generation
        await discoveryTask?.value
        guard !Task.isCancelled, token == generation, video?.id == videoID else { return false }
        switch choice {
        case nil: break
        case .server(let saved): guard saved.mediaSourceID == track.mediaSourceID, saved.index == track.index else { return false }
        default: return false
        }
        clearBitmap(); bitmap = value; cues = []; serverName = track.name; serverTrack = track
        onSelection?(); return true
    }
    var message: String?
    var canDiscover: Bool { SubtitleSource.supportsDiscovery(server) }
    var activeName: String? {
        if let serverName { return serverName }
        return switch choice { case .sidecar(let name, _), .imported(_, let name, _): name; default: nil }
    }
    func waitUntilPrepared() async { await discoveryTask?.value }
    func installServerText(_ values: [SubtitleCue], name: String, track: SubtitleServerTrack, videoID: String) async -> Bool {
        let token = generation
        await discoveryTask?.value
        let acceptsChoice: Bool
        switch choice {
        case nil: acceptsChoice = true
        case .server(let saved): acceptsChoice = saved.mediaSourceID == track.mediaSourceID && saved.index == track.index
        default: acceptsChoice = false
        }
        guard !Task.isCancelled, token == generation, video?.id == videoID, acceptsChoice, !values.isEmpty else { return false }
        intent = UUID(); selectionTask?.cancel(); reading = false
        clearBitmap(); cues = values; serverName = name; serverTrack = track; onSelection?(); return true
    }
    func installServerASS(_ value: ASSSubtitle, track: SubtitleServerTrack, videoID: String) async -> Bool {
        let token = generation
        await discoveryTask?.value
        guard !Task.isCancelled, token == generation, video?.id == videoID else { return false }
        switch choice {
        case nil: break
        case .server(let saved): guard saved.mediaSourceID == track.mediaSourceID, saved.index == track.index else { return false }
        default: return false
        }
        intent = UUID(); selectionTask?.cancel(); reading = false
        clearBitmap(); ass = value; cues = value.cues; serverTrack = track; serverName = track.name
        message = value.fontWarning; onSelection?(); return true
    }
    @discardableResult func finishServerASS(_ value: ASSSubtitle, track: SubtitleServerTrack, token: UUID) -> Bool {
        guard token == intent, !Task.isCancelled else { return false }
        clearBitmap(); ass = value; cues = value.cues; reading = false; choice = .server(track)
        serverTrack = track; serverName = track.name; delay = 0; message = value.fontWarning
        persist(); onSelection?(); return true
    }
    func beginServerSelection() -> UUID {
        selectionTask?.cancel(); intent = UUID(); reading = true; message = nil
        return intent
    }
    @discardableResult func finishServerSelection(_ values: [SubtitleCue], track: SubtitleServerTrack, token: UUID) -> Bool {
        guard token == intent, !Task.isCancelled, !values.isEmpty else { return false }
        clearBitmap(); reading = false; cues = values; choice = .server(track); serverTrack = track; serverName = track.name; delay = 0
        persist(); onSelection?(); return true
    }
    func failServerSelection(_ message: String, token: UUID) {
        guard token == intent else { return }
        reading = false; self.message = message
    }
    func selectServer(_ track: SubtitleServerTrack) {
        clearBitmap(); selectionTask?.cancel(); intent = UUID(); reading = false; cues = []; delay = 0; message = nil
        choice = .server(track); serverTrack = track; serverName = track.name
        persist(); onSelection?()
    }
    func ignoreServerSelectionForLocalPlayback() {
        guard case .server = choice else { return }
        choice = nil; serverTrack = nil; clearBitmap(); serverName = nil; cues = []
        message = "服务器字幕保留在在线来源中，离线播放可选择文件内的字幕。"
        onSelection?()
    }
    @ObservationIgnored var onSelection: (() -> Void)?
    @ObservationIgnored private var pendingImport: SubtitleImportLease?
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    private var video: Video?
    private var server: MediaServer?
    private var key: String?
    private var revision: SubtitleRevision?
    private var revisionReady = false
    private var generation = UUID()
    private var intent = UUID()

    func prepare(video: Video, server: MediaServer?, sharedCatalog: Task<SubtitleCatalog, Error>? = nil) {
        cancel()
        self.video = video; self.server = server
        cues = []; candidates = []; choice = nil; importedCopy = nil; clearBitmap(); serverName = nil; serverTrack = nil; delay = 0; hasMemory = false; message = nil; revision = nil; revisionReady = false
        do { key = try lane.memoryKey(SubtitleSource.key(video: video, server: server)) }
        catch { key = nil; message = error.localizedDescription; return }
        let token = generation, initialIntent = intent
        discovering = canDiscover
        discoveryTask = Task { [weak self] in
            guard let self, let key, !Task.isCancelled, token == generation else { return }
            defer { if token == generation { discovering = false } }
            do {
                let saved = try SubtitleSource.store.load()
                let memory = saved.value[key]
                hasMemory = memory != nil
                importedCopy = memory?.importedCopy ?? memory?.choice.importedCopy
                if saved.recovered { message = "字幕记忆已从备份恢复。" }
                let catalog: SubtitleCatalog
                if let sharedCatalog { catalog = try await sharedCatalog.value }
                else { catalog = try await SubtitleSource.catalog(video: video, server: server) }
                guard !Task.isCancelled, token == generation else { return }
                candidates = catalog.candidates; revision = catalog.revision; revisionReady = true
                guard intent == initialIntent else { persist(); return }
                if let memory {
                    guard memory.revision == revision else {
                        message = "视频文件已变化，已停止恢复旧字幕，请重新选择。"; return
                    }
                    delay = memory.safeDelay
                    try await restore(memory.choice, video: video, server: server, token: token, intent: initialIntent)
                } else if lane == .primary, let candidate = SidecarSubtitleMatch.automatic(candidates, language: PlaybackPreferences.subtitleLanguage, forcedOnly: PlaybackPreferences.forcedOnly) {
                    try await load(candidate, video: video, server: server!, expectedDigest: nil, token: token, intent: initialIntent)
                } else if lane == .primary, candidates.count > 1 { message = "找到多个同名字幕，请在字幕菜单中选择。" }
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                if intent == initialIntent { message = "字幕未能恢复或匹配：" + error.localizedDescription }
                else { message = "当前字幕选择尚未保存：无法校验视频文件信息。" }
            }
        }
    }

    private func restore(_ saved: SubtitleChoice, video: Video, server: MediaServer?, token: UUID, intent: UUID) async throws {
        switch saved {
        case .sidecar(let name, let digest):
            guard let candidate = candidates.first(where: { $0.name == name }), let server else {
                throw MediaError.message("记住的字幕已移动或删除，请重新选择。")
            }
            try await load(candidate, video: video, server: server, expectedDigest: digest, token: token, intent: intent)
        case .imported(let file, _, let expected):
            let url = try SubtitleSource.store.importedURL(file)
            let data = try await Task.detached { try SubtitleSource.readFile(url) }.value
            let document = try await SubtitleSource.document(data)
            guard token == generation, intent == self.intent, !Task.isCancelled else { return }
            guard document.digest == expected else { throw MediaError.message("保存的字幕副本已变化，请重新导入。") }
            clearBitmap(); serverName = nil; serverTrack = nil; cues = document.cues; ass = document.ass; choice = saved; importedCopy = saved.importedCopy; onSelection?()
        case .server(let track):
            guard token == generation, intent == self.intent, !Task.isCancelled else { return }
            choice = saved; serverTrack = track; serverName = track.name; onSelection?()
        case .off, .embedded:
            guard token == generation, intent == self.intent, !Task.isCancelled else { return }
            choice = saved; onSelection?()
        }
    }

    private func load(_ candidate: SidecarSubtitle, video: Video, server: MediaServer, expectedDigest: String?, token: UUID, intent: UUID) async throws {
        let data = try await SubtitleSource.read(candidate, video: video, server: server)
        let document = try await SubtitleSource.document(data)
        guard token == generation, intent == self.intent, !Task.isCancelled else { return }
        guard expectedDigest == nil || document.digest == expectedDigest else { throw MediaError.message("记住的字幕内容已变化，请重新选择以使用新版字幕。") }
        clearBitmap(); serverName = nil; serverTrack = nil; cues = document.cues; ass = document.ass; choice = .sidecar(name: candidate.name, digest: document.digest)
        message = "已使用 \(candidate.name)，将记住本视频的选择。"
        persist(); onSelection?()
    }
    func choose(_ candidate: SidecarSubtitle) {
        guard let video, let server, candidates.contains(candidate) else { return }
        selectionTask?.cancel(); intent = UUID(); reading = true; message = nil
        let token = generation, requested = intent
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do { try await load(candidate, video: video, server: server, expectedDigest: nil, token: token, intent: requested) }
            catch { if !Task.isCancelled, token == generation, requested == intent { message = error.localizedDescription } }
            if token == generation, requested == intent { reading = false }
        }
    }
    func importFile(_ file: URL) {
        guard video != nil, ["srt", "vtt", "ass", "ssa"].contains(file.pathExtension.lowercased()) else { message = "请选择 SRT／VTT／ASS／SSA 字幕文件。"; return }
        selectionTask?.cancel(); intent = UUID(); reading = true; message = nil
        let token = generation, requested = intent
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await Task.detached {
                    let access = LocalFileAccess(root: file); defer { withExtendedLifetime(access) {} }
                    return try SubtitleSource.readFile(file)
                }.value
                let document = try await SubtitleSource.document(data)
                guard token == generation, requested == intent, !Task.isCancelled else { return }
                let name = try SubtitleSource.store.makeImportedCopy(data, extension: file.pathExtension)
                pendingImport = SubtitleImportLease(file: try SubtitleSource.store.importedURL(name))
                choice = .imported(file: name, name: file.lastPathComponent, digest: document.digest)
                clearBitmap(); serverName = nil; serverTrack = nil
                importedCopy = choice?.importedCopy
                cues = document.cues; ass = document.ass; delay = 0
                message = "已保存字幕副本，将记住本视频的选择。"
                persist(); onSelection?()
            } catch { if !Task.isCancelled, token == generation, requested == intent { message = "字幕导入未完成：" + error.localizedDescription } }
            if token == generation, requested == intent { reading = false }
        }
    }
    func selectEmbedded(_ option: PlaybackTrack?, engine: PlaybackEngineID) {
        selectionTask?.cancel(); intent = UUID(); reading = false; cues = []; clearBitmap(); serverName = nil; serverTrack = nil; message = nil
        if let option { choice = .embedded(SubtitleEmbeddedTrack(engine: engine, id: option.id, name: option.displayName, language: option.language, forced: option.forced)) }
        else { choice = .off }
        persist(); onSelection?()
    }
    func useImportedCopy() {
        guard let importedCopy, let video else { return }
        selectionTask?.cancel(); intent = UUID(); reading = true; message = nil
        let token = generation, requested = intent, server = server
        selectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await restore(importedCopy.choice, video: video, server: server, token: token, intent: requested)
                if token == generation, requested == intent, !Task.isCancelled { persist() }
            } catch { if !Task.isCancelled, token == generation, requested == intent { message = "保存的字幕副本无法读取，请重新导入。" } }
            if token == generation, requested == intent { reading = false }
        }
    }
    func setDelay(_ value: Double) {
        guard !cues.isEmpty || hasBitmap || hasASS else { return }
        delay = value.isFinite ? min(30, max(-30, value)) : 0
        persist()
    }
    func forget() {
        guard let key else { return }
        do {
            try SubtitleSource.store.set(nil, for: key)
            selectionTask?.cancel(); intent = UUID(); reading = false
            cues = []; choice = nil; importedCopy = nil; clearBitmap(); serverName = nil; serverTrack = nil; delay = 0; hasMemory = false; pendingImport = nil
            message = "已清除此视频的字幕记忆，下次打开重新匹配。"; onSelection?()
        } catch { message = "字幕记忆未能清除：" + error.localizedDescription }
    }
    private func persist() {
        guard revisionReady, let video, let key, let choice else { return }
        do {
            try SubtitleSource.store.set(SubtitleMemory(sourceID: video.sourceID, videoID: video.id, revision: revision, choice: choice, delay: delay, importedCopy: importedCopy), for: key)
            hasMemory = true; pendingImport = nil
        } catch { message = "当前字幕可继续使用，但无法保存记忆：" + error.localizedDescription }
    }
    func cancel() {
        clearBitmap()
        generation = UUID(); intent = UUID(); pendingImport = nil
        discoveryTask?.cancel(); discoveryTask = nil; selectionTask?.cancel(); selectionTask = nil
        discovering = false; reading = false
    }
}
