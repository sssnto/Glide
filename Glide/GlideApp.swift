import SwiftUI

@main
struct GlideApp: App {
    @UIApplicationDelegateAdaptor(GlideAppDelegate.self) private var appDelegate
    @State private var library = LibraryStore()
    var body: some Scene {
        WindowGroup {
            AdaptiveLibraryRoot(library: library)
                .preferredColorScheme(.dark)
                .tint(GlideTheme.accent)
                .foregroundStyle(GlideTheme.text)
        }
    }
}
