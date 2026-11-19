import SwiftUI

/// Owns layout only. The caller retains playback, queue and interaction state across display changes.
struct AdaptivePlayerLayout<Picture: View, Controls: View>: View {
    var expanded: Bool
    @ViewBuilder var picture: () -> Picture
    @ViewBuilder var controls: () -> Controls
    var body: some View {
#if GLIDE_DUO_SDK
        if #available(iOS 27.1, *), expanded {
            ArrangementView {
                picture().clipped()
            } secondary: {
                controls()
            }
            .arrangementViewStyle(.split)
        } else { fallback }
#else
        fallback
#endif
    }
    private var fallback: some View {
        let layout = expanded ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(ZStackLayout())
        return layout {
            // The fullscreen surface extends behind safe areas. Clipping its
            // safe-area-sized parent cuts off that fitted image on Duo.
            picture()
            controls().frame(width: expanded ? 340 : 0, height: expanded ? nil : 0).clipped()
                .opacity(expanded ? 1 : 0).allowsHitTesting(expanded).accessibilityHidden(!expanded)
        }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }
}

/// Extra insets are queried in the custom canvas's coordinate space, never from UIScreen.
extension PlayerChromeInsets {
    static func read(_ proxy: GeometryProxy, headerHeight: CGFloat = 44) -> Self {
        var frames: [CGRect] = []
#if GLIDE_DUO_SDK
        if #available(iOS 27.1, *) {
            frames = proxy.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame)
        }
#endif
        return avoiding(size: proxy.size, headerHeight: headerHeight, occlusions: frames)
    }
}
