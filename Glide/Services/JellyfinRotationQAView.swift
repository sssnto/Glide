#if DEBUG
import SwiftUI

/// Only an isolated localhost server with authored fixtures; never saves a
/// private account or user-selected item into this UI automation path.
struct JellyfinRotationQAView:View {
    let library:LibraryStore
    @State private var video:Video?
    @State private var playing:Video?
    @State private var error:String?
    private var batchMode: Bool { ProcessInfo.processInfo.arguments.contains("--glide-jellyfin-batch-fixture") }
    var body:some View {
        Group {
            if batchMode, video != nil { LibraryView(library: library) }
            else { standardContent }
        }.fullScreenCover(item:$playing) { video in
            PlayerView(library:library,queue:PlaybackQueue(videos:[video],mode:.sequential),scopeName:"原创服务器验证",initialResumeAt:3)
        }.task { await prepare() }
    }
    private var standardContent: some View {
        NavigationStack {
            VStack(spacing:20) {
                if let video {
                    Text("Jellyfin 12.2 原创视频").font(.headline)
                    Button("播放并修正方向") { playing=video }.accessibilityIdentifier("jellyfin.rotation.qa.play")
                } else if let error { Text(error).accessibilityIdentifier("jellyfin.rotation.qa.error") }
                else { ProgressView("准备服务器原创媒体") }
            }.frame(maxWidth:.infinity,maxHeight:.infinity).navigationTitle("服务器旋转验证").navigationBarTitleDisplayMode(.inline)
        }
    }
    @MainActor private func prepare() async {
        guard video == nil else { return }
        do {
            let reader=UserDefaults.standard.bool(forKey:"glideRotationQAReader")
            var server=MediaServer(name:"原创 Jellyfin 12.2",kind:.jellyfin,address:URL(string:"http://127.0.0.1:8830")!,username:reader ? "glide-rotation-reader" : "glide-rotation-admin")
            let (token,user)=try await MediaClient.shared.signIn(server:server,password:reader ? "" : "Authored-Glide-rotation-only-122")
            server.userID=user;try Credentials.save(token,for:server.id);library.servers=[server]
            struct Items:Decodable { let Items:[CatalogItem] }
            let data=try await MediaClient.shared.request(ServerURL.endpoint(server.address,"Items",query:["UserId":user,"Recursive":"true","IncludeItemTypes":"Movie,Video","Fields":"MediaSources"]),headers:["Authorization":MediaClient.shared.authorization(token,server:server)])
            guard let item=try JSONDecoder().decode(Items.self,from:data).Items.first(where:{$0.Name == "GlideRotation"}) else { throw MediaError.message("原创媒体未索引") }
            if batchMode {
                await library.select(server.id)
                guard var folder = library.folders.first(where: { $0.name == "Native Recovery" }) else { throw MediaError.message("原创批量媒体库未索引") }
                if ProcessInfo.processInfo.arguments.contains("--glide-jellyfin-batch-home-fixture") { folder.collectionType = "homevideos" }
                await library.enter(folder)
            }
            video=item.video(server:server)
        } catch { self.error=error.localizedDescription }
    }
}
#endif
