import SwiftUI

/// One debounced request at a time, limited to local assets so scrubbing never starts remote reads.
struct TimelinePreview: View {
    let identity: String
    let time: Double
    let provider: @MainActor (Double) async -> UIImage?
    @State private var image: UIImage?
    @State private var unavailable = false
    private var requestKey: String { identity + ":" + String(Int(max(0, time) / 2)) }
    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { Rectangle().fill(.white.opacity(0.08)).overlay {
                    if unavailable { Image(systemName: "film").foregroundStyle(.secondary) }
                    else { ProgressView().tint(.white) }
                } }
            }.frame(width: 168, height: 94).clipped()
            Text(time.mediaTime).font(.system(.caption, design: .monospaced))
        }.padding(6).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine).accessibilityLabel("定位预览 " + time.mediaTime)
            .accessibilityIdentifier("player.timelinePreview")
            .task(id: requestKey) {
                image = nil; unavailable = false
                do {
                    try await Task.sleep(for: .milliseconds(180))
                    let result = await provider(time)
                    try Task.checkCancellation()
                    image = result; unavailable = result == nil
                } catch { if !Task.isCancelled { unavailable = true } }
            }
    }
}
