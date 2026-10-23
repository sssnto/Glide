import Foundation
import UIKit
import CoreText

struct ASSSubtitle: Identifiable, Sendable {
    let id = UUID()
    let document: ASSDocument
    var fonts: [Data] = []
    var fontWarning: String?
    var cues: [SubtitleCue] { document.cues }
}

/// Font initialization is serialized as well: rapidly changing tracks must not
/// initialize several large CJK font databases at once.
actor ASSRenderPreparation {
    static let shared = ASSRenderPreparation()
    func make(_ subtitle: ASSSubtitle) throws -> ASSRenderWorker {
        try Task.checkCancellation()
        return try ASSRenderWorker(subtitle: subtitle)
    }
}

/// A separate actor serializes the native library and keeps shaping/rasterization off main.
actor ASSRenderWorker {
    private let renderer: GlideASSRenderer
    let missingFonts: [String]
    private let providedPostScriptNames: Set<String>
    init(subtitle: ASSSubtitle) throws {
        let imported = try ASSFontStore.fonts()
        var allFonts = subtitle.fonts
        var total = allFonts.reduce(0) { $0 + $1.count }
        for font in imported where total + font.count <= ASSFontStore.maximumTotal { allFonts.append(font); total += font.count }
        providedPostScriptNames = Set(allFonts.flatMap { data in
            ((CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]) ?? []).compactMap {
                CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String
            }
        })
        missingFonts = subtitle.document.hasEmbeddedFonts ? [] : ASSFontStore.missingFonts(subtitle.document.requestedFonts, fonts: allFonts)
        let fallback = Bundle.main.url(forResource: "GlideSubtitleFallback", withExtension: "otf", subdirectory: "SubtitleFonts")?.path ?? ""
        guard let value = GlideASSRenderer(script: subtitle.document.data, fonts: allFonts, fallbackPath: fallback) else {
            throw MediaError.message("无法初始化 ASS 原样渲染器。")
        }
        renderer = value
    }
    func render(time: Double, width: Int, height: Int, source: CGSize, matrix: String = "") -> GlideASSFrame {
        renderer.setVideoMatrix(matrix)
        return renderer.render(at: Int64(max(-1, min(time, 100_000_000)) * 1000), width: Int32(width), height: Int32(height), sourceWidth: Int32(min(65536, max(1, source.width.isFinite ? source.width : 1920))), sourceHeight: Int32(min(65536, max(1, source.height.isFinite ? source.height : 1080))))
    }
    var providedFontCount: Int { providedPostScriptNames.count }
    var matchedProvidedFontCount: Int { providedPostScriptNames.intersection(Set(renderer.selectedPostScriptNames)).count }
    var eventCount: Int { Int(renderer.eventCount) }
    var version: Int { Int(renderer.version) }
}

