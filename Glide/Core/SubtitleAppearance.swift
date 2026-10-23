import Foundation

enum SubtitleInk: String, Codable, CaseIterable, Sendable {
    case white, warm, yellow, cyan
    var title: String { switch self { case .white: "白色"; case .warm: "暖黄"; case .yellow: "黄色"; case .cyan: "青色" } }
}
struct SubtitleLineAppearance: Codable, Equatable, Sendable {
    var size: Double
    var ink: SubtitleInk
    var outline: Double
    var safe: Self {
        Self(size: size.isFinite ? min(40, max(12, size)) : 20, ink: ink, outline: outline.isFinite ? min(2, max(0, outline)) : 1)
    }
}
struct SubtitleAppearance: Codable, Equatable, Sendable {
    var primary = SubtitleLineAppearance(size: 20, ink: .white, outline: 1)
    var secondary = SubtitleLineAppearance(size: 17, ink: .warm, outline: 1)
    var background = 0.6
    var safe: Self {
        var copy = self; copy.primary = primary.safe; copy.secondary = secondary.safe
        copy.background = background.isFinite ? min(1, max(0, background)) : 0.6
        return copy
    }
    static func restore(_ data: Data, legacyScale: Double = 100, legacySecondaryScale: Double = 85) -> Self {
        if let saved = try? JSONDecoder().decode(Self.self, from: data) { return saved.safe }
        var value = Self()
        value.primary.size = 20 * legacyScale / 100
        value.secondary.size = value.primary.size * legacySecondaryScale / 100
        return value.safe
    }
    func encoded() -> Data { (try? JSONEncoder().encode(safe)) ?? Data() }
}
