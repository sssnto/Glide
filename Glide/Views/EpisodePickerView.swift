import SwiftUI

struct EpisodePickerView: View {
    var videos: [Video]
    var currentID: String
    var loading: Bool
    var failed: Bool
    var onRetry: () -> Void
    var onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSeason: String?

    private var current: Video? { videos.first { $0.id == currentID } }
    private var seasons: [Int?] {
        Array(Set(videos.map(\.seasonNumber))).sorted { ($0 ?? Int.max) < ($1 ?? Int.max) }
    }
    private var activeSeason: Int? {
        if let key = selectedSeason, let season = seasons.first(where: { seasonKey($0) == key }) { return season }
        if seasons.contains(current?.seasonNumber) { return current?.seasonNumber }
        return seasons.first ?? nil
    }
    private var visibleEpisodes: [Video] { videos.filter { $0.seasonNumber == activeSeason } }
    private func seasonKey(_ number: Int?) -> String { number.map(String.init) ?? "unknown" }
    private func seasonTitle(_ number: Int?) -> String {
        number.map { $0 == 0 ? "特别篇" : "第 \($0) 季" } ?? "其他剧集"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    if let title = current?.seriesTitle, !title.isEmpty {
                        Text(title).font(.headline).lineLimit(2)
                    }
                    HStack {
                        Picker("选择季", selection: Binding(get: { seasonKey(activeSeason) }, set: { selectedSeason = $0 })) {
                            ForEach(seasons, id: \.self) { season in
                                Text(seasonTitle(season)).tag(seasonKey(season))
                            }
                        }.pickerStyle(.menu).accessibilityIdentifier("player.episodeSeason")
                        Spacer()
                        Text("共 \(videos.count) 集").font(.caption).foregroundStyle(GlideTheme.muted)
                    }
                    if loading { ProgressView("正在加载剧集…").font(.caption) }
                    if failed {
                        HStack {
                            Text("剧集列表未能完整加载").font(.caption).foregroundStyle(GlideTheme.muted)
                            Spacer()
                            Button("重试") { onRetry() }
                        }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
                ScrollViewReader { scroll in
                    List(visibleEpisodes) { episode in
                        Button {
                            onSelect(episode.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VideoArtwork(video: episode).frame(width: 84, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 5) {
                                    if let number = episode.episodeNumber {
                                        Text("第 \(number) 集").font(.caption).foregroundStyle(GlideTheme.accent)
                                    }
                                    Text(episode.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                    if episode.duration > 0 {
                                        Text(episode.duration.mediaTime).font(.caption2).foregroundStyle(GlideTheme.muted)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if episode.id == currentID {
                                    Image(systemName: "play.circle.fill").foregroundStyle(GlideTheme.accent)
                                        .accessibilityLabel("正在播放")
                                }
                            }.padding(.vertical, 4).foregroundStyle(GlideTheme.text)
                        }.buttonStyle(.plain)
                            .listRowBackground(episode.id == currentID ? GlideTheme.accent.opacity(0.08) : GlideTheme.panel)
                            .accessibilityIdentifier("player.episode." + (episode.remoteID ?? episode.id))
                    }.scrollContentBackground(.hidden)
                        .task(id: activeSeason) { scroll.scrollTo(currentID, anchor: .center) }
                }
            }.background(GlideTheme.background)
                .navigationTitle("选集").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("player.episodes.done")
                } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
    }
}
