import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var editing: MediaServer?
    @State private var removing: MediaServer?
    @State private var importingVideos = false
    @State private var mountingDirectory = false
    @State private var reauthorizing: MediaServer?
    @State private var importing = false
    @State private var importMessage: String?
    @State private var importError: String?
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section {
                    Button { library.showDemo(); dismiss() } label: {
                        Label("离线演示片库", systemImage: "sparkles").foregroundStyle(.primary)
                    }
                }.disabled(importing)
                Section("本地视频") {
                    Button { importingVideos = true } label: { Label("导入视频文件", systemImage: "square.and.arrow.down") }
                        .accessibilityIdentifier("sources.importVideos")
                    Button { reauthorizing = nil; mountingDirectory = true } label: { Label("添加本地目录", systemImage: "folder.badge.plus") }
                        .accessibilityIdentifier("sources.mountDirectory")
                    if importing { ProgressView("正在导入，请保持应用打开…") }
                    if let importMessage { Text(importMessage).font(.footnote).foregroundStyle(.secondary) }
                    Text("导入会复制视频到 Glide；添加目录只保存授权，文件仍留在原位置。播放格式取决于设备与所选播放器。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.disabled(importing)
                Section {
                    NavigationLink { StreamLinksView(library: library) } label: { Label("链接与 STRM", systemImage: "link") }
                        .accessibilityIdentifier("sources.links")
                }
                Section("我的来源") {
                    ForEach(library.servers) { server in
                        Button {
                            Task { await library.select(server.id) }
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: server.kind.symbol).foregroundStyle(GlideTheme.accent)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(server.name).foregroundStyle(.primary)
                                    Text(server.kind == .local ? (server.localBookmark == nil ? "设备内导入的视频" : "已授权本地目录") : server.address.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if library.selectedID == server.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(GlideTheme.accent) }
                            }.padding(.vertical, 6)
                        }
                        .accessibilityIdentifier("source." + server.id.uuidString).id(server.id)
                        .swipeActions {
                            if server.kind != .local || server.localBookmark != nil { Button("移除", role: .destructive) { removing = server } }
                            if server.kind.requiresCredentials { Button("重新登录") { editing = server }.tint(.blue) }
                            else if server.localBookmark != nil { Button("重新授权") { reauthorizing = server; mountingDirectory = true }.tint(.blue) }
                        }
                        .contextMenu {
                            if server.kind.requiresCredentials { Button("编辑与重新登录") { editing = server } }
                            else if server.localBookmark != nil { Button("重新授权目录") { reauthorizing = server; mountingDirectory = true } }
                        }
                    }

                }.disabled(importing)
                Section { NavigationLink("设置") { SettingsView(library: library) } }
                Section {
                    Text("Jellyfin 与 Emby 支持媒体库与服务器转码。NAS 可通过 SMB 2/3 或 WebDAV 浏览视频；SMB 使用兼容播放器，WebDAV 使用系统播放器。")
                    Text("账号凭据仅保存在此设备的系统钥匙串中。")
                }.font(.footnote).foregroundStyle(.secondary)
            }.accessibilityIdentifier("sources.list")
                .scrollContentBackground(.hidden).background(GlideTheme.background)
                .font(GlideTheme.Typography.body).navigationTitle("媒体来源").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { adding = true } label: { Label("添加媒体源", systemImage: "plus") }.accessibilityIdentifier("sources.add").disabled(importing) }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(importing) }
                }
                .confirmationDialog("移除媒体来源", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                    if let server = removing {
                        Button("移除来源，保留已下载影片", role: .destructive) { library.remove(server); removing = nil }
                        if server.kind != .local { Button("同时删除此来源的离线影片", role: .destructive) { library.remove(server, includingDownloads: true); removing = nil } }
                    }
                    Button("取消", role: .cancel) { removing = nil }
                } message: { Text(removing?.kind == .local ? "仅移除来源和对应的本机收藏，原目录与已导入的视频文件保留。再次导入或授权可重新观看。" : "未完成的下载会停止；本机收藏与历史会移除。服务器文件不受影响。") }
                .sheet(isPresented: $adding) { AddSourceView(library: library) }
                .sheet(item: $editing) { ReconnectSourceView(library: library, server: $0) }
                .fileImporter(isPresented: $importingVideos, allowedContentTypes: [.movie, .video], allowsMultipleSelection: true) { result in
                    do {
                        let urls = try result.get()
                        guard !urls.isEmpty else { return }
                        importing = true; importMessage = nil
                        Task {
                            defer { importing = false }
                            do { let count = try await library.importLocalVideos(urls); importMessage = "已导入 \(count) 个视频。" }
                            catch { importError = error.localizedDescription }
                        }
                    } catch { importError = error.localizedDescription }
                }
                .fileImporter(isPresented: $mountingDirectory, allowedContentTypes: [.folder]) { result in
                    do {
                        let url = try result.get(), original = reauthorizing
                        reauthorizing = nil
                        Task {
                            do { try await library.mountLocalDirectory(url, replacing: original); importMessage = "目录已添加，可返回片库开始观看。" }
                            catch { importError = error.localizedDescription }
                        }
                    } catch { importError = error.localizedDescription }
                }
                .alert("本地来源", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                    Button("知道了") { importError = nil }
                } message: { Text(importError ?? "") }
                .interactiveDismissDisabled(importing)
                .onAppear { if let id = library.selectedID { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: library.selectedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: adding) { _, open in if !open, let id = library.selectedID { proxy.scrollTo(id, anchor: .center) } }
            }
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
    @State private var share = ""
    @State private var guest = false
    @State private var domain = ""
    @State private var encrypted = false
    @State private var verifiedSMB: SMBVerification?
    @State private var remembersPlayback = false
    @State private var connecting = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    private enum Field: Hashable { case name, address, share, username, password }
    @FocusState private var focusedField: Field?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "externaldrive.badge.wifi").font(.title2).foregroundStyle(GlideTheme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("连接媒体服务器").font(GlideTheme.Typography.sectionTitle)
                            Text("填写地址与账号，直接浏览现有媒体库。").font(GlideTheme.Typography.secondary).foregroundStyle(GlideTheme.muted)
                        }
                    }.padding(.vertical, 4)
                }.listRowBackground(Color.clear)
                Section {
                    Picker("连接方式", selection: $kind) { ForEach(SourceKind.allCases.filter(\.requiresCredentials)) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                }
                Section("服务器") {
                    TextField("名称（可选）", text: $name)
                        .focused($focusedField, equals: .name).submitLabel(.next).onSubmit { focusedField = .address }
                    TextField(kind == .smb ? "192.168.1.10" : kind.isCatalogSource ? "http://192.168.1.10:8096" : "https://nas.example.com:5006/video/", text: $address)
                        .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("服务器地址")
                        .focused($focusedField, equals: .address).submitLabel(.next).onSubmit { focusedField = kind == .smb ? .share : .username }
                    if kind == .smb {
                        TextField("共享目录，例如 video/家庭视频", text: $share)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("sources.smbShare")
                            .focused($focusedField, equals: .share).submitLabel(.next).onSubmit { focusedField = guest ? nil : .username }
                    }
                }
                Section("登录账号") {
                    if kind == .smb { Toggle("访客访问", isOn: $guest).accessibilityIdentifier("sources.smbGuest") }
                    if kind != .smb || !guest {
                    TextField("用户名", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedField, equals: .username).submitLabel(.next).onSubmit { focusedField = .password }
                    SecureField("密码", text: $password).textContentType(.password)
                        .focused($focusedField, equals: .password).submitLabel(.done).onSubmit { focusedField = nil }
                    }
                    if kind == .smb {
                        DisclosureGroup("高级选项") {
                            TextField("域（可选）", text: $domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Toggle("要求 SMB 3 加密", isOn: $encrypted)
                        }
                        Button("测试连接") { testSMB() }.accessibilityIdentifier("sources.testSMB")
                            .disabled(address.isEmpty)
                        if let verifiedSMB {
                            Label("连接成功，可读取 \(verifiedSMB.entries.count) 个条目", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(GlideTheme.accent)
                        }
                    }
                }
                Section {
                    Label(kind == .smb ? "在 NAS 中启用 SMB 2/3，填写服务器地址与共享目录。只读访问，不会修改远端文件。访客访问需要服务器允许。" : kind.isCatalogSource ? "连接同一网络的 \(kind.title)，或填写可访问的远程地址。支持服务器配置的路径前缀，例如 /emby 或 /jellyfin。" : "请先在 NAS 中启用 WebDAV，并填写视频目录地址。支持 Basic 认证；服务器需要支持 Range 分段读取。", systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                    if address.lowercased().hasPrefix("http://") { Text("此地址使用明文 HTTP，仅建议在可信局域网中使用。远程连接请使用 HTTPS。") .font(.footnote).foregroundStyle(.orange) }
                }
                if kind.isFileSource {
                    Section("播放记录") {
                        Toggle("记住播放进度", isOn: $remembersPlayback).accessibilityIdentifier("sources.remembersPlayback")
                        Text("开启后保存观看进度，并加入最近观看。关闭时保留从头刷看的习惯。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error { Section { Text(error).font(.callout).foregroundStyle(.red) } }
            }.disabled(connecting).scrollContentBackground(.hidden).background(GlideTheme.background)
                .safeAreaInset(edge: .bottom) {
                    Button(action: connect) {
                        HStack(spacing: 10) {
                            if connecting { ProgressView().tint(GlideTheme.onAccent) }
                            Text(connecting ? "正在连接…" : "连接并打开片库").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(GlideTheme.onAccent)
                        .background(GlideTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(connecting || address.isEmpty || (kind.isCatalogSource && username.isEmpty))
                    .opacity(connecting || address.isEmpty || (kind.isCatalogSource && username.isEmpty) ? 0.5 : 1)
                    .accessibilityIdentifier("sources.connect")
                    .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
                    .background(GlideTheme.background)
                }
                .font(GlideTheme.Typography.body).navigationTitle("添加媒体源").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { task?.cancel(); dismiss() } } }
                .interactiveDismissDisabled(connecting)
                .onDisappear { task?.cancel() }
                .onChange(of: [address, share, username, password, domain, String(guest), String(encrypted)]) { _, _ in verifiedSMB = nil }
        }.tint(GlideTheme.accent)
    }
    private func connect() {
        connecting = true; error = nil
        task = Task {
            do {
                let url = try kind == .smb ? SMBLocation.parse(address: address, share: share).absoluteString : address
                try await library.add(name: name, kind: kind, address: url, username: kind == .smb && guest ? "" : username, password: kind == .smb && guest ? "" : password,
                    smb: kind == .smb ? SMBOptions(guest: guest, domain: domain, encrypted: encrypted) : nil,
                    verifiedSMB: kind == .smb ? verifiedSMB : nil, remembersPlayback: remembersPlayback)
                password = ""; dismiss()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            connecting = false
        }
    }
    private func testSMB() {
        connecting = true; error = nil; verifiedSMB = nil
        task = Task {
            do {
                var candidate = MediaServer(name: name, kind: .smb, address: try SMBLocation.parse(address: address, share: share), username: guest ? "" : username)
                candidate.smb = SMBOptions(guest: guest, domain: domain, encrypted: encrypted)
                verifiedSMB = try await SMBSourceProvider.verify(server: candidate, password: guest ? "" : password)
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
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(gestures, id: \.0) { gesture in
                        HStack(spacing: 18) {
                            Image(systemName: gesture.0).font(.title2).foregroundStyle(GlideTheme.accent).frame(width: 38)
                            VStack(alignment: .leading, spacing: 6) { Text(gesture.1).font(GlideTheme.Typography.itemTitle); Text(gesture.2).font(GlideTheme.Typography.secondary).foregroundStyle(GlideTheme.muted) }
                        }
                    }
                    Text("也可以通过播放按钮、上一部／下一部按钮和进度条操作。支持 iPhone 与 iPad 横竖屏。") .font(.footnote).foregroundStyle(GlideTheme.muted).padding(.top, 8)
                }.padding(20).frame(maxWidth: 720)
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
    @State private var remembersPlayback = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section("来源") {
                    TextField("名称", text: $name)
                    TextField("服务器地址", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(server.kind.isFileSource)
                    LabeledContent("账号", value: server.username)
                    SecureField("重新输入密码", text: $password)
                    if server.kind.isFileSource { Toggle("记住播放进度", isOn: $remembersPlayback) }
                    Text("保留此来源的收藏、目录和观看记录。切换账号请添加新来源。").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.orange) }
                Button(busy ? "正在验证…" : "验证并保存") {
                    busy = true; error = nil
                    task = Task {
                        do { try await library.reconnect(server, name: name, address: address, password: password, remembersPlayback: server.kind.isFileSource ? remembersPlayback : nil); password = ""; dismiss() }
                        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                        busy = false
                    }
                }.disabled(busy).accessibilityIdentifier("source.reconnect")
            }.font(GlideTheme.Typography.body).scrollContentBackground(.hidden).background(GlideTheme.background).navigationTitle("编辑与重新登录").navigationBarTitleDisplayMode(.inline).interactiveDismissDisabled(busy)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { task?.cancel(); dismiss() } } }
                .onAppear { name = server.name; address = server.address.absoluteString; remembersPlayback = server.remembersPlayback == true }
                .onDisappear { task?.cancel() }
        }
    }
}
