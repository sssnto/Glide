import SwiftUI

enum GlideAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" } }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
}

enum GlideTheme {
    // System semantic colors follow appearance and increased-contrast settings.
    static let text = Color.primary
    static let background = Color(uiColor: .systemGroupedBackground)
    static let panel = Color(uiColor: .secondarySystemGroupedBackground)
    static let surface = panel
    static let raised = Color(uiColor: .tertiarySystemGroupedBackground)
    static let subtle = Color(uiColor: .tertiaryLabel)
    static let muted = Color.secondary
    static let separator = Color(uiColor: .separator)
    static let outline = Color(uiColor: .separator).opacity(0.45)
    static let accent = Color.blue
    static let onAccent = Color.white
    static let playbackControl = Color.white

    enum Typography {
        static let pageTitle: Font = .system(.title2, design: .default, weight: .bold)
        static let sectionTitle: Font = .system(.headline, design: .default, weight: .semibold)
        static let itemTitle: Font = .system(.subheadline, design: .default, weight: .semibold)
        static let body: Font = .system(.subheadline)
        static let secondary: Font = .system(.footnote)
        static let caption: Font = .system(.caption)
        static let eyebrow: Font = .system(.caption2, design: .default, weight: .semibold)
        static let technical: Font = .system(.caption, design: .monospaced)
    }

    enum Layout {
        static let pagePadding: CGFloat = 20
        static let sectionSpacing: CGFloat = 24
        static let itemSpacing: CGFloat = 12
        static let cardRadius: CGFloat = 12
        static let smallRadius: CGFloat = 8
        static let touchTarget: CGFloat = 44
    }
}

enum MediaInfoFormatting {
    static func bitrate(_ bitsPerSecond: Double) -> String {
        guard bitsPerSecond.isFinite, bitsPerSecond >= 0 else { return "未知" }
        let unit = bitsPerSecond >= 1_000_000 ? "Mb/s" : bitsPerSecond >= 1_000 ? "kb/s" : "b/s"
        let divisor = bitsPerSecond >= 1_000_000 ? 1_000_000.0 : bitsPerSecond >= 1_000 ? 1_000.0 : 1.0
        return (bitsPerSecond / divisor).formatted(.number.precision(.fractionLength(0...1))) + " " + unit
    }
}

struct MediaInfoChip: View {
    var title: String
    var symbol: String?
    var emphasized: Bool

    init(_ title: String, symbol: String? = nil, emphasized: Bool = false) {
        self.title = title; self.symbol = symbol; self.emphasized = emphasized
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(GlideTheme.Typography.caption)
        .foregroundStyle(emphasized ? GlideTheme.accent : GlideTheme.muted)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(emphasized ? GlideTheme.accent.opacity(0.10) : GlideTheme.raised, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .combine)
    }
}

struct LandscapeArt: View {
    var index = 0
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(Color(red: 1, green: 0.9, blue: 0.63).opacity(0.85))
                    .frame(width: size.width * 0.19, height: size.width * 0.19)
                    .blur(radius: index == 2 ? 1 : 0)
                    .position(x: size.width * 0.7, y: size.height * 0.27)
                ForEach(0..<4) { layer in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for step in 0...100 {
                            let x = CGFloat(step) / 100
                            let wave = sin(x * 6 + Double(layer) * 1.5) * 0.12 + sin(x * 13 + Double(layer)) * 0.035
                            path.addLine(to: CGPoint(x: x * size.width, y: size.height * (0.54 + Double(layer) * 0.11 + wave)))
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                    }
                    .fill(Color(red: 0.025 + Double(index) * 0.022, green: 0.13 + Double(index) * 0.009, blue: 0.15 + Double(index) * 0.035).opacity(0.38 + Double(layer) * 0.18))
                }
            }
        }.clipped()
    }
    private var colors: [Color] {
        switch index {
        case 1: return [Color(red: 0.54, green: 0.29, blue: 0.3), Color(red: 0.94, green: 0.65, blue: 0.42), Color(red: 0.25, green: 0.38, blue: 0.4)]
        case 2: return [Color(red: 0.08, green: 0.15, blue: 0.34), Color(red: 0.29, green: 0.45, blue: 0.56), Color(red: 0.56, green: 0.62, blue: 0.67)]
        default: return [Color(red: 0.1, green: 0.28, blue: 0.31), Color(red: 0.47, green: 0.68, blue: 0.63), Color(red: 0.8, green: 0.81, blue: 0.62)]
        }
    }
}

