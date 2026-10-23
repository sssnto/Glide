import Foundation

struct SubtitleCue: Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    static func parse(_ input: String, assText: Bool = false) -> [SubtitleCue] {
        let blocks = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let pair = lines[index].components(separatedBy: "-->")
            guard pair.count == 2, let start = time(pair[0]), let end = time(pair[1]), end > start else { return nil }
            let body = lines.dropFirst(index + 1).joined(separator: "\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let text = ASSPlainText.render(body, enabled: assText).trimmingCharacters(in: .newlines)
            return text.isEmpty ? nil : SubtitleCue(start: start, end: end, text: text)
        }.sorted { $0.start < $1.start }
    }
    private static func time(_ input: String) -> Double? {
        guard let stamp = input.trimmingCharacters(in: .whitespaces).split(separator: " ").first else { return nil }
        let parts = stamp.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
    static func visible(_ cues: [SubtitleCue], time: Double, delay: Double) -> String? {
        let position = time - delay
        // Binary search the last started cue; subtitles can overlap, retain nearby active lines.
        var low = 0, high = cues.count
        while low < high { let mid = (low + high) / 2; if cues[mid].start <= position { low = mid + 1 } else { high = mid } }
        guard low > 0 else { return nil }
        let active = cues[max(0, low - 8)..<low].filter { $0.end > position }.map(\.text).joined(separator: "\n")
        return active.isEmpty ? nil : active
    }
}


/// Plain-text fallback for ASS override codes retained by some SRT conversions.
/// This does not replace an ASS renderer: native/VLC and server-burned styles
/// remain with their renderer; only the app's text-delivery path uses this.
enum ASSPlainText {
    private static let overrides = try! NSRegularExpression(pattern: #"\{\\[^{}]*\}"#)
    private static let blocks = try! NSRegularExpression(pattern: #"\{[^{}]*\}"#)
    static func hasOverrides(_ text: String) -> Bool {
        overrides.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    static func render(_ text: String, enabled: Bool = false) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = (enabled ? blocks : overrides).matches(in: text, range: range)
        guard enabled || !matches.isEmpty else { return text }
        var output = "", cursor = text.startIndex, drawing = false, softBreak = false
        func append(_ value: Substring) {
            guard !drawing else { return }
            var index = value.startIndex
            while index < value.endIndex {
                let char = value[index], next = value.index(after: index)
                if char == "\\", next < value.endIndex {
                    switch value[next] {
                    case "N": output.append("\n")
                    case "n": output.append(softBreak ? "\n" : " ")
                    case "h": output.append("\u{00a0}")
                    default: output.append(char); index = next; continue
                    }
                    index = value.index(after: next)
                } else { output.append(char); index = next }
            }
        }
        for match in matches {
            guard let blockRange = Range(match.range, in: text) else { continue }
            append(text[cursor..<blockRange.lowerBound])
            // Only top-level state tags affect the fallback. Tags inside a
            // transform or vector clip are parameters, not drawing switches.
            let block = text[blockRange].dropFirst().dropLast()
            var index = block.startIndex, depth = 0
            while index < block.endIndex {
                let char = block[index]
                if char == "(" { depth += 1 }
                if char == ")" { depth = max(0, depth - 1) }
                if char == "\\", depth == 0 {
                    let name = block.index(after: index)
                    if name < block.endIndex {
                        let tag = block[name], start = block.index(after: name)
                        if tag == "r" { drawing = false; softBreak = false }
                        if tag == "p" || tag == "q" {
                            var end = start
                            while end < block.endIndex, block[end].isASCII, block[end].isNumber { end = block.index(after: end) }
                            if start != end {
                                let number = block[start..<end]
                                if tag == "p" { drawing = number.contains { $0 != "0" } }
                                else { softBreak = number == "2" }
                            }
                        }
                    }
                }
                index = block.index(after: index)
            }
            cursor = blockRange.upperBound
        }
        append(text[cursor...])
        return output
    }
}
