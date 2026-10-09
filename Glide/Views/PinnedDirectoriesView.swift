import SwiftUI

struct PinnedDirectoriesView: View {
    var library: LibraryStore
    var onOpen: (DirectoryBookmark) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing: DirectoryBookmark?
    var body: some View {
        NavigationStack {
            List {
                if library.bookmarks.isEmpty {
                    ContentUnavailableView("保存常用刷看", systemImage: "pin", description: Text("进入家庭媒体库或目录，点图钉保存。范围、排序和播放顺序都可以单独设置。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(library.bookmarks) { bookmark in
                    Button { onOpen(bookmark); dismiss() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "folder.fill").foregroundStyle(GlideTheme.accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(bookmark.name).font(.headline).lineLimit(2)
                                Text(library.servers.first { $0.id == bookmark.sourceID }?.name ?? "来源已移除")
                                    .font(.caption).foregroundStyle(GlideTheme.muted)
                                if bookmark.jellyPath.count > 1 {
                                    Text(bookmark.jellyPath.map(\.name).joined(separator: " / ")).font(.caption2).foregroundStyle(GlideTheme.muted).lineLimit(2)
                                } else if !bookmark.davPath.isEmpty {
                                    Text(bookmark.davPath.map(\.lastPathComponent).joined(separator: " / ")).font(.caption2).foregroundStyle(GlideTheme.muted).lineLimit(2)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(GlideTheme.muted)
                        }.padding(.vertical, 8)
                    }.buttonStyle(.plain).accessibilityIdentifier("pin." + bookmark.id)
                        .listRowBackground(GlideTheme.panel)
                        .contextMenu {
                            Button("编辑名称与刷看规则") { editing = bookmark }
                            Button("取消固定", role: .destructive) { library.removeBookmark(bookmark) }
                        }
                        .swipeActions(edge: .leading) { Button("编辑") { editing = bookmark }.tint(GlideTheme.accent) }
                        .swipeActions { Button("取消固定", role: .destructive) { library.removeBookmark(bookmark) } }
                }
                Section {
                    Text("范围与排序按目录保存在本机。固定目录不复制或移动服务器中的文件。")
                        .font(.footnote).foregroundStyle(GlideTheme.muted)
                }.listRowBackground(Color.clear)
            }.scrollContentBackground(.hidden).background(GlideTheme.background)
                .navigationTitle("常用刷看")
                .sheet(item: $editing) { BookmarkEditor(library: library, bookmark: $0) }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(GlideTheme.accent)
    }
}

struct BookmarkEditor: View {
    var library: LibraryStore
    var bookmark: DirectoryBookmark
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var recursive = true
    @State private var sort: VideoSort = .nameAscending
    @State private var mode: PlaybackMode = .sequential
    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("例如：旅行回忆", text: $name).accessibilityIdentifier("bookmark.name") }
                Section("刷看规则") {
                    Toggle("包含子目录", isOn: $recursive).accessibilityIdentifier("bookmark.recursive")
                    Picker("视频排序", selection: $sort) { ForEach(VideoSort.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu).accessibilityIdentifier("bookmark.sort")
                    Picker("播放顺序", selection: $mode) { ForEach(PlaybackMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu).accessibilityIdentifier("bookmark.mode")
                }
                Section { Text("只改变此常用刷看的名称与规则，不会改名、移动或删除服务器目录。").font(.footnote) }
            }.navigationTitle("编辑常用刷看").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        var updated = bookmark; updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.options = BrowseOptions(includesDescendants: recursive, sort: sort); updated.mode = mode
                        updated.accountID = library.servers.first { $0.id == bookmark.sourceID }?.userID
                        library.updateBookmark(updated); dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("bookmark.save") }
                }
                .onAppear {
                    name = bookmark.name; let options = library.options(for: bookmark); recursive = options.includesDescendants; sort = options.sort
                    mode = bookmark.mode ?? PlaybackMode(rawValue: UserDefaults.standard.string(forKey: "playbackMode") ?? "") ?? .sequential
                }
        }.tint(GlideTheme.accent)
    }
}