struct VideoArtwork: View {
    var video: Video
    var contentMode: ContentMode = .fill
    var server: MediaServer? = nil
    var body: some View {
        VideoImageCanvas(video: video, server: server, contentMode: contentMode)
    }
}

/// Family recordings use the same portrait canvas before and after image loading.
/// Fit preserves the entire recording without cropping either orientation.
struct VideoPreviewArtwork: View {
    var video: Video
    var server: MediaServer? = nil
    var body: some View {
        VideoImageCanvas(video: video, server: server, contentMode: .fit)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
    }
}

private struct ArtworkLoadKey: Hashable {
    var identity: String
    var pixels: Int
}

private enum ArtworkSize {
    static func pixels(_ size: CGSize, scale: CGFloat) -> Int {
        // Buckets avoid restarting image tasks for fractional layout changes.
        let dimension = max(size.width, size.height) * scale
        guard dimension.isFinite, dimension > 0 else { return 256 }
        return min(1600, max(256, Int(ceil(min(dimension, 1600) / 128)) * 128))
    }
}

private struct VideoImageCanvas: View {
    var video: Video
    var server: MediaServer?
    var contentMode: ContentMode
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadedIdentity = ""

    private var identity: String {
        [video.id, video.artwork?.absoluteString ?? "", video.localRelativePath ?? "",
         server?.id.uuidString ?? "", server?.address.absoluteString ?? "", server?.userID ?? ""].joined(separator: "|")
    }

    var body: some View {
        GeometryReader { geometry in
            let request = ArtworkLoadKey(identity: identity, pixels: ArtworkSize.pixels(geometry.size, scale: displayScale))
            ZStack {
                GlideTheme.panel
                if let index = video.demoIndex { LandscapeArt(index: index) }
                else if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(systemName: "film.stack")
                        .font(.system(size: 26, weight: .light)).foregroundStyle(GlideTheme.subtle)
                    if server == nil, let url = video.artwork {
                        AsyncImage(url: url) { phase in
                            if let loaded = phase.image {
                                loaded.resizable().aspectRatio(contentMode: contentMode)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                            }
                        }
                    }
                }
            }
            .clipped().allowsHitTesting(false)
            .task(id: request) { await load(request) }
        }
    }

    private func load(_ request: ArtworkLoadKey) async {
        guard !Task.isCancelled else { return }
        if loadedIdentity != request.identity { image = nil; loadedIdentity = request.identity }
        guard video.demoIndex == nil, let server else { return }
        let loaded: UIImage?
        if server.kind == .local { loaded = await LocalArtwork.image(video: video, server: server) }
        else if let url = video.artwork { loaded = try? await ArtworkCache.shared.image(server: server, url: url, pixels: request.pixels) }
        else { loaded = nil }
        guard !Task.isCancelled, loadedIdentity == request.identity else { return }
        image = loaded
    }
}

struct RoundControl: View {
    var symbol: String
    var label: String
    var prominent = false
    var compact = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: prominent && !compact ? 22 : 18, weight: .medium))
                .frame(width: prominent && !compact ? 60 : GlideTheme.Layout.touchTarget,
                       height: prominent && !compact ? 60 : GlideTheme.Layout.touchTarget)
                .foregroundStyle(prominent ? Color.black : GlideTheme.text)
                .background(prominent ? GlideTheme.playbackControl : GlideTheme.raised, in: Circle())
                .contentShape(Circle())
        }.accessibilityLabel(label).buttonStyle(.plain)
    }
}

struct LibraryFolderTile: View {
    @ScaledMetric(relativeTo: .subheadline) private var titleHeight = 36
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var title: String
    var server: MediaServer
    var folder: MediaFolder? = nil
    var directory: DAVEntry? = nil
    var isLibrary = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment: .center, spacing: 14) {
                        artwork.frame(width: 72, height: 108)
                        metadata
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(GlideTheme.muted)
                    }.frame(minHeight: 80)
                } else {
                    VStack(alignment: .leading, spacing: 8) { artwork; metadata }
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel((isLibrary ? "媒体库，" : "目录，") + title)
    }
    private var artwork: some View {
        FolderPreviewArtwork(server: server, folder: folder, directory: directory,
                             preservesImageAspectRatio: !isLibrary || LibraryExperience(collectionType: folder?.collectionType) == .home)
            .clipShape(RoundedRectangle(cornerRadius: GlideTheme.Layout.cardRadius))
    }
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(GlideTheme.Typography.itemTitle).foregroundStyle(GlideTheme.text)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2).multilineTextAlignment(.leading)
                .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? nil : titleHeight, alignment: .topLeading)
            Label(kindTitle, systemImage: isLibrary ? "square.stack.3d.up" : "folder")
                .font(GlideTheme.Typography.caption).foregroundStyle(GlideTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var kindTitle: String {
        guard isLibrary else { return "文件夹" }
        switch LibraryExperience(collectionType: folder?.collectionType) {
        case .movies: return "电影"
        case .shows: return "剧集"
        case .home: return "家庭视频"
        }
    }
}

