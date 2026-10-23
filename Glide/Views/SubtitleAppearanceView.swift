import SwiftUI

private enum SubtitleAppearanceStorage {
    static let key = "externalSubtitleAppearance.v1"
}

struct SubtitleAppearanceView: View {
    @AppStorage(SubtitleAppearanceStorage.key) private var data = Data()
    @AppStorage("subtitleScale") private var legacyScale = 100.0
    @AppStorage("externalSubtitleSecondaryScale") private var legacySecondary = 85.0
    private var appearance: SubtitleAppearance { .restore(data, legacyScale: legacyScale, legacySecondaryScale: legacySecondary) }
    var body: some View {
        Form {
            Section("实时预览") {
                SubtitleCaptionStack(primary: "你好，世界。", secondary: "Hello, world.", appearance: appearance)
                    .frame(maxWidth: .infinity, minHeight: 120).background(Color(red: 0.18, green: 0.29, blue: 0.31), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("subtitles.appearance.preview")
            }
            lineSection("主字幕", lane: .primary)
            lineSection("第二字幕", lane: .secondary)
            Section("字幕背景") {
                Slider(value: Binding(get: { appearance.background }, set: { var value = appearance; value.background = $0; data = value.encoded() }), in: 0...1, step: 0.05) {
                    Text("背景不透明度")
                }.accessibilityIdentifier("subtitles.appearance.background")
                Text("背景不透明度：\(Int((appearance.background * 100).rounded()))%")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("恢复默认样式") { data = SubtitleAppearance().encoded() }.accessibilityIdentifier("subtitles.appearance.reset")
                Text("样式作用于本机画面中的外部文字字幕，并立即保存。内嵌样式、图形字幕与服务器烧录字幕由各自播放器控制。").font(.footnote).foregroundStyle(.secondary)
            }
        }.font(GlideTheme.Typography.body).scrollContentBackground(.hidden).background(GlideTheme.background)
            .navigationTitle("字幕样式").navigationBarTitleDisplayMode(.inline)
    }
    private func line(_ lane: SubtitleLane) -> SubtitleLineAppearance { lane == .primary ? appearance.primary : appearance.secondary }
    private func binding<T>(_ lane: SubtitleLane, _ path: WritableKeyPath<SubtitleLineAppearance, T>) -> Binding<T> {
        Binding(get: { line(lane)[keyPath: path] }, set: { updated in
            var value = appearance, row = line(lane); row[keyPath: path] = updated
            if lane == .primary { value.primary = row } else { value.secondary = row }
            data = value.encoded()
        })
    }
    private func lineSection(_ title: String, lane: SubtitleLane) -> some View {
        Section(title) {
            Stepper("字号：\(Int(line(lane).size))", value: binding(lane, \.size), in: 12...40, step: 1)
                .accessibilityIdentifier("subtitles.appearance." + lane.rawValue + ".size")
            Picker("颜色", selection: binding(lane, \.ink)) {
                ForEach(SubtitleInk.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }.accessibilityIdentifier("subtitles.appearance." + lane.rawValue + ".ink")
            Stepper("描边：\(line(lane).outline, specifier: "%.1f")", value: binding(lane, \.outline), in: 0...2, step: 0.5)
                .accessibilityIdentifier("subtitles.appearance." + lane.rawValue + ".outline")
        }
    }
}

struct SubtitleCaptionStack: View {
    var primary: String?
    var secondary: String?
    var appearance: SubtitleAppearance
    var body: some View {
        VStack(spacing: 4) {
            if let primary { SubtitleStyledLine(text: primary, appearance: appearance.primary).accessibilityIdentifier("player.subtitle.overlay") }
            if let secondary { SubtitleStyledLine(text: secondary, appearance: appearance.secondary).accessibilityIdentifier("player.subtitle.secondary.overlay") }
        }.padding(6).background(.black.opacity(appearance.safe.background), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct SubtitleStyledLine: View {
    var text: String
    var appearance: SubtitleLineAppearance
    private let directions: [CGSize] = [.init(width: -1, height: -1), .init(width: 0, height: -1), .init(width: 1, height: -1), .init(width: -1, height: 0), .init(width: 1, height: 0), .init(width: -1, height: 1), .init(width: 0, height: 1), .init(width: 1, height: 1)]
    private var ink: Color {
        switch appearance.ink { case .white: .white; case .warm: Color(red: 1, green: 0.91, blue: 0.68); case .yellow: .yellow; case .cyan: .cyan }
    }
    var body: some View {
        let style = appearance.safe
        Text(text).foregroundStyle(ink)
            .background {
                if style.outline > 0 {
                    Canvas { context, size in
                        let outline = context.resolve(Text(text).font(.system(size: style.size, weight: .medium)).foregroundColor(.black))
                        for direction in directions {
                            context.draw(outline, in: CGRect(origin: CGPoint(x: direction.width * style.outline, y: direction.height * style.outline), size: size))
                        }
                    }.accessibilityHidden(true)
                }
            }
            .font(.system(size: style.size, weight: .medium)).multilineTextAlignment(.center)
            .accessibilityLabel(text)
    }
}
