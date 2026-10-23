import SwiftUI

struct PlaybackSkipSettings: View {
    let session: PlaybackSkipSession
    let duration: Double
    let position: Double
    @Environment(\.dismiss) private var dismiss
    @State private var rule = PlaybackSkipRule()
    @State private var intro = "0"
    @State private var outro = "0"
    @State private var series = false
    @State private var error: String?
    var body: some View {
            Form {
                Section {
                    Toggle("显示跳过提示", isOn: $rule.enabled).accessibilityIdentifier("skip.enabled")
                    Toggle("自动跳过", isOn: $rule.automatic).disabled(!rule.enabled).accessibilityIdentifier("skip.automatic")
                    Text("默认点按钮跳过。自动跳过只在播放中执行，每段本次仅执行一次；暂停和回拖不反复跳过。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if session.canUseSeries {
                    Section("规则范围") {
                        Picker("应用到", selection: $series) { Text("当前视频").tag(false); Text("本节目全部剧集").tag(true) }
                            .accessibilityIdentifier("skip.scope")
                        if series { Text("保存将更新本节目的共用规则，并清除当前视频的单独覆盖。").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                Section("手动时间（秒）") {
                    LabeledContent("片头") { TextField("秒", text: $intro).multilineTextAlignment(.trailing).keyboardType(.decimalPad).accessibilityIdentifier("skip.intro") }
                    LabeledContent("片尾") { TextField("秒", text: $outro).multilineTextAlignment(.trailing).keyboardType(.decimalPad).accessibilityIdentifier("skip.outro") }
                    if position > 0 && position < duration {
                        Button("以当前位置设为片头结束") { intro = String(format: "%.1f", position) }
                        Button("以当前位置设为片尾起点") { outro = String(format: "%.1f", max(0, duration - position)) }
                    }
                    Text("片头从开头计算，片尾从结尾倒数。填 0 不设手动区间；手动区间优先于同类服务器标记。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if session.supportsServerMarkers {
                Section("服务器片段") {
                    Toggle("使用 Jellyfin 片段标记", isOn: $rule.serverMarkers).accessibilityIdentifier("skip.server")
                    if session.loading { ProgressView("正在读取…") }
                    else { Text("当前读取到 \(session.serverSegments.count) 个片段").font(.footnote).foregroundStyle(.secondary) }
                    if let message = session.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                }
                if session.hasMemory {
                    Section { Button(session.usesSeries ? "清除本节目规则" : "清除当前视频规则", role: .destructive) {
                        do { try session.clear(); dismiss() } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("skip.clear") }
                }
            }
            .font(GlideTheme.Typography.body)
            .navigationTitle("片头片尾").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    rule.intro = Double(intro) ?? .nan; rule.outro = Double(outro) ?? .nan
                    do { try session.save(rule, series: series, duration: duration); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.accessibilityIdentifier("skip.save").disabled(!duration.isFinite || duration <= 0) }
            }
            .onAppear {
                rule = session.rule; series = session.usesSeries
                intro = String(format: "%.1f", rule.intro); outro = String(format: "%.1f", rule.outro)
            }
            .alert("无法保存规则", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了") { error = nil }
            } message: { Text(error ?? "").accessibilityIdentifier("skip.error") }
        .tint(GlideTheme.accent)
    }
}
