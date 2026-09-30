import SwiftUI

enum TrackKind: String, Identifiable { case audio, subtitle; var id: String { rawValue } }
struct PlaybackOptionRow: View {
    var title: String
    var value: String
    var body: some View {
        HStack(spacing: 16) {
            Text(title).foregroundStyle(GlideTheme.text).fixedSize()
            Spacer(minLength: 0)
            Text(value).font(.subheadline).foregroundStyle(GlideTheme.accent).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(GlideTheme.muted)
        }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
    }
}
struct TrackChoicesView: View {
    var title: String
    var streams: [CatalogItem.Stream]
    @Binding var selection: Int
    var allowsOff: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                choice("服务器默认", index: -2)
                if allowsOff { choice("关闭字幕", index: -1) }
                ForEach(streams) { stream in choice(stream.label, index: stream.Index) }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(GlideTheme.accent)
    }
    private func choice(_ label: String, index: Int) -> some View {
        Button { selection = index; dismiss() } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(label).font(.body).fixedSize(horizontal: false, vertical: true).foregroundStyle(GlideTheme.text)
                Spacer(minLength: 0)
                if selection == index { Image(systemName: "checkmark").foregroundStyle(GlideTheme.accent) }
            }.padding(.vertical, 10)
        }.accessibilityLabel(label)
    }
}
