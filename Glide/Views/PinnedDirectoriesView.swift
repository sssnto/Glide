import SwiftUI

struct PinnedDirectoriesView: View {
    var library: LibraryStore
    var onOpen: (DirectoryBookmark) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if library.bookmarks.isEmpty {
                    ContentUnavailableView("固定常看的目录", systemImage: "pin", description: Text("进入媒体库或目录，点标题右侧的图钉。下次从这里一键进入。"))
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
                        .swipeActions { Button("取消固定", role: .destructive) { library.removeBookmark(bookmark) } }
                }
                Section {
                    Text("范围与排序按目录保存在本机。固定目录不复制或移动服务器中的文件。")
                        .font(.footnote).foregroundStyle(GlideTheme.muted)
                }.listRowBackground(Color.clear)
            }.scrollContentBackground(.hidden).background(GlideTheme.background)
                .navigationTitle("固定目录")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(GlideTheme.accent)
    }
}
