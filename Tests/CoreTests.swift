import Foundation
import Testing
@testable import GlideCore

@Test func rejectsCredentialsAndUnsupportedSchemes() throws {
    for value in ["smb://nas/share", "ftp://nas", "https://user:password@nas/", "https://nas/?api_key=secret", "nas:8096", ""] {
        #expect(throws: (any Error).self) { try ServerURL.parse(value) }
    }
    #expect(try ServerURL.parse(" https://nas.example/jellyfin ").path == "/jellyfin")
}
@Test func preservesReverseProxyPathAndEncodesQuery() throws {
    let url = ServerURL.endpoint(try ServerURL.parse("https://nas.example/jellyfin/"), "Items/abc/PlaybackInfo", query: ["user": "a&b", "Name": "中文"])
    #expect(url.path == "/jellyfin/Items/abc/PlaybackInfo")
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "user" })?.value == "a&b")
    #expect(ServerURL.sameOrigin(URL(string: "https://nas:443/a")!, URL(string: "https://nas/b")!))
    #expect(!ServerURL.sameOrigin(URL(string: "https://nas/a")!, URL(string: "http://nas/a")!))
}
@Test func davNamespacesStatusAndOrigin() throws {
    let xml = """
    <?xml version="1.0"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response><D:href>/video/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
      <D:response><D:href>/video/movies/</D:href><D:propstat><D:prop><D:displayname>电影</D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
      <D:response><D:href>/video/A%20B.mp4</D:href><D:propstat><D:prop><D:displayname>A &amp; B</D:displayname><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat><D:propstat><D:prop><D:displayname>Wrong</D:displayname></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
      <D:response><D:href>https://other.example/steal.mp4</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
      <D:response><D:href>/video/private.mp4</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 403 Forbidden</D:status></D:propstat></D:response>
    </D:multistatus>
    """
    let result = try DAVParser(base: URL(string: "https://nas.example/video/")!).parse(Data(xml.utf8))
    #expect(result.count == 2)
    #expect(result[0].isDirectory)
    #expect(result[0].name == "电影")
    #expect(result[1].name == "A & B")
    #expect(result[1].url.lastPathComponent == "A B.mp4")
}
@Test func rejectsMalformedDAV() {
    #expect(throws: (any Error).self) { try DAVParser(base: URL(string: "https://nas.example/")!).parse(Data("not xml".utf8)) }
}
@Test func webDAVCreationAndModificationDatesAreAvailableForSorting() throws {
    let xml = """
    <d:multistatus xmlns:d="DAV:"><d:response><d:href>/video/new.mp4</d:href><d:propstat><d:prop>
    <d:creationdate>2026-09-24T08:00:00.000Z</d:creationdate>
    <d:getlastmodified>Thu, 24 Sep 2026 07:00:00 GMT</d:getlastmodified>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
    """
    let entry = try #require(DAVParser(base: URL(string: "https://nas.example/video/")!).parse(Data(xml.utf8)).first)
    #expect(entry.createdAt != nil)
    #expect(entry.modifiedAt != nil)
    #expect(entry.displayDate == entry.createdAt)
    #expect(MediaTimestamp.parse("2026-09-24T08:00:00Z") != nil)
    #expect(MediaTimestamp.parse("2026-09-24T08:00:00.1234567Z") != nil)
}
@Test func timeFormatting() {
    #expect(0.0.mediaTime == "00:00")
    #expect(3671.0.mediaTime == "1:01:11")
    #expect(Double.nan.mediaTime == "00:00")
    #expect((-4.0).mediaTime == "00:00")
}

@Test func directoryScopeNeverBecomesGlobalOrRecursive() {
    let first = DirectoryQuery.items(userID: "user", parentID: "folder-A", start: 0)
    let next = DirectoryQuery.items(userID: "user", parentID: "folder-A", start: 100)
    #expect(first["ParentId"] == "folder-A")
    #expect(next["ParentId"] == first["ParentId"])
    #expect(first["Recursive"] == "false")
    #expect(next["Recursive"] == "false")
    #expect(next["StartIndex"] == "100")
    #expect(DirectoryQuery.items(userID: "user", parentID: "folder-B", start: 0)["ParentId"] == "folder-B")
    let preview = DirectoryQuery.folderPreview(userID: "user", parentID: "folder-A")
    #expect(preview["ParentId"] == "folder-A")
    #expect(preview["Recursive"] == "true")
    #expect(preview["MediaTypes"] == "Video")
    #expect(preview["Limit"] == "20")
}
