import Foundation
import Testing
@testable import GlideCore

struct WebDAVMediaPresentationTests {
    private let root=URL(string:"https://dav.invalid/videos/")!
    @Test func rotationIsOnlyOfferedForTheCurrentWritableFileProtocol() {
        let server=MediaServer(name:"NAS",kind:.webDAV,address:root,username:"viewer")
        let file=root.appendingPathComponent("nested/My Video.mp4")
        var video=Video(id:"test",title:"title",subtitle:"",sourceID:server.id,url:file)
        #expect(WebDAVRotationTarget(video:video,server:server,playingURL:file)?.file==file)
        #expect(WebDAVRotationTarget(video:video,server:server,playingURL:URL(fileURLWithPath:"/tmp/offline.mp4"))==nil)
        for kind in [SourceKind.jellyfin,.emby,.smb,.local] {
            var other=server;other.kind=kind
            #expect(WebDAVRotationTarget(video:video,server:other,playingURL:file)==nil)
        }
        video.offlineOnly=true;#expect(WebDAVRotationTarget(video:video,server:server,playingURL:file)==nil)
        video.offlineOnly=nil;video.url=root.appendingPathComponent("movie.mkv")
        #expect(WebDAVRotationTarget(video:video,server:server,playingURL:video.url)==nil)
        video.url=URL(string:"https://dav.invalid/other/movie.mp4")!
        #expect(WebDAVRotationTarget(video:video,server:server,playingURL:video.url)==nil)
    }
    @Test func folderOnlyChainInheritsVideoAndPrefersExplicitCover() async throws {
        let child=root.appendingPathComponent("Child",isDirectory:true),deep=root.appendingPathComponent("Child/Deep",isDirectory:true)
        let video=DAVEntry(url:deep.appendingPathComponent("movie.mp4"),name:"movie.mp4",isDirectory:false)
        let entries=[root:[DAVEntry(url:child,name:"Child",isDirectory:true)],child:[DAVEntry(url:deep,name:"Deep",isDirectory:true)],deep:[video]]
        let result=try await DirectoryCoverCandidates.find(root:root) { entries[$0] ?? [] }
        #expect(result==[video])
        let cover=DAVEntry(url:deep.appendingPathComponent("cover.jpg"),name:"cover.jpg",isDirectory:false)
        let preferred=try await DirectoryCoverCandidates.find(root:deep) { _ in [video,cover] }
        #expect(preferred.first==cover)
    }
    @Test func cyclesBoundsAndForeignFilesDoNotCauseUnboundedRequests() async throws {
        var requests=0
        let result=try await DirectoryCoverCandidates.find(root:root,maximumDirectories:4) { folder in
            requests+=1
            return [DAVEntry(url:folder.appendingPathComponent("next",isDirectory:true),name:"next",isDirectory:true),DAVEntry(url:root,name:"cycle",isDirectory:true),DAVEntry(url:URL(string:"https://other.invalid/movie.mp4")!,name:"foreign",isDirectory:false)]
        }
        #expect(result.isEmpty && requests==4)
    }
}
