import Foundation
import Testing
@testable import GlideCore

struct WebDAVPlaybackPolicyTests {
    @Test func sourceScopeAndRouting() {
        let root = URL(string: "https://nas.example/media/")!
        #expect(WebDAVPlaybackPolicy.accepts(file: root.appendingPathComponent("a.mp4"), root: root))
        for value in ["https://other.example/media/a.mp4", "https://nas.example/medias/a.mp4", "https://user:secret@nas.example/media/a.mp4", "https://nas.example/media/a.mp4?token=secret", "file:///media/a.mp4"] {
            #expect(!WebDAVPlaybackPolicy.accepts(file: URL(string: value)!, root: root))
        }
        #expect(WebDAVPlaybackPolicy.prefersCompatibility(root.appendingPathComponent("A.MKV")))
        #expect(!WebDAVPlaybackPolicy.prefersCompatibility(root.appendingPathComponent("a.mp4")))
        #expect(PlaybackEngineSelection.resolve(preferred: .vlc, localFile: false, hasHeaders: true, webDAV: true) == .vlc)
        #expect(PlaybackEngineSelection.resolve(preferred: .vlc, localFile: false, hasHeaders: true) == .avPlayer)
        #expect(WebDAVPlaybackPolicy.canRecover(webDAV: true, engine: .avPlayer, attempted: false, external: false))
        #expect(!WebDAVPlaybackPolicy.canRecover(webDAV: true, engine: .avPlayer, attempted: true, external: false))
        #expect(!WebDAVPlaybackPolicy.canRecover(webDAV: true, engine: .vlc, attempted: false, external: false))
        #expect(!WebDAVPlaybackPolicy.canRecover(webDAV: true, engine: .avPlayer, attempted: false, external: true))
    }
    @Test func boundedRequestsCannotChangeUpstreamOrSmuggleBodies() {
        func parse(_ text: String) -> WebDAVBridgeHTTP.Request? { WebDAVBridgeHTTP.request(Data(text.utf8), path: "/opaque/media") }
        #expect(parse("GET /opaque/media HTTP/1.1\r\nRange: bytes=42-99\r\n\r\n") == .init(head: false, range: "bytes=42-99"))
        #expect(parse("HEAD /opaque/media HTTP/1.0\r\n\r\n") == .init(head: true, range: nil))
        for text in ["GET http://evil.example/ HTTP/1.1\r\n\r\n", "GET /wrong HTTP/1.1\r\n\r\n", "POST /opaque/media HTTP/1.1\r\n\r\n", "GET /opaque/media HTTP/1.1\r\nRange: bytes=0-1\r\nRange: bytes=2-3\r\n\r\n", "GET /opaque/media HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", "GET /opaque/media HTTP/1.1\r\nContent-Length: 1\r\n\r\nx", String(repeating: "x", count: 8193)] { #expect(parse(text) == nil) }
    }
    @Test func rangesAreValidatedAgainstActualResponse() {
        for range in ["bytes=0-", "bytes=40-90", "bytes=-20"] { #expect(WebDAVBridgeHTTP.validRange(range)) }
        for range in ["bytes=-0", "bytes=2-1", "bytes=1-2,4-5", "bytes=+2-", "bytes=99999999999999999999999-", "bytes=1--2"] { #expect(!WebDAVBridgeHTTP.validRange(range)) }
        #expect(WebDAVBridgeHTTP.validResponse(status: 206, range: "bytes=50-", contentRange: "bytes 50-99/100", length: 50))
        #expect(WebDAVBridgeHTTP.validResponse(status: 206, range: "bytes=-20", contentRange: "bytes 80-99/100", length: 20))
        #expect(WebDAVBridgeHTTP.validResponse(status: 206, range: "bytes=90-200", contentRange: "bytes 90-99/100", length: 10))
        #expect(!WebDAVBridgeHTTP.validResponse(status: 206, range: "bytes=50-", contentRange: "bytes 0-49/100", length: 50))
        #expect(!WebDAVBridgeHTTP.validResponse(status: 206, range: "bytes=50-", contentRange: "bytes 50-99/100", length: 99))
        #expect(!WebDAVBridgeHTTP.validResponse(status: 200, range: "bytes=50-", contentRange: nil, length: 100))
    }
}
