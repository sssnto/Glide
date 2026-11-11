import SwiftUI

private struct MediaGridSpace: Equatable {
    var width: Double = 0
    var hasDivision = false
    var vertical: DisplayDivision?
}

/// The content keeps one identity while its columns adapt to the proposal and reserved regions.
struct AdaptiveMediaGrid<Content: View>: View {
    var minimum: CGFloat
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 18
    @ViewBuilder var content: () -> Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var space = MediaGridSpace()
    private var columns: [GridItem] {
        let plan = MediaGridPlan.make(width: space.width, minimum: minimum, spacing: spacing, singleColumn: dynamicTypeSize.isAccessibilitySize,
                                      hasDivision: space.hasDivision, verticalDivision: space.vertical)
        if plan.widths.isEmpty { return dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: minimum), spacing: spacing, alignment: .top)] }
        return zip(plan.widths, plan.spacings).map { GridItem(.fixed($0.0), spacing: $0.1, alignment: .top) }
    }
    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: rowSpacing, content: content)
            .onGeometryChange(for: MediaGridSpace.self) { proxy in
                var result = MediaGridSpace(width: proxy.size.width)
#if GLIDE_DUO_SDK
                if #available(iOS 27.1, *) {
                    let regions = proxy.reservedRegions(kind: .division, options: .includeInactive)
                    result.hasDivision = !regions.isEmpty
                    if let region = regions.first(where: { $0.isActive && $0.frame.height > $0.frame.width }) {
                        if layoutDirection == .rightToLeft {
                            result.vertical = DisplayDivision(lower: max(0, proxy.size.width - region.frame.maxX - region.margins.leading),
                                                              upper: min(proxy.size.width, proxy.size.width - region.frame.minX + region.margins.trailing))
                        } else {
                            result.vertical = DisplayDivision(lower: max(0, region.frame.minX - region.margins.leading),
                                                              upper: min(proxy.size.width, region.frame.maxX + region.margins.trailing))
                        }
                    }
                }
#endif
                return result
            } action: { value in if space != value { space = value } }
    }
}

/// Two stable children, rather than a conditional HStack/VStack that discards their state.
struct MediaDetailColumns: Layout {
    var expanded: Bool
    var direction: LayoutDirection = .leftToRight
    var spacing: CGFloat = 24
    private func twoColumns(_ width: CGFloat) -> Bool { expanded && width >= 640 }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 340
        let split = twoColumns(width), cell = split ? (width - spacing) / 2 : width
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)) }
        return CGSize(width: width, height: split ? sizes.map(\.height).max() ?? 0 : sizes.reduce(0) { $0 + $1.height } + CGFloat(max(0, sizes.count - 1)) * spacing)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let split = twoColumns(bounds.width), cell = split ? (bounds.width - spacing) / 2 : bounds.width
        var y = bounds.minY
        for (index, view) in subviews.enumerated() {
            let column = direction == .rightToLeft ? subviews.count - 1 - index : index
            view.place(at: CGPoint(x: bounds.minX + (split ? CGFloat(column) * (cell + spacing) : 0), y: split ? bounds.minY : y), anchor: .topLeading, proposal: ProposedViewSize(width: cell, height: nil))
            if !split { y += view.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height + spacing }
        }
    }
}
