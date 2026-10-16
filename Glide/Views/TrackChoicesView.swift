import SwiftUI

enum TrackKind: String, Identifiable { case audio, subtitle; var id: String { rawValue } }

/// Structured server fields carry the short label; the full release title stays in the chooser.
enum TrackDisplay {
    static func codec(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "h264", "avc", "avc1": return "H.264"
        case "hevc", "h265", "hvc1", "hev1": return "HEVC"
        case "eac3": return "E-AC-3"
        case "ac3": return "AC-3"
        case "dca": return "DTS"
        case "hdmv_pgs_subtitle", "pgssub": return "PGS"
        case "subrip": return "SRT"
        case "mov_text": return "文本"
        default: return value.uppercased()
        }
    }
    static func language(_ stream: CatalogItem.Stream) -> String? {
        guard let language = stream.Language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !language.isEmpty, language.lowercased() != "und" else { return nil }
        return Locale(identifier: "zh-Hans").localizedString(forLanguageCode: language) ?? language
    }
    static func title(_ stream: CatalogItem.Stream) -> String {
        language(stream) ?? (stream.Type == "Audio" ? "音轨 \(stream.Index)" : "字幕 \(stream.Index)")
    }
    static func summary(_ stream: CatalogItem.Stream) -> String {
        [title(stream), codec(stream.Codec), stream.IsForced == true ? "强制" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
    static func attributes(_ stream: CatalogItem.Stream) -> [String] {
        [codec(stream.Codec), stream.IsDefault == true ? "默认" : nil, stream.IsForced == true ? "强制" : nil]
            .compactMap { $0 }
    }
}

struct PlaybackOptionRow: View {
    var title: String
    var value: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        HStack(spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) { titleText; valueText }
            } else {
                titleText
                Spacer(minLength: 8)
                valueText.multilineTextAlignment(.trailing)
            }
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                .foregroundStyle(GlideTheme.muted).accessibilityHidden(true)
        }.frame(maxWidth: .infinity, minHeight: 48).padding(.vertical, 4).contentShape(Rectangle())
    }
    private var titleText: some View { Text(title).font(.subheadline).foregroundStyle(GlideTheme.text).fixedSize() }
    private var valueText: some View {
        Text(value).font(.caption).foregroundStyle(GlideTheme.muted)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2).fixedSize(horizontal: false, vertical: true)
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
                Section {
                    choice("服务器默认", index: -2)
                    if allowsOff { choice("关闭字幕", index: -1) }
                }
                if !streams.isEmpty {
                    Section("可用轨道 · \(streams.count)") {
                        ForEach(streams) { stream in
                            Button { select(stream.Index) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(TrackDisplay.title(stream)).font(.subheadline.weight(.semibold)).foregroundStyle(GlideTheme.text)
                                            Text("#\(stream.Index)").font(.caption2).monospacedDigit().foregroundStyle(GlideTheme.muted)
                                        }
                                        if let label = stream.DisplayTitle, !label.isEmpty {
                                            Text(label).font(.caption).foregroundStyle(GlideTheme.muted)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        let attributes = TrackDisplay.attributes(stream)
                                        if !attributes.isEmpty {
                                            Text(attributes.joined(separator: " · ")).font(.caption2.weight(.medium)).foregroundStyle(GlideTheme.accent)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    selectionMark(stream.Index)
                                }.padding(.vertical, 8).frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .accessibilityLabel(stream.label)
                            .accessibilityValue(selection == stream.Index ? "已选择" : "")
                            .accessibilityAddTraits(selection == stream.Index ? [.isSelected] : [])
                        }
                    }
                }
            }.scrollContentBackground(.hidden).background(GlideTheme.background)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(GlideTheme.accent)
    }
    private func select(_ index: Int) { selection = index; dismiss() }
    private func choice(_ label: String, index: Int) -> some View {
        Button { select(index) } label: {
            HStack(spacing: 12) {
                Text(label).font(.subheadline).foregroundStyle(GlideTheme.text)
                Spacer(minLength: 0)
                selectionMark(index)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityLabel(label)
            .accessibilityValue(selection == index ? "已选择" : "")
            .accessibilityAddTraits(selection == index ? [.isSelected] : [])
    }
    @ViewBuilder private func selectionMark(_ index: Int) -> some View {
        if selection == index { Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(GlideTheme.accent).accessibilityHidden(true) }
    }
}
