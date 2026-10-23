import SwiftUI

struct SubtitleTranscriptView: View {
    var playback: PlaybackController
    @State private var transcript = SubtitleTranscript(cues: [])
    @State private var results: [SubtitleTranscript.Entry] = []
    @State private var query = ""
    @State private var following = true
    var body: some View {
        VStack(spacing: 0) {
            Toggle("跟随当前句", isOn: $following).font(.footnote).padding(.horizontal).padding(.vertical, 8)
                .accessibilityIdentifier("subtitles.transcript.follow")
            if playback.subtitles.cues.isEmpty {
                ContentUnavailableView("没有可读取的主字幕", systemImage: "captions.bubble", description: Text("先选择或导入主字幕 SRT／VTT，再查看全文。"))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                TranscriptRows(playback: playback, transcript: transcript, results: results, following: $following)
            }
        }
        .searchable(text: $query, prompt: "搜索主字幕台词")
        .task(id: playback.subtitles.cues) {
            transcript = SubtitleTranscript(cues: playback.subtitles.cues); results = transcript.search(query)
        }
        .task(id: query) {
            do { try await Task.sleep(for: .milliseconds(200)); try Task.checkCancellation(); results = transcript.search(query) } catch { }
        }
        .navigationTitle("字幕全文").navigationBarTitleDisplayMode(.inline).background(GlideTheme.background)
    }
}

private struct TranscriptRows: View {
    var playback: PlaybackController
    var transcript: SubtitleTranscript
    var results: [SubtitleTranscript.Entry]
    @Binding var following: Bool
    var body: some View {
        let active = transcript.active(at: playback.time, delay: playback.subtitles.delay)?.id
        ScrollViewReader { proxy in
            List(results) { entry in
                TranscriptRow(entry: entry, active: entry.id == active, playback: playback)
                    .id(entry.id)
            }.accessibilityIdentifier("subtitles.transcript.list")
                .scrollContentBackground(.hidden)
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in if following { following = false } })
                .onChange(of: active, initial: true) { _, id in if following, let id, results.contains(where: { $0.id == id }) { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: following) { _, value in if value, let active { proxy.scrollTo(active, anchor: .center) } }
        }
    }
}

private struct TranscriptRow: View {
    var entry: SubtitleTranscript.Entry
    var active: Bool
    var playback: PlaybackController
    private var target: Double { max(0, entry.cue.start + playback.subtitles.delay) }
    private var available: Bool { entry.cue.end + playback.subtitles.delay > 0 && target < playback.duration }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { playback.seekToSubtitle(entry.cue) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(target.mediaTime).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(entry.cue.text).font(GlideTheme.Typography.body).foregroundStyle(active ? GlideTheme.accent : GlideTheme.text)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!available)
                .accessibilityIdentifier("subtitles.transcript.cue." + String(entry.cue.start))
                .accessibilityValue(active ? "当前句" : "")
            Button { _ = playback.replaySubtitle(entry.cue) } label: { Image(systemName: "arrow.counterclockwise").frame(width: 44, height: 44) }
                .buttonStyle(.borderless).disabled(!available || playback.isSeeking)
                .accessibilityLabel("重播此句").accessibilityIdentifier("subtitles.transcript.replay." + String(entry.cue.start))
        }.listRowBackground(active ? GlideTheme.accent.opacity(0.08) : Color.clear)
    }
}
