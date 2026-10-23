import Foundation

/// The untouched script drives libass. Plain cues are only a transcript/search index.
struct ASSDocument: Sendable {
    let data: Data
    let cues: [SubtitleCue]
    var hasEmbeddedFonts: Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.range(of: "[Fonts]", options: .caseInsensitive) != nil && text.range(of: "fontname:", options: .caseInsensitive) != nil
    }
    var requestedFonts: [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var styleFields = [String](), inStyles = false, result = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { inStyles = ["[v4+ styles]", "[v4 styles]"].contains(line.lowercased()); continue }
            guard inStyles, let colon = line.firstIndex(of: ":") else { continue }
            let kind = line[..<colon].lowercased(), body = String(line[line.index(after: colon)...])
            if kind == "format" { styleFields = body.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
            if kind == "style", let index = styleFields.firstIndex(of: "fontname") {
                let values = body.components(separatedBy: ",")
                if values.indices.contains(index) { result.insert(values[index].trimmingCharacters(in: .whitespaces)) }
            }
        }
        let regex = try! NSRegularExpression(pattern: #"\\fn([^\\}]+)"#)
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range(at: 1), in: text) { result.insert(String(text[range]).trimmingCharacters(in: .whitespaces)) }
        }
        return result.filter { !$0.isEmpty }.sorted()
    }
    static func recognizes(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.range(of: "[Script Info]", options: .caseInsensitive) != nil && text.range(of: "[Events]", options: .caseInsensitive) != nil
    }
    static func parse(_ data: Data) throws -> ASSDocument {
        guard data.count <= SubtitleDocument.maximumBytes, let text = String(data: data, encoding: .utf8), recognizes(data) else {
            throw MediaError.message("无法读取 ASS／SSA 原始字幕，请使用 UTF-8 编码。")
        }
        var events = false, fields = [String](), cues = [SubtitleCue]()
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { events = line.lowercased() == "[events]"; continue }
            guard events, let colon = line.firstIndex(of: ":") else { continue }
            let kind = line[..<colon].lowercased(), body = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if kind == "format" { fields = body.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }; continue }
            guard kind == "dialogue", !fields.isEmpty, fields.last == "text" else { continue }
            let values = body.split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false).map(String.init)
            guard values.count == fields.count, let s = fields.firstIndex(of: "start"), let e = fields.firstIndex(of: "end"),
                  let start = time(values[s]), let end = time(values[e]), end > start else { continue }
            let caption = ASSPlainText.render(values.last ?? "", enabled: true)
            if !caption.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: caption)) }
        }
        // Drawing-only tracks are valid even when the searchable transcript is empty.
        guard text.range(of: "Dialogue:", options: .caseInsensitive) != nil else { throw MediaError.message("ASS 字幕中没有可播放的事件。") }
        return ASSDocument(data: data, cues: cues.sorted { $0.start < $1.start })
    }
    private static func time(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]),
              h >= 0, m >= 0, m < 60, s >= 0, s < 60 else { return nil }
        let result = h * 3600 + m * 60 + s
        return result.isFinite ? result : nil
    }
}
