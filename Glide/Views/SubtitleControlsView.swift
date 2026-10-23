import SwiftUI
import UniformTypeIdentifiers

struct SubtitleControlsView: View {
    var playback: PlaybackController
    var requestImport: (SubtitleLane) -> Void
    @State private var importingFont = false
    @State private var fontMessage: String?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("externalSubtitleBottom") private var bottom = 12.0
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("字幕全文与台词定位") { SubtitleTranscriptView(playback: playback) }.accessibilityIdentifier("subtitles.transcript.open")
                    NavigationLink("单句重播与 A–B 循环") { PlaybackLoopView(playback: playback) }.accessibilityIdentifier("subtitles.loop.open")
                    NavigationLink("字幕样式与预览") { SubtitleAppearanceView() }.accessibilityIdentifier("subtitles.appearance.open")
                }
                if !playback.serverSubtitleOptions.isEmpty {
                    Section {
                        NavigationLink {
                            ServerSubtitleChoices(playback: playback)
                        } label: {
                            LabeledContent("服务器字幕", value: "\(playback.serverSubtitleOptions.count) 条可选")
                        }.accessibilityIdentifier("subtitles.server.open")
                    }
                }
                laneSection(playback.subtitles)
                laneSection(playback.secondarySubtitles)
                Section("ASS 原样渲染") {
                    Text("ASS／SSA 保留原字体、颜色、定位和特效，不受普通字幕样式和底部距离设置影响。优先使用视频附带字体；缺失时可导入原字体。").font(.footnote).foregroundStyle(.secondary)
                    Button("导入字幕字体…", systemImage: "textformat") { importingFont = true }.accessibilityIdentifier("subtitles.font.import")
                    if let fontMessage { Text(fontMessage).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("显示") {
                    Stepper("底部距离：\(Int(bottom))%", value: $bottom, in: 5...35, step: 2)
                    Text("主字幕在上，第二字幕在下。两路分别调整偏移，正值让字幕晚出现，负值让字幕早出现。").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("关闭全部字幕") { playback.closeExternalSubtitles() }.accessibilityIdentifier("subtitles.closeAll")
                    if playback.subtitles.hasMemory || playback.secondarySubtitles.hasMemory {
                        Button("清除此视频的两路记忆", role: .destructive) { playback.forgetSubtitles() }.accessibilityIdentifier("subtitles.forgetAll")
                    }
                    Text("双字幕支持外部 SRT／VTT／ASS／SSA。ASS 保持各自原始布局，重叠时请选择另一字幕。先选择主字幕，再添加第二字幕。内嵌字幕使用单字幕模式；外部字幕仅显示在本机画面中。").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("subtitles.controls.list")
            .font(GlideTheme.Typography.body).scrollContentBackground(.hidden).background(GlideTheme.background)
            .navigationTitle("字幕控制").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("subtitles.done") } }
        }.fileImporter(isPresented: $importingFont, allowedContentTypes: [UTType(filenameExtension: "ttf") ?? .data, UTType(filenameExtension: "otf") ?? .data, UTType(filenameExtension: "ttc") ?? .data]) { result in
            Task { @MainActor in
                do {
                    let url = try result.get()
                    try await Task.detached { try ASSFontStore.importFont(url) }.value
                    playback.subtitles.reloadASSFonts(); playback.secondarySubtitles.reloadASSFonts()
                    fontMessage = "字体已导入，当前 ASS 字幕已重新渲染。"
                } catch { fontMessage = error.localizedDescription }
            }
        }.tint(GlideTheme.accent).presentationDetents([.large]).presentationDragIndicator(.visible)
    }
    @ViewBuilder private func laneSection(_ session: SubtitleSession) -> some View {
        let lane = session.lane
        let enabled = lane == .primary || playback.subtitles.hasASS || session.hasASS || !playback.subtitles.cues.isEmpty || !session.cues.isEmpty
        Section(lane.title) {
            LabeledContent("当前", value: session.activeName ?? (lane == .primary ? playback.selectedServerSubtitle?.label ?? playback.selectedSubtitle?.displayName ?? "关闭" : "关闭"))
                .accessibilityIdentifier("subtitles." + lane.rawValue + ".name")
            if session.discovering || session.reading { ProgressView(session.reading ? "正在读取…" : "正在匹配…") }
            Button(lane == .primary ? "导入主字幕…" : "导入第二字幕…", systemImage: "doc.badge.plus") {
                requestImport(lane); dismiss()
            }.disabled(!enabled || session.reading).accessibilityIdentifier("subtitles." + lane.rawValue + ".import")
            if let saved = session.importedCopy {
                Button("使用已导入：" + saved.name) { session.useImportedCopy() }
                    .disabled(!enabled || session.reading).accessibilityIdentifier("subtitles." + lane.rawValue + ".imported")
            }
            if !session.candidates.isEmpty {
                NavigationLink {
                    SubtitleCandidateList(session: session, excludedName: lane == .secondary ? playback.subtitles.activeName : nil)
                } label: { Text("选择同目录字幕") }
                .disabled(!enabled || session.reading).accessibilityIdentifier("subtitles." + lane.rawValue + ".candidates")
            }
            if !session.cues.isEmpty || session.hasBitmap || session.hasASS {
                Stepper("时间偏移：\(session.delay, specifier: "%.1f") 秒", value: Binding(get: { session.delay }, set: { session.setDelay($0) }), in: -30...30, step: 0.1)
                    .accessibilityIdentifier("subtitles." + lane.rawValue + ".delay")
                Button("偏移归零") { session.setDelay(0) }.disabled(session.delay == 0)
                    .accessibilityIdentifier("subtitles." + lane.rawValue + ".resetDelay")
                if lane == .secondary { Button("关闭第二字幕") { session.selectEmbedded(nil, engine: playback.engineDescriptor.id) }.accessibilityIdentifier("subtitles.secondary.off") }
            }
            if let message = session.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

private struct ServerSubtitleChoices: View {
    var playback: PlaybackController
    var body: some View {
        List {
            Button("关闭字幕") { playback.closeExternalSubtitles() }.accessibilityIdentifier("subtitles.server.off")
            Section("可用字幕 · \(playback.serverSubtitleOptions.count)") {
                ForEach(playback.serverSubtitleOptions) { stream in
                    Button { playback.chooseServerSubtitle(stream) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(TrackDisplay.summary(stream) + " · #\(stream.Index)").font(.subheadline.weight(.medium)).foregroundStyle(GlideTheme.text)
                                if let title = stream.DisplayTitle { Text(title).font(.caption).foregroundStyle(.secondary) }
                                if !CatalogSubtitlePolicy.textCodecs.contains(stream.Codec?.lowercased() ?? "") {
                                    Text(playback.supportsClientPGS && CatalogSubtitlePolicy.pgsCodecs.contains(stream.Codec?.lowercased() ?? "") ? "PGS 图形字幕 · 客户端显示" : "图形字幕，由服务器处理").font(.caption2).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if playback.serverSubtitlePendingIndex == stream.Index { ProgressView() }
                            else if playback.selectedServerSubtitleIndex == stream.Index { Image(systemName: "checkmark").foregroundStyle(GlideTheme.accent) }
                        }.frame(minHeight: 44).padding(.vertical, 4).contentShape(Rectangle())
                    }.disabled(playback.pictureInPicture.active)
                        .accessibilityIdentifier("subtitles.server.\(stream.Index)")
                        .accessibilityValue(playback.selectedServerSubtitleIndex == stream.Index ? "已选择" : "")
                }
            }
            if let message = playback.subtitles.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }.scrollContentBackground(.hidden).background(GlideTheme.background)
            .navigationTitle("服务器字幕").navigationBarTitleDisplayMode(.inline)
    }
}

private struct SubtitleCandidateList: View {
    var session: SubtitleSession
    var excludedName: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(session.candidates) { candidate in
            Button {
                session.choose(candidate); dismiss()
            } label: {
                HStack {
                    Text(candidate.name).lineLimit(3)
                    Spacer()
                    if session.activeName == candidate.name { Image(systemName: "checkmark").foregroundStyle(GlideTheme.accent) }
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.disabled(candidate.name == excludedName)
                .accessibilityIdentifier("subtitles." + session.lane.rawValue + ".sidecar." + candidate.name)
        }.font(GlideTheme.Typography.body).scrollContentBackground(.hidden).background(GlideTheme.background)
            .navigationTitle(session.lane.title).navigationBarTitleDisplayMode(.inline)
    }
}