private struct FolderPreviewArtwork: View {
    var server: MediaServer
    var folder: MediaFolder?
    var directory: DAVEntry?
    var preservesImageAspectRatio: Bool
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadedIdentity = ""
    private var identity: String {
        [server.id.uuidString, server.address.absoluteString, server.userID ?? "",
         folder?.id ?? directory?.id ?? "", folder?.primaryImageTag ?? "",
         directory?.modifiedAt.map { String($0.timeIntervalSince1970) } ?? ""].joined(separator: "|")
    }
    var body: some View {
        GeometryReader { geometry in
            let request = ArtworkLoadKey(identity: identity, pixels: ArtworkSize.pixels(geometry.size, scale: displayScale))
            ZStack {
                LinearGradient(colors: [GlideTheme.panel, GlideTheme.raised], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image {
                    Image(uiImage: image).resizable()
                        .aspectRatio(contentMode: preservesImageAspectRatio ? .fit : .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(systemName: "folder.fill").font(.system(size: 30, weight: .light))
                        .foregroundStyle(GlideTheme.subtle.opacity(0.55))
                }
            }
            .clipped().allowsHitTesting(false)
            .task(id: request) { await load(request) }
        }.aspectRatio(2.0 / 3.0, contentMode: .fit)
    }
    private func load(_ request: ArtworkLoadKey) async {
        guard !Task.isCancelled else { return }
        if loadedIdentity != request.identity { image = nil; loadedIdentity = request.identity }
        if let folder {
            if let tag = folder.primaryImageTag {
                let url = ServerURL.endpoint(server.address, "Items/\(folder.id)/Images/Primary", query: ["maxWidth": String(request.pixels), "tag": tag])
                if let loaded = try? await ArtworkCache.shared.image(server: server, url: url, pixels: request.pixels), !Task.isCancelled {
                    image = loaded; return
                }
            }
            guard !Task.isCancelled else { return }
            if let preview = try? await MediaClient.shared.folderPreview(server: server, folderID: folder.id), !Task.isCancelled {
                var query = ["maxWidth": String(request.pixels)]
                if let tag = preview.tag { query["tag"] = tag }
                let url = ServerURL.endpoint(server.address, "Items/\(preview.id)/Images/Primary", query: query)
                if let loaded = try? await ArtworkCache.shared.image(server: server, url: url, pixels: request.pixels), !Task.isCancelled { image = loaded }
            }
        } else if let directory {
            if server.kind == .local {
                if let entries = try? await SourceProviders.directories(for: .local).entries(server: server, directory: directory.url),
                   !Task.isCancelled,
                   let entry = entries.first(where: { !$0.isDirectory && DirectoryScope.isVideo($0.url) }),
                   let relative = try? LocalMediaIdentity.relativePath(root: server.address, file: entry.url) {
                    let video = Video(id: LocalMediaIdentity.id(sourceID: server.id, relativePath: relative), title: entry.name, subtitle: "", sourceID: server.id, url: entry.url, localRelativePath: relative)
                    let loaded = await LocalArtwork.image(video: video, server: server)
                    if !Task.isCancelled { image = loaded }
                }
                return
            }
            guard let provider = try? SourceProviders.directories(for: server.kind),
                  let entries = try? await provider.entries(server: server, directory: directory.url), !Task.isCancelled else { return }
            let pictures = entries.filter {
                !$0.isDirectory && DirectoryScope.contains(root: directory.url, child: $0.url)
                    && $0.url.query == nil && $0.url.fragment == nil
                    && ["jpg", "jpeg", "png", "webp", "heic"].contains($0.url.pathExtension.lowercased())
            }
            let preferred = ["folder", "cover", "poster", "thumb"]
            let cover = pictures.first { preferred.contains($0.url.deletingPathExtension().lastPathComponent.lowercased()) } ?? pictures.first
            if let cover, let loaded = try? await ArtworkCache.shared.image(server: server, url: cover.url, pixels: request.pixels, version: cover.modifiedAt.map { String($0.timeIntervalSince1970) } ?? ""), !Task.isCancelled {
                image = loaded
            }
        }
    }
}
