import SwiftUI

struct PlaybackLoopView: View {
    var playback: PlaybackController
    var body: some View {
        Form {
            Section("单句重播") {
                Button("重播当前主字幕句", systemImage: "arrow.counterclockwise") { _ = playback.replaySubtitle() }
                    .disabled(playback.subtitles.cues.isEmpty || playback.isSeeking).accessibilityIdentifier("loop.replaySentence")
                Text("从当前句开头播放，到句尾自动暂停，沿用当前倍速。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("A–B 循环") {
                LoopClock(playback: playback)
                LabeledContent("起点 A", value: playback.loopStart?.mediaTime ?? "未设置").monospacedDigit()
                LabeledContent("终点 B", value: playback.loop?.end.mediaTime ?? "未设置").monospacedDigit()
                Button("当前位置设为 A") { playback.markLoopStart() }.disabled(!playback.frameReady || playback.isSeeking).accessibilityIdentifier("loop.markA")
                Button("当前位置设为 B 并开始循环") { playback.markLoopEnd() }.disabled(playback.loopStart == nil || playback.isSeeking).accessibilityIdentifier("loop.markB")
                HStack {
                    Button("快退 5 秒") { playback.seek(playback.time - 5) }
                    Spacer()
                    Button(playback.isPlaybackRequested ? "暂停" : "播放") { playback.toggle() }
                    Spacer()
                    Button("快进 5 秒") { playback.seek(playback.time + 5) }
                }.buttonStyle(.borderless).frame(minHeight: 44)
                if let loop = playback.loop {
                    Label(loop.mode == .once ? "正在单句重播" : "循环中 · 已回环 \(playback.loopCount) 次", systemImage: "repeat")
                        .foregroundStyle(GlideTheme.accent).accessibilityIdentifier("loop.status")
                }
                if playback.loop == nil, playback.loopStart != nil { Button("清除起点 A") { playback.clearLoop() }.accessibilityIdentifier("loop.clearA") }
            }
            if let message = playback.loopMessage { Section { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("loop.message") } }
            Section { Text("区间至少 0.5 秒。循环期间暂挂片头片尾跳过和自动下一条；手动定位到区间外或切换视频时退出。循环区间仅用于本次播放。").font(.footnote).foregroundStyle(.secondary) }
        }.font(GlideTheme.Typography.body).scrollContentBackground(.hidden).background(GlideTheme.background)
            .navigationTitle("片段循环").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if playback.loop != nil {
                    Button("退出循环与单句重播") { playback.clearLoop() }
                        .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.bordered)
                        .padding(.horizontal).padding(.vertical, 8).background(GlideTheme.background)
                        .accessibilityIdentifier("loop.clear")
                }
            }
    }
}

private struct LoopClock: View {
    var playback: PlaybackController
    var body: some View { LabeledContent("当前位置", value: playback.time.mediaTime).monospacedDigit().accessibilityIdentifier("loop.time") }
}
