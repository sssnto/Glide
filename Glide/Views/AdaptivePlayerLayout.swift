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
            picture().clipped()
            controls().frame(width: expanded ? 340 : 0).clipped()
                .opacity(expanded ? 1 : 0).allowsHitTesting(expanded).accessibilityHidden(!expanded)
        }
    }
}

/// Extra insets are queried in the custom canvas's coordinate space, never from UIScreen.
struct PlayerChromeInsets: Equatable {
    var top: CGFloat = 0
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    static func read(_ proxy: GeometryProxy) -> Self {
        var result = Self()
#if GLIDE_DUO_SDK
        if #available(iOS 27.1, *) {
            for region in proxy.reservedRegions(kind: .occlusion) where region.isActive {
                if region.frame.minY < 100, region.frame.maxY > 0 {
                    result.top = max(result.top, region.frame.maxY + region.margins.bottom - proxy.safeAreaInsets.top)
                }
            }
        }
#endif
        return result
    }
}
