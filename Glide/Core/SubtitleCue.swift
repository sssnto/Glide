import Foundation

struct SubtitleCue: Equatable {
    var start: Double
    var end: Double
    var text: String
    static func parse(_ input: String) -> [SubtitleCue] {
        let blocks = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let pair = lines[index].components(separatedBy: "-->")
            guard pair.count == 2, let start = time(pair[0]), let end = time(pair[1]), end > start else { return nil }
            let text = lines.dropFirst(index + 1).joined(separator: "\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
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
