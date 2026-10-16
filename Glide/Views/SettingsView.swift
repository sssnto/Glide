import SwiftUI
import AVKit

struct SettingsView: View {
    var library: LibraryStore
    @AppStorage("preferredAudioLanguage") private var audio = ""
    @AppStorage("preferredSubtitleLanguage") private var subtitle = ""
    @AppStorage("forcedSubtitlesOnly") private var forced = false
    @AppStorage("subtitleScale") private var scale = 100.0
    @AppStorage("cellularPlayback") private var cellular = true
    @AppStorage("downloadWiFiOnly") private var wifi = true
    @AppStorage("downloadLimitGB") private var limit = 20
    @AppStorage("seekInterval") private var seek = 10.0
    @AppStorage("controlsDelay") private var delay = 3.0
    @State private var clearing = false
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Toggle("允许蜂窝网络播放", isOn: $cellular)
                Picker("快进与快退", selection: $seek) { ForEach([5.0, 10, 15, 30], id: \.self) { Text("\(Int($0)) 秒").tag($0) } }
                Picker("控制栏自动隐藏", selection: $delay) { ForEach([3.0, 5, 8], id: \.self) { Text("\(Int($0)) 秒").tag($0) } }

            } header: { Text("播放") } footer: { Text("播放器优先使用原画，必要时请求 Jellyfin 转码。服务器需允许当前账号转码。") }
            Section {
                languagePicker("首选声音", selection: $audio, allowOff: false)
                languagePicker("首选字幕", selection: $subtitle, allowOff: true)
                Toggle("仅匹配强制字幕", isOn: $forced)
                Picker("文字字幕大小", selection: $scale) { ForEach([80.0, 100, 125, 150], id: \.self) { Text("\(Int($0))%").tag($0) } }

            } header: { Text("声音与字幕") } footer: { Text("优先按语言匹配下一集；找不到时使用服务器默认。字幕大小适用于系统文字字幕。") }
            Section {
                if let message = library.storageMessage {
                    Label(message, systemImage: "externaldrive.badge.exclamationmark").font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.storageStatus")
                }
                Toggle("新下载仅使用 Wi-Fi", isOn: $wifi)
                Picker("离线容量预算", selection: $limit) { ForEach([5, 10, 20, 50, 100], id: \.self) { Text("\($0) GB").tag($0) } }
                NavigationLink("管理离线下载") { DownloadsView(library: library) }
                Button(clearing ? "正在清理…" : "清理海报与媒体缓存") {
                    clearing = true
                    Task {
                        for server in library.servers { await MediaCache.shared.clear(server: server) }
                        await ArtworkCache.shared.clear(); clearing = false; message = "已清理缓存，收藏、进度和下载文件保留。"
                    }
                }.disabled(clearing).accessibilityIdentifier("settings.clearCache")
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }

            } header: { Text("下载与存储") } footer: { Text("Wi-Fi 偏好仅作用于新下载；已暂停的任务可继续。") }
            Section {
                NavigationLink("最近一次播放诊断") { DiagnosticView(diagnostic: PlaybackController.lastDiagnostic) }
                NavigationLink("操作指南") { GestureHelpView() }
                NavigationLink("数据、隐私与帮助") { PrivacySupportView() }
                NavigationLink("开源组件") { OpenSourceNoticesView() }
                LabeledContent("版本", value: PlaybackPreferences.appVersion)

            } header: { Text("帮助与反馈") } footer: { Text("反馈时请附版本、设备和复现步骤。诊断导出前可预览，内容不包含片名、服务器地址或凭据。") }
        }.scrollContentBackground(.hidden).background(GlideTheme.background)
            .tint(GlideTheme.accent)
            .font(GlideTheme.Typography.body).navigationTitle("设置").navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("settings.screen")
    }
    private func languagePicker(_ title: String, selection: Binding<String>, allowOff: Bool) -> some View {
        Picker(title, selection: selection) {
            Text("服务器默认").tag("")
            if allowOff { Text("关闭字幕").tag("off") }
            Text("中文").tag("zh"); Text("英语").tag("en"); Text("日语").tag("ja"); Text("韩语").tag("ko")
        }
    }
}

private struct OpenSourceNoticesView: View {
    private var notices: String {
        let names = ["ThirdPartyNotices", "MobileVLCKit-LGPL-2.1", "SubtitleFont-OFL"]
        return names.compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }.joined(separator: "\n\n")
    }
    var body: some View {
        ScrollView { Text(notices).font(.footnote).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            .navigationTitle("开源组件").navigationBarTitleDisplayMode(.inline)
    }
}

struct DiagnosticView: View {
    let diagnostic: PlaybackDiagnostic
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    MediaInfoChip(diagnostic.state, symbol: "waveform.path.ecg", emphasized: true)
                    Spacer()
                    Text(diagnostic.version).font(GlideTheme.Typography.technical).foregroundStyle(GlideTheme.muted)
                }
                Text("媒体参数来自服务器；输出尺寸与观察码率由播放器测得。服务器流的处理方式未确认时会如实标注。").font(GlideTheme.Typography.secondary).foregroundStyle(.secondary)
                Text(diagnostic.export).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("diagnostic.json")
                ShareLink(item: diagnostic.export) { Label("分享诊断", systemImage: "square.and.arrow.up") }.accessibilityIdentifier("diagnostic.share")
            }.padding(20).frame(maxWidth: 720)
        }.frame(maxWidth: .infinity).background(GlideTheme.background).navigationTitle("播放诊断").navigationBarTitleDisplayMode(.inline)
    }
}

struct AirPlayControl: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.tintColor = .white; view.activeTintColor = .systemGreen
        view.prioritizesVideoDevices = true; view.accessibilityLabel = "AirPlay 播放设备"; return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
