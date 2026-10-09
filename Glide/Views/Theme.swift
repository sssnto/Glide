import SwiftUI

enum GlideTheme {
    static let text = Color(red: 0.941, green: 0.941, blue: 0.914)
    static let separator = Color(red: 0.173, green: 0.200, blue: 0.180)
    static let background = Color(red: 0.047, green: 0.063, blue: 0.059)
    static let panel = Color(red: 0.098, green: 0.122, blue: 0.110)
    static let accent = Color(red: 0.773, green: 0.871, blue: 0.773)
    static let muted = Color(red: 0.631, green: 0.667, blue: 0.643)
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
    @State private var cachedImage: UIImage?
    var body: some View {
        ZStack {
            if let index = video.demoIndex { LandscapeArt(index: index) }
            else {
                GlideTheme.panel
                Image(systemName: "film.stack").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(GlideTheme.muted)
                if let url = video.artwork {
                    GeometryReader { geometry in
                        if server != nil {
                            if let cachedImage { Image(uiImage: cachedImage).resizable().aspectRatio(contentMode: contentMode).frame(width: geometry.size.width, height: geometry.size.height) }
                        } else {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image { image.resizable().aspectRatio(contentMode: contentMode).frame(width: geometry.size.width, height: geometry.size.height) }
                            }
                        }
                    }.allowsHitTesting(false)
                }
            }
        }.clipped().task(id: video.id + (video.artwork?.absoluteString ?? "") + (server?.userID ?? "")) {
            guard let server, let url = video.artwork else { return }
            let image = try? await ArtworkCache.shared.image(server: server, url: url, pixels: 640)
            if !Task.isCancelled { cachedImage = image }
        }
    }
}

/// Family clips keep their own image proportions, including portrait recordings.
struct VideoPreviewArtwork: View {
    var video: Video
    var server: MediaServer? = nil
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let index = video.demoIndex { LandscapeArt(index: index).aspectRatio(16.0 / 9.0, contentMode: .fit) }
            else if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity) }
            else if server == nil {
                AsyncImage(url: video.artwork) { phase in
                    if let loaded = phase.image { loaded.resizable().scaledToFit().frame(maxWidth: .infinity) }
                    else { placeholder }
                }
            } else { placeholder }
        }.task(id: video.id + (server?.userID ?? "")) {
            guard let server, let url = video.artwork else { return }
            let loaded = try? await ArtworkCache.shared.image(server: server, url: url, pixels: 640)
            if !Task.isCancelled { image = loaded }
        }
    }
    private var placeholder: some View {
        GlideTheme.panel.overlay { Image(systemName: "film.stack").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(GlideTheme.muted) }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
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
            Image(systemName: symbol).font(.system(size: prominent && !compact ? 23 : 18, weight: .medium))
                .frame(width: prominent && !compact ? 64 : 44, height: prominent && !compact ? 64 : 44)
                .foregroundStyle(prominent ? Color.black : Color.white)
                .background(prominent ? GlideTheme.accent : Color.white.opacity(0.09), in: Circle())
        }.accessibilityLabel(label).buttonStyle(.plain)
    }
}

struct LibraryFolderTile: View {
    var title: String
    var server: MediaServer
    var folder: MediaFolder? = nil
    var directory: DAVEntry? = nil
    var isLibrary = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                FolderPreviewArtwork(server: server, folder: folder, directory: directory,
                                     preservesImageAspectRatio: !isLibrary || LibraryExperience(collectionType: folder?.collectionType) == .home)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: isLibrary ? "square.stack.3d.up" : "folder")
                        .font(.caption).foregroundStyle(GlideTheme.accent)
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(GlideTheme.text)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel((isLibrary ? "媒体库，" : "目录，") + title)
    }
}

private struct FolderPreviewArtwork: View {
    var server: MediaServer
    var folder: MediaFolder?
    var directory: DAVEntry?
    var preservesImageAspectRatio: Bool
    @State private var image: UIImage?
    private var identity: String { server.id.uuidString + (folder?.id ?? directory?.id ?? "") + (folder?.primaryImageTag ?? "") }
    var body: some View {
        Group {
            if preservesImageAspectRatio, let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                ZStack {
                    LinearGradient(colors: [GlideTheme.panel, Color(red: 0.12, green: 0.24, blue: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let image {
                        GeometryReader { proxy in
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                        }.allowsHitTesting(false)
                    } else {
                        Image(systemName: "folder.fill").font(.system(size: 42, weight: .ultraLight))
                            .foregroundStyle(GlideTheme.accent.opacity(0.34))
                    }
                }.aspectRatio(1.3, contentMode: .fit)
            }
        }.clipped().task(id: identity) { await load() }
    }
    private func load() async {
        image = nil
        if let folder {
            if let tag = folder.primaryImageTag {
                let url = ServerURL.endpoint(server.address, "Items/\(folder.id)/Images/Primary", query: ["maxWidth": "540", "tag": tag])
                if let loaded = try? await ArtworkCache.shared.image(server: server, url: url, pixels: 640), !Task.isCancelled {
                    image = loaded; return
                }
            }
            if let preview = try? await MediaClient.shared.folderPreview(server: server, folderID: folder.id), !Task.isCancelled {
                var query = ["maxWidth": "540"]
                if let tag = preview.tag { query["tag"] = tag }
                let url = ServerURL.endpoint(server.address, "Items/\(preview.id)/Images/Primary", query: query)
                if let loaded = try? await ArtworkCache.shared.image(server: server, url: url, pixels: 640), !Task.isCancelled { image = loaded }
            }
        } else if let directory {
            guard let entries = try? await MediaClient.shared.webDAV(server: server, directory: directory.url), !Task.isCancelled else { return }
            let pictures = entries.filter {
                !$0.isDirectory && DirectoryScope.contains(root: directory.url, child: $0.url)
                    && $0.url.query == nil && $0.url.fragment == nil
                    && ["jpg", "jpeg", "png", "webp", "heic"].contains($0.url.pathExtension.lowercased())
            }
            let preferred = ["folder", "cover", "poster", "thumb"]
            let cover = pictures.first { preferred.contains($0.url.deletingPathExtension().lastPathComponent.lowercased()) } ?? pictures.first
            if let cover, let loaded = try? await ArtworkCache.shared.image(server: server, url: cover.url, pixels: 640, version: cover.modifiedAt.map { String($0.timeIntervalSince1970) } ?? ""), !Task.isCancelled {
                image = loaded
            }
        }
    }
}
