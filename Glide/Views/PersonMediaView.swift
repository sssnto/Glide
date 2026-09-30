import SwiftUI

struct CastSection: View {
    var library: LibraryStore
    var server: MediaServer
    var people: [CatalogItem.Person]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("演职人员").font(.title3.bold()); Spacer(); Text("\(people.count) 位").font(.caption).foregroundStyle(GlideTheme.muted) }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                        if let id = person.personID {
                            NavigationLink { PersonMediaView(library: library, server: server, person: person) } label: {
                                personCard(person)
                            }.buttonStyle(.plain).accessibilityIdentifier("person." + id)
                                .accessibilityLabel(person.Name + "，" + person.credit + "，查看相关媒体")
                        } else { personCard(person).accessibilityHint("服务器未提供人员标识") }
                    }
                }
            }
        }
    }
    private func personCard(_ person: CatalogItem.Person) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PersonPortrait(person: person, server: server).frame(width: 100, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 14)).contentShape(Rectangle())
            Text(person.Name).font(.subheadline.weight(.medium)).lineLimit(2)
            Text(person.credit).font(.caption).foregroundStyle(GlideTheme.muted).lineLimit(2)
        }.frame(width: 100, alignment: .leading).contentShape(Rectangle())
    }
}

struct PersonPortrait: View {
    var person: CatalogItem.Person
    var server: MediaServer
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            GlideTheme.panel
            if let image {
                GeometryReader { proxy in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                }.allowsHitTesting(false).accessibilityIdentifier("portrait.loaded." + (person.personID ?? ""))
            } else { Image(systemName: "person.crop.rectangle").font(.largeTitle).foregroundStyle(GlideTheme.muted) }
        }.clipped().task(id: server.id.uuidString + (person.personID ?? "") + (person.PrimaryImageTag ?? "")) {
            image = nil
            guard let id = person.personID else { return }
            var query = ["maxWidth": "320", "quality": "85"]
            if let tag = person.PrimaryImageTag { query["tag"] = tag }
            let url = ServerURL.endpoint(server.address, "Items/\(id)/Images/Primary", query: query)
            if let loaded = try? await ArtworkCache.shared.image(server: server, url: url, pixels: 400), !Task.isCancelled { image = loaded }
        }
    }
}

struct PersonMediaView: View {
    var library: LibraryStore
    var server: MediaServer
    var person: CatalogItem.Person
    @State private var items: [CatalogItem] = []
    @State private var total = 0
    @State private var nextIndex = 0
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    @State private var generation = UUID()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 20) {
                    PersonPortrait(person: person, server: server).frame(width: 110, height: 146)
                        .clipShape(RoundedRectangle(cornerRadius: 18)).contentShape(Rectangle())
                    VStack(alignment: .leading, spacing: 10) {
                        Text(person.Name).font(.title.bold())
                        Text("相关媒体").font(.headline).foregroundStyle(GlideTheme.accent)
                        Text("\(server.name) · 当前账号可访问的媒体").font(.caption).foregroundStyle(GlideTheme.muted)
                    }
                }
                if loaded { Text("共 \(total) 部 · 已加载 \(items.count) 部").font(.subheadline).foregroundStyle(GlideTheme.muted) }
                if loaded && items.isEmpty && error == nil {
                    ContentUnavailableView("暂无相关媒体", systemImage: "film", description: Text("当前服务器还没有关联该人员的可用媒体。"))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], spacing: 24) {
                    ForEach(items) { item in
                        NavigationLink { CatalogDetailView(library: library, server: server, initial: item) } label: {
                            CatalogPosterCard(item: item, server: server)
                        }.buttonStyle(.plain).accessibilityIdentifier("person.media." + item.id)
                    }
                }
                if loading { ProgressView("正在读取相关媒体…").frame(maxWidth: .infinity) }
                if let error {
                    Text(error).foregroundStyle(.orange)
                    Button("重试加载") { Task { await load(reset: !loaded) } }.accessibilityIdentifier("person.retry")
                } else if loaded && nextIndex < total && !loading {
                    Button("加载更多") { Task { await load(reset: false) } }.frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("person.more")
                }
            }.padding(24).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.background(GlideTheme.background).navigationTitle(person.Name).navigationBarTitleDisplayMode(.inline)
            .task(id: server.id.uuidString + (person.personID ?? "")) { if !loaded { await load(reset: true) } }
            .refreshable { await load(reset: true, forceRefresh: true) }
    }
    private func kind(_ item: CatalogItem) -> String {
        switch item.Type { case "Movie": return "电影"; case "Series": return "节目"; case "Episode": return item.episodeLabel; default: return "视频" }
    }
    private func load(reset: Bool, forceRefresh: Bool = false) async {
        guard reset || !loading else { return }
        let requestID = UUID(); generation = requestID
        loading = true; error = nil
        if reset { items = []; total = 0; nextIndex = 0; loaded = false }
        defer { if generation == requestID { loading = false } }
        do {
            guard let id = person.personID else { throw MediaError.message("服务器未提供人员标识。") }
            let page = try await MediaClient.shared.personMedia(server: server, personID: id, start: nextIndex, refresh: forceRefresh)
            try Task.checkCancellation()
            guard generation == requestID else { return }
            let next = nextIndex + page.Items.count
            var known = Set(items.map(\.id))
            let added = page.Items.filter { known.insert($0.id).inserted }
            guard next >= page.TotalRecordCount || !added.isEmpty else { throw MediaError.message("相关媒体分页没有进展，请重试。") }
            items += added; total = page.TotalRecordCount; nextIndex = next; loaded = true
        } catch { if generation == requestID && !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
