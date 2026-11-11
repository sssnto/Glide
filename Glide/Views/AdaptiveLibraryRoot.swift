import SwiftUI

struct AdaptiveLibraryRoot: View {
    var library: LibraryStore
    @SceneStorage("glide.selectedSection") private var selectedSection = AppSection.home.rawValue
    @State private var personalPlayback: Video?
#if DEBUG
    @State private var appliedLaunchDestination=false
#endif
    private var selection: Binding<AppSection> {
        Binding(get: { (AppSection(rawValue: selectedSection) ?? .home).primaryDestination }, set: { selectedSection = $0.rawValue })
    }
    var body: some View {
        Group {
            if #available(iOS 18, *) { adaptiveTabs }
            else { legacyTabs }
        }
        .tint(GlideTheme.accent)
        .fullScreenCover(item: $personalPlayback) { video in
            PlayerView(library: library, queue: PlaybackQueue(videos: [video], mode: .sequential), scopeName: "个人片库", cinematic: ["Movie", "Episode"].contains(video.mediaType ?? ""))
        }
#if DEBUG
        .onAppear {
            guard !appliedLaunchDestination else { return };appliedLaunchDestination=true
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--glide-v2-preview") { selectedSection = AppSection.home.rawValue }
            if arguments.contains("--glide-discovery-fixture") { selectedSection = AppSection.home.rawValue }
            if arguments.contains("--glide-trip-fixture") { selectedSection = AppSection.tasks.rawValue }
            if arguments.contains("--glide-link-fixture") { selectedSection = AppSection.library.rawValue }
            guard arguments.contains("--glide-ui-audit") else { return }
            selectedSection = AppSection.library.rawValue
            if arguments.contains("--glide-ui-audit-settings") { selectedSection = AppSection.library.rawValue }
            if arguments.contains("--glide-ui-audit-downloads") { selectedSection = AppSection.tasks.rawValue }
            if arguments.contains("--glide-ui-audit-personal") { selectedSection = AppSection.personal.rawValue }
            if arguments.contains("--glide-ui-audit-player") {
                personalPlayback = Video(id: "ui-audit-demo", title: "Glide 播放预览", subtitle: "本地演示", url: Bundle.main.url(forResource: "demo0", withExtension: "mp4"), demoIndex: 0)
            }
        }
#endif
    }
    @available(iOS 18, *) private var adaptiveTabs: some View {
        TabView(selection: selection) {
            Tab("观看", systemImage: "play.rectangle.fill", value: AppSection.home) { DiscoveryHomeView(library: library, openLibrary: { selectedSection = AppSection.library.rawValue }) }
            Tab("片库", systemImage: "square.stack.fill", value: AppSection.library) { LibraryView(library: library) }
            Tab("收藏", systemImage: "heart.fill", value: AppSection.personal) { personal }
            Tab("任务", systemImage: "arrow.down.circle", value: AppSection.tasks) { NavigationStack { WorkspaceTasksView(library:library) } }
        }.tabViewStyle(.sidebarAdaptable)
    }
    private var legacyTabs: some View {
        TabView(selection:selection) {
            DiscoveryHomeView(library:library,openLibrary:{ selectedSection = AppSection.library.rawValue }).tabItem { Label("观看",systemImage:"play.rectangle.fill") }.tag(AppSection.home)
            LibraryView(library:library).tabItem { Label("片库",systemImage:"square.stack.fill") }.tag(AppSection.library)
            personal.tabItem { Label("收藏",systemImage:"heart.fill") }.tag(AppSection.personal)
            NavigationStack { WorkspaceTasksView(library:library) }.tabItem { Label("任务",systemImage:"arrow.down.circle") }.tag(AppSection.tasks)
        }
    }
    private var personal: some View {
        PersonalLibraryView(library: library, onPlay: { personalPlayback = $0 }, presentedAsSheet: false)
    }
}
