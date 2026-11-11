import SwiftUI
import AVFoundation

struct VideoRotationEditor: View {
    var library: LibraryStore
    var videoTitle: String?
    var expectedFilename: String?
    var willReplace: () -> Void = {}
    var didSave: () -> Void = {}
    @State private var model = VideoRotationEditorModel()
    @State private var connecting = false
    @State private var confirmSave = false
    @State private var restoring: VideoRotationReceipt?
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    private var webDAV: [MediaServer] { library.servers.filter { $0.kind == .webDAV } }
    private var nameMatches: Bool {
        guard let expectedFilename,!expectedFilename.isEmpty,let selected=model.selected else { return true }
        return expectedFilename.localizedCaseInsensitiveCompare(selected.url.lastPathComponent) == .orderedSame
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section {
                    Text("把方向修正写入服务器原文件，控制器保持正常位置。支持 MP4、MOV、M4V；只修改方向信息，不重新编码视频、音轨或字幕。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let videoTitle { LabeledContent("正在校正",value:videoTitle) }
                    if let expectedFilename { LabeledContent("服务器原文件名",value:expectedFilename).font(.caption).textSelection(.enabled) }
                }
                Section("WebDAV 写入目录") {
                    ForEach(webDAV) { server in
                        Button { Task { await model.connect(server) } } label: {
                            Label(server.name,systemImage:model.server?.id == server.id ? "checkmark.circle.fill" : "externaldrive.connected.to.line.below")
                        }.disabled(model.saving || model.loading)
                    }
                    Button("添加 WebDAV 写入目录",systemImage:"plus") { connecting=true }.disabled(model.saving || model.loading)
                    Text("选择与媒体服务器指向同一原文件的可写目录。账号密码保存在钥匙串。")
                        .font(.caption).foregroundStyle(.secondary)
                }
#if DEBUG
                if (ProcessInfo.processInfo.arguments.contains("--glide-rotation-qa") || Bundle.main.bundleIdentifier == "com.songpeng.glide.rotationqa"),model.server != nil {
                    Section("原创短片验收") {
                        Button("验证旋转保存与原样还原") { Task { await model.validateDirectory() } }.disabled(model.saving || model.loading)
                            .accessibilityIdentifier("rotation.qa.run")
                        Text(model.validationResult).accessibilityIdentifier("rotation.qa.result")
                        Text("仅创建带随机名称的原创测试短片及其备份，验证后清理。不会改动目录中的其他视频。").font(.caption).foregroundStyle(.secondary)
                    }
                }
#endif
                if model.prepared != nil || model.receipt != nil {
                    Section("预览方向") {
                        rotationPreview.frame(height:280).listRowInsets(EdgeInsets()).listRowBackground(Color.black)
                        HStack {
                            Button("左转 90°",systemImage:"rotate.left") { rotate(-1) }.accessibilityIdentifier("rotation.left")
                            Spacer()
                            Button("右转 90°",systemImage:"rotate.right") { rotate(1) }.accessibilityIdentifier("rotation.right")
                        }.buttonStyle(.borderless).frame(minHeight:44).disabled(model.saving || model.prepared == nil)
                        LabeledContent("相对原方向",value:model.turn.title)
                        Button("恢复原方向") { model.turn = .original }.disabled(model.saving || model.prepared == nil)
                        if !model.previewReady { Text("正在准备预览。若文件编码无法预览，请保留原文件并更换处理方式。").font(.caption).foregroundStyle(.secondary) }
                        if let selected=model.selected { Text(selected.url.lastPathComponent).font(.caption).textSelection(.enabled) }
                        if !nameMatches { Text("选中文件名与服务器原文件名不一致，请重新选择原文件。").foregroundStyle(.orange) }
                        Toggle("确认这是要替换的服务器原文件",isOn:$model.confirmedFile).disabled(model.saving || model.prepared == nil || !nameMatches)
                            .accessibilityIdentifier("rotation.confirmFile")
                        Button("备份并替换原文件",systemImage:"square.and.arrow.down") { confirmSave=true }
                            .disabled(model.prepared == nil || !model.previewReady || model.turn == .original || !model.confirmedFile || !nameMatches || model.saving)
                            .accessibilityIdentifier("rotation.save")
                        Text("会上传并校验临时文件，保留原始备份后才替换。保存时请保持应用打开；文件被他人修改时会拒绝覆盖。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.id("rotation.preview")
                }
                if model.loading || model.saving { Section { ProgressView(model.stage.isEmpty ? "正在读取…" : model.stage) } }
                if let error=model.error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                if let message=model.message { Section { Label(message,systemImage:"checkmark.circle").foregroundStyle(.secondary) } }
                if let server=model.server,let directory=model.directory {
                    Section("选择原文件") {
                        Text(directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if DirectoryScope.key(directory) != DirectoryScope.key(server.address) {
                            Button("上一级",systemImage:"arrow.up") { Task { await model.browse(directory.deletingLastPathComponent()) } }.disabled(model.loading || model.saving)
                        }
                        TextField("筛选文件名",text:$query).textInputAutocapitalization(.never).autocorrectionDisabled()
                        ForEach(Array(model.entries.filter { query.isEmpty || $0.name.localizedStandardContains(query) }.prefix(250))) { entry in
                            Button {
                                Task { if entry.isDirectory { await model.browse(entry.url) } else { await model.choose(entry) } }
                            } label: {
                                Label(entry.name,systemImage:entry.isDirectory ? "folder" : "film")
                                    .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                            }.disabled(model.loading || model.saving || (!entry.isDirectory && !["mp4","mov","m4v"].contains(entry.url.pathExtension.lowercased())))
                        }
                        Text("预览前会读取原文件并用少量临时文件检查写入保护。每次最多显示 250 项，可筛选名称。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !model.history.isEmpty {
                    Section("保存与恢复记录") {
                        ForEach(model.history) { receipt in
                            VStack(alignment:.leading,spacing:8) {
                                Text(receipt.original.lastPathComponent).font(.subheadline)
                                Text(receipt.date,style:.date).font(.caption).foregroundStyle(.secondary)
                                Text("备份："+receipt.backup.lastPathComponent).font(.caption2).textSelection(.enabled)
                                if receipt.state == "saved" {
                                    Button("从备份还原原文件") { restoring=receipt }.disabled(model.saving || model.loading)
                                } else if receipt.state != "unchanged" {
                                    Button("核对上次保存状态") { Task { await model.resolve(receipt) } }.disabled(model.saving || model.loading)
                                } else { Text("原文件未发生替换").font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical,4)
                        }
                    }
                }
            }
                .onChange(of:model.prepared?.file) { _, file in
                    if file != nil { withAnimation { proxy.scrollTo("rotation.preview",anchor:.top) } }
                }
                .navigationTitle("修正视频方向").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() }.disabled(model.saving) } }
                .interactiveDismissDisabled(model.saving)
                .sheet(isPresented:$connecting) { RotationWebDAVConnection(library:library) { server in Task { await model.connect(server) } } }
                .confirmationDialog("替换所选服务器原文件？",isPresented:$confirmSave,titleVisibility:.visible) {
                    Button("备份并替换原文件",role:.destructive) { Task { if await model.save(willReplace:willReplace) { didSave() } } }.accessibilityIdentifier("rotation.publish.confirm")
                } message: { Text((model.selected?.url.lastPathComponent ?? "")+"\n原始备份会保留在同一目录。其他播放器重新读取文件后也会使用修正后的方向。") }
                .confirmationDialog("从备份还原此文件？",isPresented:Binding(get:{ restoring != nil },set:{ if !$0 { restoring=nil } }),titleVisibility:.visible) {
                    if let restoring { Button("还原原文件",role:.destructive) { Task { let value=restoring;self.restoring=nil;if await model.restore(value,willReplace:willReplace) { didSave() } } }.accessibilityIdentifier("rotation.restore.confirm") }
                } message: { Text((restoring?.original.lastPathComponent ?? "")+"\n仅在当前文件仍与这次保存结果一致时还原。当前文件也会另行备份。") }
                .task {
                    if model.server == nil,let source=webDAV.first { await model.connect(source) }
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--glide-rotation-nas-probe") { await model.validateDirectory() }
#endif
                }
                .onDisappear { model.close() }
            }
        }
    }
    private func rotate(_ delta: Int) { model.turn=VideoQuarterTurn(rawValue:(model.turn.rawValue+delta+4)%4)! }
    private var rotationPreview: some View {
        GeometryReader { geometry in
            let swaps=model.turn.swapsAxes
            VideoSurface(presentation:.native(model.player),onLayer:model.attachLayer,identity:model.selected?.id ?? "rotation-preview",title:"原文件方向预览",frameReady:model.previewReady,locked:true,filled:false,onSwipe:{ _ in },onToggle:{},onSeek:{ _ in },onSpeedPreset:{ _ in },onHUD:{ _ in })
                .frame(width:swaps ? geometry.size.height : geometry.size.width,height:swaps ? geometry.size.width : geometry.size.height)
                .rotationEffect(.degrees(Double(model.turn.degrees)))
                .position(x:geometry.size.width/2,y:geometry.size.height/2)
        }.clipped().accessibilityLabel("视频方向预览，"+model.turn.title)
    }
}

private struct RotationWebDAVConnection: View {
    var library: LibraryStore
    var connected: (MediaServer) -> Void
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var loading = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("WebDAV 目录地址",text:$address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("rotation.connection.address")
                TextField("用户名",text:$username).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("rotation.connection.username")
                SecureField("密码",text:$password).privacySensitive().accessibilityIdentifier("rotation.connection.password")
                Text("请输入具有此目录读写权限的账号。密码仅保存在设备钥匙串。").font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                Button { Task { await connect() } } label: { if loading { ProgressView() } else { Text("连接并保存") } }.disabled(loading || address.isEmpty)
            }.navigationTitle("WebDAV 写入目录").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() }.disabled(loading) } }
                .interactiveDismissDisabled(loading)
                .onAppear {
#if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--glide-rotation-qa") { address=UserDefaults.standard.string(forKey:"glideRotationQAAddress") ?? "" }
#endif
                }
        }
    }
    private func connect() async {
        loading=true;error=nil;defer { loading=false }
        do {
            try await library.add(name:"方向修正目录",kind:.webDAV,address:address,username:username,password:password)
            if let source=library.servers.last { password="";connected(source);dismiss() }
        } catch { self.error=error.localizedDescription }
    }
}
