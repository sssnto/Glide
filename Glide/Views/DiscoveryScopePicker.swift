import SwiftUI

struct DiscoveryScopePicker: View {
    var library: LibraryStore
    @State var selected: [DiscoveryScope]
    var onSave: ([DiscoveryScope]) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if !selected.isEmpty {
                    Section("已选范围 · \(selected.count)/16") {
                        ForEach(selected) { scope in
                            HStack {
                                Label(scope.name, systemImage: "checkmark.circle.fill")
                                Spacer()
                                Button { selected.removeAll { $0.id == scope.id } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).accessibilityLabel("移除“\(scope.name)”")
                            }
                        }
                    }
                }
                Section {
                    Button("使用当前片库范围", systemImage: "rectangle.stack") { toggle(DiscoveryResolver.current(library)) }
                        .accessibilityIdentifier("discovery.scope.current")
                    scopeRow(.demo)
                } header: { Text("快捷选择") }
                Section("已连接来源") {
                    ForEach(library.servers) { server in scopeRow(DiscoveryResolver.root(server)) }
                    if library.servers.isEmpty { Text("连接来源后，可以选择媒体库、剧集、目录或单个视频。").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("选择内容范围").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onSave(selected); dismiss() }.disabled(selected.isEmpty).accessibilityIdentifier("discovery.scope.done")
                }
            }
        }
    }
    @ViewBuilder private func scopeRow(_ scope: DiscoveryScope) -> some View {
        HStack {
            if scope.kind == .demo || scope.kind == .video { Text(scope.name).frame(maxWidth: .infinity, alignment: .leading) }
            else { NavigationLink { DiscoveryScopeBrowser(library: library, scope: scope, selected: $selected, onDone: { onSave($0); dismiss() }) } label: { Text(scope.name) } }
            Button { toggle(scope) } label: { Image(systemName: selected.contains(where: { $0.id == scope.id }) ? "checkmark.circle.fill" : "plus.circle").font(.title3).frame(minWidth: 44, minHeight: 44) }
                .buttonStyle(.borderless).disabled(selected.count >= 16 && !selected.contains(where: { $0.id == scope.id }))
                .accessibilityLabel("选择“\(scope.name)”").accessibilityIdentifier("discovery.scope.toggle." + scope.id)
        }
    }
    private func toggle(_ scope: DiscoveryScope) {
        if selected.contains(where: { $0.id == scope.id }) { selected.removeAll { $0.id == scope.id } }
        else if selected.count < 16 { selected.append(scope) }
    }
}

private struct DiscoveryScopeBrowser: View {
    var library: LibraryStore
    var scope: DiscoveryScope
    @Binding var selected: [DiscoveryScope]
    var onDone: ([DiscoveryScope]) -> Void
    @State private var children: [DiscoveryScope] = []
    @State private var loading = true
    @State private var error: String?
    @State private var retry = 0
    var body: some View {
        List {
            Button(selected.contains(where: { $0.id == scope.id }) ? "移除此范围" : "加入整个范围", systemImage: "checkmark.circle") { toggle(scope) }
                .disabled(selected.count >= 16 && !selected.contains(where: { $0.id == scope.id }))
                .accessibilityIdentifier("discovery.scope.entire")
            if loading { ProgressView("正在读取…") }
            if let error { Text(error).foregroundStyle(.secondary); Button("重试") { retry += 1 } }
            if !loading && children.isEmpty && error == nil { Text("此范围内没有可选择的内容。").foregroundStyle(.secondary) }
            ForEach(children) { child in
                HStack {
                    if child.kind == .video { Label(child.name, systemImage: "play.rectangle").frame(maxWidth: .infinity, alignment: .leading) }
                    else { NavigationLink { DiscoveryScopeBrowser(library: library, scope: child, selected: $selected, onDone: onDone) } label: { Label(child.name, systemImage: "folder") } }
                    Button { toggle(child) } label: { Image(systemName: selected.contains(where: { $0.id == child.id }) ? "checkmark.circle.fill" : "plus.circle").font(.title3).frame(minWidth: 44, minHeight: 44) }
                        .buttonStyle(.borderless).disabled(selected.count >= 16 && !selected.contains(where: { $0.id == child.id }))
                        .accessibilityLabel("选择“\(child.name)”")
                }
            }
        }.navigationTitle(scope.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("完成") { onDone(selected) }.disabled(selected.isEmpty).accessibilityIdentifier("discovery.scope.done")
            } }
            .task(id: retry) {
                loading = true; error = nil
                do { let values = try await DiscoveryResolver.children(scope, library: library); try Task.checkCancellation(); children = values; loading = false }
                catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
            }
    }
    private func toggle(_ scope: DiscoveryScope) {
        if selected.contains(where: { $0.id == scope.id }) { selected.removeAll { $0.id == scope.id } }
        else if selected.count < 16 { selected.append(scope) }
    }
}
