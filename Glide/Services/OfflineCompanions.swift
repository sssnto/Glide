import Foundation

struct OfflineSubtitleAsset: Codable {
    var lane: String
    var name: String
    var file: String?
    var fonts: [String] = []
    var delay = 0.0
    var disabled = false
}

/// All names are generated locally. Source paths and authentication never enter this folder.
enum OfflineCompanions {
    static func directory(_ filename: String) -> URL {
        DownloadStore.directory.appendingPathComponent("Assets", isDirectory: true).appendingPathComponent(filename, isDirectory: true)
    }
    static func url(_ name: String, filename: String) throws -> URL {
        guard !name.isEmpty, name == (name as NSString).lastPathComponent, !name.contains("\\"), !name.hasPrefix(".") else {
            throw MediaError.message("离线资料路径无效。")
        }
        return directory(filename).appendingPathComponent(name)
    }
    static func write(_ data: Data, name: String, filename: String) throws {
        let target = try url(name, filename: filename)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func read(_ name: String, filename: String, limit: Int = SubtitleDocument.maximumBytes) throws -> Data {
        let file = try url(name, filename: filename)
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= limit else {
            throw MediaError.message("离线字幕或字体缺失、损坏或超过限制，请重新准备资料。")
        }
        return try Data(contentsOf: file)
    }
    static func remove(_ filename: String) { try? FileManager.default.removeItem(at: directory(filename)) }
    static func bytes(_ filename: String) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(filename), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    static func fingerprint(_ assets: [OfflineSubtitleAsset], filename: String) throws -> String {
        var stamps = [String]()
        for name in assets.flatMap({ [$0.file].compactMap { $0 } + $0.fonts }).sorted() {
            let file = try url(name, filename: filename)
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, let modified = values.contentModificationDate else { throw MediaError.message("离线配套资料缺失。") }
            stamps.append("\(name):\(size):\(modified.timeIntervalSince1970)")
        }
        return SubtitleSource.digest(Data(stamps.joined(separator: "\n").utf8))
    }
}

@MainActor extension DownloadStore {
    func prepareLocalCompanions(video: Video, server: MediaServer, filename: String) async -> (assets: [OfflineSubtitleAsset], warnings: [String]) {
        var assets = [OfflineSubtitleAsset](), warnings = [String]()
        do {
            let catalog = try await SubtitleSource.catalog(video: video, server: server)
            for lane in SubtitleLane.allCases {
                let key = lane.memoryKey(try SubtitleSource.key(video: video, server: server))
                let memory = try SubtitleSource.store.load().value[key]
                if let memory, memory.revision != catalog.revision { warnings.append("视频已变化，请重新选择字幕。"); continue }
                var asset = OfflineSubtitleAsset(lane: lane.rawValue, name: "字幕", delay: memory?.safeDelay ?? 0)
                let data: Data, ext: String
                switch memory?.choice {
                case .off: asset.disabled = true; assets.append(asset); continue
                case .embedded: continue
                case .imported(let file, let name, _):
                    data = try SubtitleSource.readFile(SubtitleSource.store.importedURL(file)); ext = (file as NSString).pathExtension; asset.name = name
                default:
                    let candidate: SidecarSubtitle?
                    if case .sidecar(let name, _) = memory?.choice { candidate = catalog.candidates.first { $0.name == name } }
                    else if lane == .primary, !PlaybackPreferences.subtitlesOff { candidate = SidecarSubtitleMatch.automatic(catalog.candidates, language: PlaybackPreferences.subtitleLanguage, forcedOnly: PlaybackPreferences.forcedOnly) }
                    else { continue }
                    guard let candidate else {
                        if !catalog.candidates.isEmpty { warnings.append("存在多个或已变化的外挂字幕，请先在播放器中选择，再重新加入行程包。") }
                        continue
                    }
                    data = try await SubtitleSource.read(candidate, video: video, server: server); ext = candidate.url.pathExtension; asset.name = candidate.name
                }
                let document = try await SubtitleSource.document(data)
                if let ass = document.ass { warnings += ASSFontStore.missingFonts(ass.document.requestedFonts, fonts: try ASSFontStore.fonts()).map { "缺少原字体：\($0)" } }
                let name = lane.rawValue + "." + ext
                try OfflineCompanions.write(data, name: name, filename: filename); asset.file = name
                assets.append(asset)
            }
        } catch { warnings.append(error.localizedDescription) }
        return (assets, warnings)
    }
    func prepareCompanions(item: CatalogItem, server: MediaServer, filename: String) async -> (assets: [OfflineSubtitleAsset], warnings: [String]) {
        guard let source = item.MediaSources?.first else { return ([], ["服务器没有提供当前文件资料。"]) }
        let video = item.video(server: server)
        var assets = [OfflineSubtitleAsset](), warnings = [String]()
        for lane in SubtitleLane.allCases {
            do {
                try Task.checkCancellation()
                let key = try lane.memoryKey(SubtitleSource.key(video: video, server: server))
                let memory = try SubtitleSource.store.load().value[key]
                var asset = OfflineSubtitleAsset(lane: lane.rawValue, name: "字幕", delay: memory?.safeDelay ?? 0)
                let data: Data, ext: String
                var fonts = [Data]()
                switch memory?.choice {
                case .off:
                    asset.disabled = true; assets.append(asset); continue
                case .imported(let file, let name, _):
                    data = try SubtitleSource.readFile(SubtitleSource.store.importedURL(file)); ext = (file as NSString).pathExtension; asset.name = name
                case .embedded:
                    // Embedded tracks travel inside the original file and stay switchable in VLC.
                    continue
                default:
                    guard lane == .primary || memory != nil else { continue }
                    let streams = source.MediaStreams?.filter { $0.Type == "Subtitle" } ?? []
                    let selected: CatalogItem.Stream?
                    if case .server(let saved) = memory?.choice {
                        guard saved.mediaSourceID == source.Id else { throw MediaError.message("已选字幕不属于当前下载版本，请重新选择。") }
                        selected = streams.first { $0.Index == saved.index }
                        if selected == nil { throw MediaError.message("已选字幕轨道已变化。") }
                    } else if PlaybackPreferences.subtitlesOff { asset.disabled = true; assets.append(asset); continue }
                    else {
                        let preferred = LanguagePreference.stream(streams, language: PlaybackPreferences.subtitleLanguage, forcedOnly: PlaybackPreferences.forcedOnly)
                        selected = streams.first { $0.Index == preferred } ?? streams.first { $0.IsDefault == true }
                    }
                    guard let selected else { continue }
                    asset.name = selected.label
                    if ["ass", "ssa"].contains(selected.Codec?.lowercased() ?? "") {
                        let ass = try await MediaClient.shared.serverASSSubtitle(video: video, server: server, sourceID: source.Id, stream: selected, attachments: source.MediaAttachments, offlineDownload: true)
                        data = ass.document.data; ext = "ass"; fonts = ass.fonts
                        if let warning = ass.fontWarning { warnings.append(warning) }
                    } else if CatalogSubtitlePolicy.textCodecs.contains(selected.Codec?.lowercased() ?? "") {
                        let cues = try await MediaClient.shared.serverSubtitle(video: video, server: server, sourceID: source.Id, stream: selected, offlineDownload: true)
                        data = Data(("WEBVTT\n\n" + cues.map { "\(Self.vttTime($0.start)) --> \(Self.vttTime($0.end))\n\($0.text)\n" }.joined(separator: "\n")).utf8); ext = "vtt"
                    } else if CatalogSubtitlePolicy.pgsCodecs.contains(selected.Codec?.lowercased() ?? ""), server.kind == .jellyfin {
                        data = try await MediaClient.shared.offlineBitmapData(video: video, server: server, sourceID: source.Id, stream: selected); ext = "sup"
                    } else {
                        warnings.append("\(selected.label)：请在离线检查时确认文件内字幕；该轨道没有单独保存。")
                        continue
                    }
                }
                if ext != "sup" {
                    let document = try await SubtitleSource.document(data)
                    if let ass = document.ass {
                        let imported = try ASSFontStore.fonts()
                        warnings += ASSFontStore.missingFonts(ass.document.requestedFonts, fonts: fonts + imported).map { "缺少原字体：\($0)" }
                    }
                }
                let name = lane.rawValue + "." + ext
                try OfflineCompanions.write(data, name: name, filename: filename); asset.file = name
                for (index, font) in fonts.enumerated() {
                    let name = lane.rawValue + "-font-\(index).font"
                    try OfflineCompanions.write(font, name: name, filename: filename); asset.fonts.append(name)
                }
                assets.append(asset)
            } catch { warnings.append("\(lane.rawValue) 字幕资料：" + error.localizedDescription) }
        }
        return (assets, warnings)
    }
    private static func vttTime(_ value: Double) -> String {
        let ms = Int(max(0, value.isFinite ? min(value, 31_536_000) : 0) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
