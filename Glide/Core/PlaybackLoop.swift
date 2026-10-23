import Foundation

struct PlaybackLoop: Equatable, Sendable {
    enum Mode: String, Sendable { case repeating, once }
    let start: Double
    let end: Double
    let mode: Mode
    init?(start: Double, end: Double, duration: Double, mode: Mode = .repeating) {
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0,
              start >= 0, end <= duration, end - start >= 0.5 else { return nil }
        self.start = start; self.end = end; self.mode = mode
    }
    func contains(_ time: Double) -> Bool { time.isFinite && time >= start && time < end }
    func reachedEnd(_ time: Double, playing: Bool, seeking: Bool) -> Bool {
        playing && !seeking && time.isFinite && time >= end
    }
}

struct SubtitleTranscript: Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let id = UUID()
        let cue: SubtitleCue
        func range(delay: Double, duration: Double, mode: PlaybackLoop.Mode = .once) -> PlaybackLoop? {
            guard delay.isFinite, duration.isFinite else { return nil }
            return PlaybackLoop(start: max(0, cue.start + delay), end: min(duration, cue.end + delay), duration: duration, mode: mode)
        }
    }
    let entries: [Entry]
    init(cues: [SubtitleCue]) { entries = cues.map { Entry(cue: $0) } }
    func search(_ query: String) -> [Entry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? entries : entries.filter { $0.cue.text.localizedStandardContains(text) }
    }
    func active(at mediaTime: Double, delay: Double) -> Entry? {
        guard mediaTime.isFinite, delay.isFinite else { return nil }
        let time = mediaTime - delay
        var low = 0, high = entries.count
        while low < high { let mid = (low + high) / 2; if entries[mid].cue.start <= time { low = mid + 1 } else { high = mid } }
        guard low > 0 else { return nil }
        return entries[max(0, low - 8)..<low].last { $0.cue.end > time }
    }
}