/// Font imports are private to libass; they never register or replace system fonts.
enum ASSFontStore {
    static let maximumBytes = 20_000_000
    static let maximumTotal = 64_000_000
    private static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SubtitleFonts", isDirectory: true) }
    static func fonts() throws -> [Data] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
        var total = 0, result = [Data]()
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= maximumBytes, total + size <= maximumTotal else { continue }
            let data = try Data(contentsOf: file)
            if valid(data) { result.append(data); total += size }
        }
        return result
    }
    static func missingFonts(_ names: [String], fonts: [Data]) -> [String] {
        func normalized(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }
        var available = Set<String>()
        for data in fonts {
            for descriptor in (CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]) ?? [] {
                let font = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
                if let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableName), CTFontTableOptions(rawValue: 0)) {
                    for name in FontNameTable.names(table as Data) { available.insert(normalized(name)) }
                }
                for attribute in [kCTFontFamilyNameAttribute, kCTFontNameAttribute, kCTFontDisplayNameAttribute] {
                    if let name = CTFontDescriptorCopyAttribute(descriptor, attribute) as? String { available.insert(normalized(name)) }
                }
            }
        }
        return names.filter { requested in
            let name = requested.hasPrefix("@") ? String(requested.dropFirst()) : requested
            if available.contains(normalized(name)) { return false }
            let font = CTFontCreateWithName(name as CFString, 16, nil)
            let candidates = [CTFontCopyFamilyName(font) as String, CTFontCopyPostScriptName(font) as String, CTFontCopyFullName(font) as String]
            return !candidates.contains { normalized($0) == normalized(name) }
        }
    }
    static func valid(_ data: Data) -> Bool {
        !data.isEmpty && data.count <= maximumBytes && (CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor])?.isEmpty == false
    }
    static func importFont(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= maximumBytes else { throw MediaError.message("请选择不超过 20 MB 的 TTF、OTF 或 TTC 字体文件。") }
        let data = try Data(contentsOf: url)
        guard valid(data) else { throw MediaError.message("字体文件无法读取。") }
        let existing = try fonts(), digest = SubtitleSource.digest(data)
        if existing.contains(where: { SubtitleSource.digest($0) == digest }) { return }
        guard existing.reduce(0, { $0 + $1.count }) + data.count <= maximumTotal else { throw MediaError.message("导入字体总大小已达到 64 MB。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(digest + ".font"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

#if DEBUG
enum ASSStyleQA {
    static let script = #"""
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360
    ScaledBorderAndShadow: yes
    YCbCr Matrix: None
    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Glide Subtitle Fallback,28,&H00FFFFFF,&H0000FFFF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,20,1
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\an7\pos(30,80)\1c&H0000FF&\fad(500,500)}原始字体 红色
    Dialogue: 1,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\an7\pos(30,130)\fnCourier New\1c&HFF0000&\blur1\shad2}Original blue type
    Dialogue: 2,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\an7\pos(400,50)\bord0\shad0\1c&H00FF00&\p1}m 0 0 l 40 0 40 40 0 40
    Dialogue: 3,0:00:00.00,0:00:04.00,Default,,0,0,0,,{\an7\pos(30,200)\1c&H00FFFF&\2c&HFFFFFF&}{\kf100}Kara{\kf100}oke
    Dialogue: 0,0:00:04.00,0:00:08.00,Default,,0,0,0,,{\an7\move(40,90,420,160,0,4000)\t(0,4000,\frz25\1c&HFF0000&)\clip(0,0,640,300)}移动与旋转 Motion
    Dialogue: 1,0:00:08.00,0:00:12.00,Default,,0,0,0,,{\an7\pos(50,100)\iclip(100,0,140,360)\frz-10\1c&HFF00FF&\fscx110}裁剪与缩放 Clip
    """#
    static func subtitle(_ script: String = script) throws -> ASSSubtitle {
        let font = Bundle.main.url(forResource: "GlideSubtitleFallback", withExtension: "otf", subdirectory: "SubtitleFonts")!
        return ASSSubtitle(document: try ASSDocument.parse(Data(script.utf8)), fonts: [try Data(contentsOf: font)])
    }
    static func validate() async throws -> [String: Any] {
        var checks = [String]()
        func check(_ value: Bool, _ name: String) throws {
            guard value else { throw MediaError.message("ASS 样式验证失败：" + name) }
            checks.append(name)
        }
        let authored = try subtitle(), renderer = try ASSRenderWorker(subtitle: authored), size = CGSize(width: 640, height: 360)
        try check(await renderer.version == 0x01703000, "fixed-libass-0.17.3-runtime")
        try check(await renderer.eventCount == 6, "all-authored-events-loaded")
        func draw(_ time: Double, width: Int = 640, height: Int = 360) async -> GlideASSFrame { await renderer.render(time: time, width: width, height: height, source: size) }
        func bytes(_ frame: GlideASSFrame) -> Data { frame.image?.cgImage?.dataProvider?.data as Data? ?? Data() }
        let early = await draw(0.1), stable = await draw(1)
        try check(stable.image != nil && stable.imageCount > 8, "multi-layer-shaping-outline-shadow-and-drawing")
        let data = bytes(stable), rgba = [UInt8](data)
        var red = 0, green = 0, blue = 0, partial = 0
        for i in stride(from: 0, to: rgba.count, by: 4) {
            if rgba[i] > 160 && rgba[i+1] < 60 && rgba[i+2] < 60 { red += 1 }
            if rgba[i+1] > 200 && rgba[i] < 30 && rgba[i+2] < 30 { green += 1 }
            if rgba[i+2] > 160 && rgba[i] < 60 && rgba[i+1] < 60 { blue += 1 }
            if rgba[i+3] > 0 && rgba[i+3] < 255 { partial += 1 }
        }
        try check(red > 30 && green > 1000 && blue > 30, "original-red-blue-and-green-colours")
        try check(partial > 30, "alpha-antialiasing-and-blur-preserved")
        try check(bytes(early) != data, "fade-and-karaoke-change-with-real-timestamps")
        let same = await draw(1)
        try check(!same.changed, "paused-frame-reuses-raster")
        let motionStart = await draw(4.2), motionEnd = await draw(7.2)
        try check(motionEnd.rect.minX > motionStart.rect.minX + 100 && bytes(motionStart) != bytes(motionEnd), "move-rotation-transform-interpolates")
        let clipped = await draw(9)
        try check(clipped.image != nil && bytes(clipped) != bytes(motionEnd), "inverse-clip-and-scaling-render")
        let resized = await draw(9, width: 1280, height: 720)
        try check(resized.changed && abs(resized.rect.width / clipped.rect.width - 2) < 0.15, "viewport-resize-retains-script-coordinates")
        let gone = await draw(13)
        try check(gone.changed && gone.image == nil, "event-end-clears-overlay")
        let sought = await draw(1)
        try check(sought.image != nil, "backward-seek-restores-original-frame")
        let offmainFont = try ASSRenderWorker(subtitle: subtitle(script.replacingOccurrences(of: "Glide Subtitle Fallback", with: "Courier New")))
        let different = await offmainFont.render(time: 1, width: 640, height: 360, source: size)
        try check(bytes(different) != data, "authored-font-choice-changes-glyphs")
        let matrixWorker = try ASSRenderWorker(subtitle: subtitle(script.replacingOccurrences(of: "YCbCr Matrix: None", with: "YCbCr Matrix: TV.601")))
        let mapped = await matrixWorker.render(time: 1, width: 640, height: 360, source: size, matrix: "bt709")
        try check(mapped.image != nil && bytes(mapped) != data, "declared-ycbcr-matrix-maps-to-video-colour-space")
        return ["passed": true, "checks": checks, "expectedChecks": 14, "version": await renderer.version,
            "colouredPixels": ["red": red, "blue": blue, "green": green], "timestamp": ISO8601DateFormatter().string(from: Date())]
    }
}
#endif
