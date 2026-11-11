#if DEBUG
import SwiftUI

struct WebDAVPresentationQAView: View {
    var library: LibraryStore
    @State private var ready=false
    @State private var playing: Video?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            if ready,let server=library.selectedServer {
                ScrollView {
                    VStack(spacing:16) {
                        Button("播放当前 WebDAV 视频") {
                            playing=Video(id:"dav-qa-current",title:"原创方向片段",subtitle:"",sourceID:server.id,url:server.address.appendingPathComponent("original.mp4"))
                        }.frame(minHeight:44).accessibilityIdentifier("dav.qa.play")
                        HStack {
                            LibraryFolderTile(title:"直属视频目录",server:server,directory:DAVEntry(url:server.address.appendingPathComponent("Direct",isDirectory:true),name:"Direct",isDirectory:true),action:{})
                                .accessibilityIdentifier("dav.qa.direct")
                            LibraryFolderTile(title:"仅子目录",server:server,directory:DAVEntry(url:server.address.appendingPathComponent("Nested",isDirectory:true),name:"Nested",isDirectory:true),action:{})
                                .accessibilityIdentifier("dav.qa.nested")
                        }
                    }.padding()
                }.navigationTitle("WebDAV 播放与封面")
            } else if let error { Text(error) } else { ProgressView() }
        }.fullScreenCover(item:$playing) { video in
            PlayerView(library:library,queue:PlaybackQueue(videos:[video],mode:.sequential),scopeName:"原创验证",initialResumeAt:3)
        }.task {
            guard !ready else { return }
            do {
                let root=URL(string:"http://127.0.0.1:8828/lock-presentation-"+UUID().uuidString+"/")!
                let server=MediaServer(name:"原创 WebDAV",kind:.webDAV,address:root,username:"glide")
                try Credentials.save("rotation-fixture",for:server.id)
                library.servers=[server];await library.select(server.id);ready=true
            } catch { self.error=error.localizedDescription }
        }
    }
}
#endif
