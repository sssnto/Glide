import SwiftUI

struct SourcesView: View {
    var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var editing: MediaServer?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { library.showDemo(); dismiss() } label: {
                        Label("离线演示片库", systemImage: "sparkles").foregroundStyle(.primary)
                    }
                }
                Section("我的服务器") {
                    ForEach(library.servers) { server in
                        Button {
                            Task { await library.select(server.id) }
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: server.kind.symbol).foregroundStyle(GlideTheme.accent)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(server.name).foregroundStyle(.primary)
                                    Text(server.address.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if library.selectedID == server.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(GlideTheme.accent) }
                            }.padding(.vertical, 6)
                        }
                        .accessibilityIdentifier("source." + server.id.uuidString)
                        .swipeActions { Button("移除", role: .destructive) { library.remove(server) }; Button("重新登录") { editing = server }.tint(.blue) }
                        .contextMenu { Button("编辑与重新登录") { editing = server } }
                    }
                    Button { adding = true } label: { Label("添加媒体源", systemImage: "plus.circle.fill") }.accessibilityIdentifier("sources.add")
                }
                Section { NavigationLink("设置") { SettingsView(library: library) } }
                Section {
                    Text("Jellyfin 支持媒体库、播放进度和服务器转码。NAS 可通过 WebDAV 直接浏览并播放系统支持的视频格式。")
                    Text("账号凭据仅保存在此设备的系统钥匙串中。")
                }.font(.footnote).foregroundStyle(.secondary)
            }.scrollContentBackground(.hidden).background(GlideTheme.background)
                .navigationTitle("媒体来源")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $adding) { AddSourceView(library: library) }
                .sheet(item: $editing) { ReconnectSourceView(library: library, server: $0) }
        }.tint(GlideTheme.accent)
    }
}

struct AddSourceView: View {
    var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind = SourceKind.jellyfin
    @State private var name = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connecting = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "externaldrive.badge.wifi").font(.largeTitle).foregroundStyle(GlideTheme.accent)
                        Text("连接你的私人影院").font(.title2.weight(.semibold))
                        Text("视频留在你的服务器，精彩随身。").font(.subheadline).foregroundStyle(GlideTheme.muted)
                    }.padding(.vertical, 12)
                }.listRowBackground(Color.clear)
                Section {
                    Picker("连接方式", selection: $kind) { ForEach(SourceKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                }
                Section("服务器") {
                    TextField("名称（可选）", text: $name)
                    TextField(kind == .jellyfin ? "http://192.168.1.10:8096" : "https://nas.example.com:5006/video/", text: $address)
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("服务器地址")
                }
                Section("登录账号") {
                    TextField("用户名", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password).textContentType(.password)
                }
                Section {
                    Label(kind == .jellyfin ? "连接与你的设备处于同一网络的 Jellyfin，或填写可访问的远程地址。支持包含 /jellyfin 等路径前缀的地址。" : "请先在 NAS 中启用 WebDAV，并填写视频目录地址。支持 Basic 认证；服务器需要支持 Range 分段读取。", systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                    if address.lowercased().hasPrefix("http://") { Text("此地址使用明文 HTTP，仅建议在可信局域网中使用。远程连接请使用 HTTPS。") .font(.footnote).foregroundStyle(.orange) }
                }
                if let error { Section { Text(error).font(.callout).foregroundStyle(.red) } }
            }.disabled(connecting).scrollContentBackground(.hidden).background(GlideTheme.background)
                .safeAreaInset(edge: .bottom) {
                    Button(action: connect) {
                        HStack(spacing: 10) {
                            if connecting { ProgressView().tint(.black) }
                            Text(connecting ? "正在连接…" : "连接并打开片库").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .foregroundStyle(.black)
                        .background(GlideTheme.accent, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .disabled(connecting || address.isEmpty || (kind == .jellyfin && username.isEmpty))
                    .opacity(connecting || address.isEmpty || (kind == .jellyfin && username.isEmpty) ? 0.5 : 1)
                    .accessibilityIdentifier("sources.connect")
                    .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
                    .background(GlideTheme.background)
                }
                .navigationTitle("添加媒体源").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { task?.cancel(); dismiss() } } }
                .interactiveDismissDisabled(connecting)
                .onDisappear { task?.cancel() }
        }.tint(GlideTheme.accent)
    }
    private func connect() {
        connecting = true; error = nil
        task = Task {
            do {
                try await library.add(name: name, kind: kind, address: address, username: username, password: password)
                password = ""; dismiss()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            connecting = false
        }
    }
}

struct GestureHelpView: View {
    @Environment(\.dismiss) private var dismiss
    let gestures: [(String, String, String)] = [
        ("hand.draw", "上下滑动", "切换下一部 / 上一部视频"),
        ("forward.fill", "左右滑动", "右滑切换 2×，左滑恢复正常速度"),
        ("hand.point.up.left.fill", "长按画面左侧 / 右侧", "快退 / 快进设置的秒数"),
        ("arrow.up.left.and.arrow.down.right", "双指捏合", "1–4 倍缩放画面；每次切片自动复位"),
        ("hand.point.up.braille", "拖动画面", "放大后可用单指或双指向任意方向移动；缩回原大小后恢复切片与倍速手势"),
        ("hand.tap", "单击 / 双指轻点", "单击显示或隐藏控制；双指轻点播放或暂停"),
        ("lock", "锁定触控", "避免误触；点击屏幕后可解锁")]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text("少一点操作，\n多一点沉浸。").font(.largeTitle.bold()).padding(.bottom, 8)
                    ForEach(gestures, id: \.0) { gesture in
                        HStack(spacing: 18) {
                            Image(systemName: gesture.0).font(.title2).foregroundStyle(GlideTheme.accent).frame(width: 38)
                            VStack(alignment: .leading, spacing: 6) { Text(gesture.1).font(.headline); Text(gesture.2).font(.subheadline).foregroundStyle(GlideTheme.muted) }
                        }
                    }
                    Text("也可以通过播放按钮、上一部／下一部按钮和进度条操作。支持 iPhone 与 iPad 横竖屏。") .font(.footnote).foregroundStyle(GlideTheme.muted).padding(.top, 8)
                }.padding(26)
            }.background(GlideTheme.background).navigationTitle("手势指南").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("知道了") { dismiss() } } }
        }.tint(GlideTheme.accent)
    }
}


struct ReconnectSourceView: View {
    var library: LibraryStore
    var server: MediaServer
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section("来源") {
                    TextField("名称", text: $name)
                    TextField("服务器地址", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(server.kind == .webDAV)
                    LabeledContent("账号", value: server.username)
                    SecureField("重新输入密码", text: $password)
                    Text("保留此来源的收藏、目录和观看记录。切换账号请添加新来源。").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.orange) }
                Button(busy ? "正在验证…" : "验证并保存") {
                    busy = true; error = nil
                    task = Task {
                        do { try await library.reconnect(server, name: name, address: address, password: password); password = ""; dismiss() }
                        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                        busy = false
                    }
                }.disabled(busy).accessibilityIdentifier("source.reconnect")
            }.navigationTitle("编辑与重新登录").interactiveDismissDisabled(busy)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { task?.cancel(); dismiss() } } }
                .onAppear { name = server.name; address = server.address.absoluteString }
                .onDisappear { task?.cancel() }
        }
    }
}
