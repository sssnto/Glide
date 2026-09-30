import SwiftUI

struct AdaptiveLibraryRoot: View {
    var library: LibraryStore
    @State private var destination: String? = "library"
    @State private var phoneTab = PhoneTab.library
    @State private var personalPlayback: Video?
    private enum PhoneTab: Hashable { case library, personal, downloads, settings }
    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            NavigationSplitView {
                List(selection: $destination) {
                    Label("媒体库", systemImage: "rectangle.stack").tag("library")
                    Label("收藏与继续观看", systemImage: "heart").tag("personal")
                    Label("离线下载", systemImage: "arrow.down.circle").tag("downloads")
                    Label("媒体来源", systemImage: "externaldrive").tag("sources")
                    Label("设置", systemImage: "gearshape").tag("settings")
                }.navigationTitle("Glide").navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
            } detail: {
                switch destination {
                case "settings": NavigationStack { SettingsView(library: library) }
                case "downloads": NavigationStack { DownloadsView(library: library) }
                case "sources": SourcesView(library: library)
                case "personal": PersonalLibraryView(library: library, onPlay: { personalPlayback = $0 }, presentedAsSheet: false)
                default: LibraryView(library: library)
                }
            }.fullScreenCover(item: $personalPlayback) { video in
                PlayerView(library: library, queue: PlaybackQueue(videos: [video], mode: .sequential), scopeName: "个人片库")
            }
        } else {
            TabView(selection: $phoneTab) {
                LibraryView(library: library)
                    .tabItem { Label("片库", systemImage: "square.stack.fill") }
                    .tag(PhoneTab.library)
                PersonalLibraryView(library: library, onPlay: { personalPlayback = $0 }, presentedAsSheet: false)
                    .tabItem { Label("继续与收藏", systemImage: "heart.text.square") }
                    .tag(PhoneTab.personal)
                NavigationStack { DownloadsView(library: library) }
                    .tabItem { Label("离线", systemImage: "arrow.down.circle") }
                    .tag(PhoneTab.downloads)
                NavigationStack { SettingsView(library: library) }
                    .tabItem { Label("设置", systemImage: "gearshape") }
                    .tag(PhoneTab.settings)
            }
            .tint(GlideTheme.accent)
            .fullScreenCover(item: $personalPlayback) { video in
                PlayerView(library: library, queue: PlaybackQueue(videos: [video], mode: .sequential), scopeName: "个人片库")
            }
        }
    }
}
