import Foundation

enum AppSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case home, library, personal, tasks, downloads, sources, settings
    static let primary:[AppSection] = [.home,.library,.personal,.tasks]
    var primaryDestination:AppSection {
        switch self {
        case .downloads:return .tasks
        case .sources,.settings:return .library
        default:return self
        }
    }
    var id: String { rawValue }
}

struct DisplayDivision: Equatable, Sendable {
    var lower: Double
    var upper: Double
}
struct MediaGridPlan: Equatable, Sendable {
    var widths: [Double]
    var spacings: [Double]
    static func make(width: Double, minimum: Double, spacing: Double = 12, singleColumn: Bool = false,
                     hasDivision: Bool = false, verticalDivision: DisplayDivision? = nil) -> Self {
        guard width.isFinite, width > 0, minimum.isFinite, minimum > 0, spacing.isFinite, spacing >= 0 else { return Self(widths: [], spacings: []) }
        if singleColumn { return Self(widths: [width], spacings: [0]) }
        if let division = verticalDivision, division.lower.isFinite, division.upper.isFinite,
           division.lower > 0, division.upper < width, division.upper >= division.lower {
            let leading = division.lower, trailing = width - division.upper
            let count = max(1, min(5, Int(min(5, (min(leading, trailing) + spacing) / (minimum + spacing)))))
            let a = max(1, (leading - Double(count - 1) * spacing) / Double(count))
            let b = max(1, (trailing - Double(count - 1) * spacing) / Double(count))
            var gaps = Array(repeating: spacing, count: count * 2)
            gaps[count - 1] = division.upper - division.lower; gaps[gaps.count - 1] = 0
            return Self(widths: Array(repeating: a, count: count) + Array(repeating: b, count: count), spacings: gaps)
        }
        var count = max(1, min(10, Int(min(10, (width + spacing) / (minimum + spacing)))))
        if hasDivision, count > 1, count % 2 != 0 { count -= 1 }
        let cell = max(1, (width - Double(count - 1) * spacing) / Double(count))
        return Self(widths: Array(repeating: cell, count: count), spacings: (0..<count).map { $0 + 1 == count ? 0 : spacing })
    }
}

/// A viewport resize preserves the relative focal point and retires in-flight gestures.
enum VideoViewport {
    static func offset(_ offset: CGSize, from old: CGSize, to new: CGSize, zoom: Double) -> CGSize {
        guard old.width.isFinite, old.height.isFinite, new.width.isFinite, new.height.isFinite,
              old.width > 0, old.height > 0, new.width > 0, new.height > 0, zoom.isFinite, zoom >= 1,
              offset.width.isFinite, offset.height.isFinite else { return CGSize(width: 0, height: 0) }
        let limitX = new.width * (zoom - 1) / 2, limitY = new.height * (zoom - 1) / 2
        return CGSize(width: max(-limitX, min(limitX, offset.width * new.width / old.width)),
                      height: max(-limitY, min(limitY, offset.height * new.height / old.height)))
    }
}
