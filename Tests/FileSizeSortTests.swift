import Foundation
import Testing
@testable import GlideCore

@Suite struct FileSizeSortTests {
    @Test func bothDirectionsUseBytesAndKeepUnknownLastWithStableTies() {
        let videos = [Video(id:"unknown",title:"A",subtitle:""),
                      Video(id:"negative",title:"Z",subtitle:"",fileSize:-1),
                      Video(id:"b",title:"clip2",subtitle:"",fileSize:20),
                      Video(id:"a",title:"clip2",subtitle:"",fileSize:20),
                      Video(id:"zero",title:"clip1",subtitle:"",fileSize:0),
                      Video(id:"huge",title:"clip10",subtitle:"",fileSize:Int64.max)]
        #expect(VideoSort.sizeAscending.sorted(videos).map(\.id) == ["zero","a","b","huge","unknown","negative"])
        #expect(VideoSort.sizeDescending.sorted(videos).map(\.id) == ["huge","a","b","zero","unknown","negative"])
        let large = Int64(1) << 54
        let close = [Video(id:"b",title:"B",subtitle:"",fileSize:large+1),Video(id:"a",title:"A",subtitle:"",fileSize:large+2)]
        #expect(VideoSort.sizeDescending.sorted(close).map(\.id) == ["a","b"])
    }

    @Test func serverPagesStayScopedAndRequestSizeMetadataWithoutAnUnsupportedSort() {
        for sort in [VideoSort.sizeAscending,.sizeDescending] {
            for cursor in [0,200,400] {
                let query = DirectoryQuery.playback(userID:"user",parentID:"folder",start:cursor,search:"旅行",options:BrowseOptions(includesDescendants:false,sort:sort))
                #expect(query["ParentId"] == "folder" && query["Recursive"] == "false")
                #expect(query["SortBy"] == "SortName" && query["SortOrder"] == "Ascending")
                #expect(query["Fields"]?.contains("MediaSources") == true)
                #expect(query["StartIndex"] == String(cursor) && query["SearchTerm"] == "旅行")
            }
        }
    }

    @Test func oldRecordsAndNewSizePreferencesRoundTrip() throws {
        let old = try JSONDecoder().decode(Video.self,from:Data(#"{"id":"old","title":"Old","subtitle":"","duration":0,"resume":0}"#.utf8))
        #expect(old.fileSize == nil)
        let video = Video(id:"new",title:"New",subtitle:"",fileSize:Int64.max)
        #expect(try JSONDecoder().decode(Video.self,from:JSONEncoder().encode(video)).fileSize == Int64.max)
        for sort in [VideoSort.sizeAscending,.sizeDescending] {
            let options = BrowseOptions(includesDescendants:true,sort:sort)
            #expect(try JSONDecoder().decode(BrowseOptions.self,from:JSONEncoder().encode(options)) == options)
        }
    }

    @Test func webDAVAcceptsOnlySuccessfulNonnegativeFileLengths() throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/video/one.mp4</d:href><d:propstat><d:prop><d:getcontentlength>4294967297</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/video/two.mp4</d:href><d:propstat><d:prop><d:getcontentlength>99</d:getcontentlength></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat><d:propstat><d:prop><d:displayname>two.mp4</d:displayname></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/video/three.mp4</d:href><d:propstat><d:prop><d:getcontentlength>-1</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/video/folder/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getcontentlength>123</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """
        let entries = try DAVParser(base:URL(string:"https://nas.example/video/")!).parse(Data(xml.utf8))
        #expect(entries.first { $0.name == "one.mp4" }?.fileSize == 4_294_967_297)
        #expect(entries.filter { $0.name != "one.mp4" }.allSatisfy { $0.fileSize == nil })
    }

    @Test func movieSizeUsesDefaultVersionAndNeverSumsAlternativeVersions() throws {
        let first = try JSONDecoder().decode(CatalogItem.self,from:Data(#"{"Id":"first","Name":"First","Type":"Movie","MediaSources":[{"Id":"default","Size":100},{"Id":"alternate","Size":9000}]}"#.utf8))
        let second = try JSONDecoder().decode(CatalogItem.self,from:Data(#"{"Id":"second","Name":"Second","Type":"Movie","MediaSources":[{"Id":"default","Size":200}]}"#.utf8))
        let unknown = try JSONDecoder().decode(CatalogItem.self,from:Data(#"{"Id":"unknown","Name":"A","Type":"Movie","MediaSources":[{"Id":"default"},{"Id":"alternate","Size":10000}]}"#.utf8))
        #expect(first.fileSize == 100 && unknown.fileSize == nil)
        let order = CatalogOrder(sort:.size,descending:true)
        #expect(order.sortedBySize([first,unknown,second]).map(\.id) == ["second","first","unknown"])
        #expect(order.query["SortBy"] == "SortName" && order.query["SortOrder"] == "Ascending")
    }

    @Test func oldWebDAVIndexesRefreshOnlyWhenSizeSortingNeedsThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let cache = DirectoryListingCache(directory:directory)
        let server = MediaServer(name:"NAS",kind:.webDAV,address:URL(string:"https://nas.example/video/")!,username:"fixture")
        let identity = DirectoryCacheIdentity(server)
        let entry = DAVEntry(url:server.address.appendingPathComponent("one.mp4"),name:"one.mp4",isDirectory:false)
        try await cache.store(identity,root:server.address,recursive:false,listings:[CachedDirectoryListing(directory:server.address,entries:[entry],date:Date(),metadataVersion:nil)])
        #expect(await cache.scan(identity,directory:server.address,recursive:false) != nil)
        #expect(await cache.scan(identity,directory:server.address,recursive:false,requiresFileSize:true) == nil)
        // A server which omits lengths is still cached after the new metadata request.
        try await cache.store(identity,root:server.address,recursive:false,listings:[CachedDirectoryListing(directory:server.address,entries:[entry],date:Date())])
        #expect(await cache.scan(identity,directory:server.address,recursive:false,requiresFileSize:true) != nil)
    }
}
