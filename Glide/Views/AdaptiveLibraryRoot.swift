import SwiftUI

struct AdaptiveLibraryRoot: View {
    var library: LibraryStore
    @State private var destination: String? = "home"
    @State private var phoneTab = PhoneTab.home
    @State private var personalPlayback: Video?
    private enum PhoneTab: Hashable { case home, library, personal, downloads, settings }
    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            NavigationSplitView {
                List(selection: $destination) {
                    Label("首页", systemImage: "house").tag("home")
                    Label("媒体库", systemImage: "rectangle.stack").tag("library")
                    Label("收藏与继续观看", systemImage: "heart").tag("personal")
                    Label("离线下载", systemImage: "arrow.down.circle").tag("downloads")
                    Label("媒体来源", systemImage: "externaldrive").tag("sources")
                    Label("设置", systemImage: "gearshape").tag("settings")
                }.scrollContentBackground(.hidden).background(GlideTheme.background).navigationTitle("Glide").navigationBarTitleDisplayMode(.inline).navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
            } detail: {
                switch destination {
                case "home": DiscoveryHomeView(library: library)
                case "settings": NavigationStack { SettingsView(library: library) }
                case "downloads": NavigationStack { DownloadsView(library: library) }
                case "sources": SourcesView(library: library)
                case "personal": PersonalLibraryView(library: library, onPlay: { personalPlayback = $0 }, presentedAsSheet: false)
                default: LibraryView(library: library)
                }
            }.fullScreenCover(item: $personalPlayback) { video in
                PlayerView(library: library, queue: PlaybackQueue(videos: [video], mode: .sequential), scopeName: "个人片库", cinematic: ["Movie", "Episode"].contains(video.mediaType ?? ""))
            }
        } else {
            TabView(selection: $phoneTab) {
                DiscoveryHomeView(library: library)
                    .tabItem { Label("首页", systemImage: "house.fill") }
                    .tag(PhoneTab.home)
                LibraryView(library: library)
                    .tabItem { Label("片库", systemImage: "square.stack.fill") }
                    .tag(PhoneTab.library)
                PersonalLibraryView(library: library, onPlay: { personalPlayback = $0 }, presentedAsSheet: false)
                    .tabItem { Label("我的", systemImage: "heart.text.square") }
                    .tag(PhoneTab.personal)
                NavigationStack { DownloadsView(library: library) }
                    .tabItem { Label("离线", systemImage: "arrow.down.circle") }
                    .tag(PhoneTab.downloads)
                NavigationStack { SettingsView(library: library) }
                    .tabItem { Label("设置", systemImage: "gearshape") }
                    .tag(PhoneTab.settings)
            }
            .tint(GlideTheme.accent)
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("--glide-trip-fixture") { phoneTab = .downloads }
                if ProcessInfo.processInfo.arguments.contains("--glide-link-fixture") { phoneTab = .library }
                guard ProcessInfo.processInfo.arguments.contains("--glide-ui-audit") else { return }
                phoneTab = .library
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--glide-ui-audit-settings") { phoneTab = .settings }
                if arguments.contains("--glide-ui-audit-downloads") { phoneTab = .downloads }
                if arguments.contains("--glide-ui-audit-personal") { phoneTab = .personal }
                if arguments.contains("--glide-ui-audit-player") {
                    personalPlayback = Video(id: "ui-audit-demo", title: "Glide 播放预览", subtitle: "本地演示", url: Bundle.main.url(forResource: "demo0", withExtension: "mp4"), demoIndex: 0)
                }
            }
            #endif
            .fullScreenCover(item: $personalPlayback) { video in
                PlayerView(library: library, queue: PlaybackQueue(videos: [video], mode: .sequential), scopeName: "个人片库", cinematic: ["Movie", "Episode"].contains(video.mediaType ?? ""))
            }
        }
    }
}
