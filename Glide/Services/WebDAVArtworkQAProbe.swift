#if DEBUG
import SwiftUI

struct WebDAVArtworkQAProbe: View {
    let library: LibraryStore
    @State private var server: MediaServer?
    @State private var videos: [Video]=[]
    @State private var status="加载 WebDAV 视频预览"
    @State private var checks:[String]=[]
    @State private var passed=false
    private var live:Bool { ProcessInfo.processInfo.arguments.contains("--glide-webdav-artwork-investigate") }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:16) {
                    Text(status).accessibilityIdentifier("dav.artwork.status")
                    LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:16) {
                        ForEach(videos) { video in
                            VStack {
                                VideoPreviewArtwork(video:video,server:server)
                                    .clipShape(RoundedRectangle(cornerRadius:10))
                                Text(video.title).font(.caption)
                            }
                        }
                    }
                    Button("检查缩略图缓存与取消") { Task { await verify() } }.accessibilityIdentifier("dav.artwork.verify")
                }.padding()
            }.navigationTitle("WebDAV 视频缩略图")
        }.task { await prepare() }.onAppear { UIApplication.shared.isIdleTimerDisabled=true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled=false }
    }
    @MainActor private func prepare() async {
        do {
            if live {
                guard let value=UserDefaults.standard.string(forKey:"glideWebDAVPlaybackInvestigateURL"),let file=URL(string:value),
                      let source=library.servers.first(where:{ $0.kind == .webDAV && WebDAVPlaybackPolicy.accepts(file:file,root:$0.address) }) else { throw MediaError.message("没有匹配原片的已保存 WebDAV 连接") }
                server=source
                videos=[Video(id:"dav-art-original",title:"当前原片预览",subtitle:"",sourceID:source.id,url:file)]
                await verify()
            } else {
                let root=URL(string:UserDefaults.standard.string(forKey:"glideWebDAVPlaybackFixtureAddress") ?? "http://127.0.0.1:8827/")!
                let source=MediaServer(name:"原创 WebDAV",kind:.webDAV,address:root,username:"glide")
                try Credentials.save("playback-fixture",for:source.id);server=source
                videos=[("native.mp4","系统 MP4"),("high10.mp4","High 10 MP4"),("compat.mkv","兼容 MKV")].enumerated().map {
                    Video(id:"dav-art-\($0.offset)",title:$0.element.1,subtitle:"",sourceID:source.id,url:root.appendingPathComponent($0.element.0))
                }
            }
        } catch { status="验证失败";save(error) }
    }
    @MainActor private func check(_ condition:Bool,_ name:String) throws {
        guard condition else { throw MediaError.message(name) };checks.append(name)
    }
    @MainActor private func verify() async {
        guard let server else { return }
        do {
            status="检查缓存与取消"
            for video in videos {
                guard let file=video.url,let image=await WebDAVArtwork.image(server:server,file:file,modified:nil,pixels:640) else { throw MediaError.message("视频预览未生成") }
                try check(image.size.width>0 && image.size.height>0 && max(image.size.width,image.size.height)<=640,"取帧成功且最长边不超过 640")
            }
            let before=WebDAVArtwork.qaStats["generated",default:0]
            for video in videos {
                guard let file=video.url,await WebDAVArtwork.image(server:server,file:file,modified:nil,pixels:320) != nil else { throw MediaError.message("无法复用缩略图") }
            }
            try check(WebDAVArtwork.qaStats["generated",default:0]==before,"重进与不同显示尺寸复用已有图片，无额外解码")
            try check(WebDAVArtwork.qaStats["peakActive",default:0]<=2,"取帧并发最多两个")
            if !live {
                let cancelled=(0..<20).map { index in Task { @MainActor in
                    await WebDAVArtwork.image(server:server,file:server.address.appendingPathComponent("cancel-\(index).mp4"),modified:nil,pixels:320)
                } }
                cancelled.forEach { $0.cancel() };for task in cancelled { _=await task.value }
                try check(WebDAVArtwork.qaStats["generated",default:0]==before,"快速离屏任务不启动视频解码")
                try check(WebDAVArtwork.qaStats["compatibilityFrames",default:0]>=2,"High 10 与 MKV 均通过兼容内核取帧")
            }
            passed=true;status="验证通过";save()
        } catch { status="验证失败";save(error) }
    }
    @MainActor private func save(_ error:Error?=nil) {
        let report:[String:Any]=["version":PlaybackPreferences.appVersion,"passed":passed,"live":live,"stage":status,
            "checks":checks,"statistics":WebDAVArtwork.qaStats,"error":error?.localizedDescription ?? "",
            "os":UIDevice.current.systemVersion,"timestamp":ISO8601DateFormatter().string(from:Date())]
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        try? FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:root.appendingPathComponent("WebDAVVideoArtworkQA.json"),options:.atomic) }
    }
}
#endif
