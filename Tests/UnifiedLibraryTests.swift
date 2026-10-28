import Foundation
import Testing
@testable import GlideCore

private func unified(_ id: String, binding: String = "server-a", title: String = "测试电影", type: String = "Movie", providers: [String: String] = [:], offline: Bool = false) -> UnifiedRecord {
    UnifiedRecord(id: id, binding: binding, sourceName: binding, video: Video(id: id, title: title, subtitle: "", mediaType: type), providers: providers, offline: offline)
}

@Test func unifiedUsesTrustedIdentifiersAndNeverTitleOnly() {
    let a = unified("a", providers: ["Tmdb": "123"]), b = unified("b", binding: "server-b", providers: ["tmdb": "123"])
    #expect(UnifiedLibraryGrouping.works([a,b], query: "").count == 1)
    #expect(UnifiedLibraryGrouping.works([unified("a"),unified("b")], query: "").count == 2)
    #expect(UnifiedLibraryGrouping.works([a,unified("remake", providers: ["Tmdb":"456"])], query: "").count == 2)
}
@Test func unifiedKeepsMovieSeriesAndEpisodesInDifferentNamespaces() {
    let values = ["Movie","Series","Episode","Video"].map { unified($0, type: $0, providers: ["Tmdb":"123"]) }
    #expect(UnifiedLibraryGrouping.works(values, query: "").count == 4)
    #expect(UnifiedLibraryGrouping.providerKey(["imdb":"tt12345"], type:"Movie") == "Movie:imdb:tt12345")
    for value in ["0", "-1", "12/path", "https://123", "999999999999999999999999999"] {
        #expect(UnifiedLibraryGrouping.providerKey(["Tmdb":value], type:"Movie") == nil)
    }
}
@Test func unifiedConflictingSecondaryIdentifiersPreventAutomaticMerge() {
    let a = unified("a", providers:["Tmdb":"123","Imdb":"tt12345"])
    let b = unified("b", providers:["Tmdb":"123","Imdb":"tt54321"])
    #expect(UnifiedLibraryGrouping.works([a,b],query:"").count == 2)
    #expect(UnifiedLibraryGrouping.providerKey(["Tmdb":"00123"],type:"Movie") == "Movie:tmdb:123")
}
@Test func unifiedAlternateTitlesRetainAllMatchingWorkVersions() {
    let a = unified("a", title:"Café Story", providers:["Tmdb":"1"])
    let b = unified("b", title:"咖啡故事", providers:["Tmdb":"1"])
    #expect(UnifiedLibraryGrouping.works([a,b], query:"CAFE").first?.variants.count == 2)
    #expect(UnifiedLibraryGrouping.works([a,b], query:"咖啡").first?.variants.count == 2)
    #expect(UnifiedLibraryGrouping.works([a,b], query:"不存在").isEmpty)
}
@Test func unifiedOfflineCopyAndRemoteVersionsReuseIdentity() {
    let a = unified("server-item-v1", providers:["Tmdb":"1"])
    var b = unified("offline-copy", offline:true); b.video.id = a.video.id
    let work = UnifiedLibraryGrouping.works([a,b,a], query:"").first!
    #expect(work.variants.count == 2)
    #expect(work.hasOffline)
    #expect(work.variants.first?.offline == true)
    b.binding = "other-account"
    #expect(UnifiedLibraryGrouping.works([a,b], query:"").count == 2)
}
@Test func unifiedFiltersOnlyReturnRequestedKindsAndOfflineEntries() {
    let rows = [unified("film"),unified("show",type:"Series"),unified("episode",type:"Episode"),unified("home",type:"Video"),unified("download",offline:true)]
    #expect(UnifiedLibraryGrouping.works(rows, query:"", filter:.movies).count == 2)
    #expect(UnifiedLibraryGrouping.works(rows, query:"", filter:.series).count == 2)
    #expect(UnifiedLibraryGrouping.works(rows, query:"", filter:.videos).count == 1)
    #expect(UnifiedLibraryGrouping.works(rows, query:"", filter:.downloaded).first?.variants.first?.id == "download")
}
@Test func unifiedSelectionSurvivesOrderChangesButNeverSelectsMissingVersion() {
    let a=unified("a"),b=unified("b")
    let work=UnifiedWork(id:"work",variants:[a,b])
    #expect(UnifiedLibraryGrouping.preferred(in:work,saved:"b")?.id == "b")
    #expect(UnifiedLibraryGrouping.preferred(in:work,saved:"removed") == nil)
    #expect(UnifiedLibraryGrouping.preferred(in:work,saved:nil)?.id == "a")
    #expect(!UnifiedLibraryGrouping.canReuseDownload(savedSourceID:"v1",requestedSourceID:"v2"))
    #expect(!UnifiedLibraryGrouping.canReuseDownload(savedSourceID:nil,requestedSourceID:"v1"))
    #expect(UnifiedLibraryGrouping.canReuseDownload(savedSourceID:"v1",requestedSourceID:"v1"))
}
@Test func unifiedSnapshotContainsDisplayMetadataWithoutPathsOrPlaybackCredentials() throws {
    var row = unified("a")
    row.video.remoteID="remote";row.video.url=URL(string:"https://server.test/video?api_key=secret")
    row.video.artwork=URL(string:"https://server.test/image?api_key=secret")
    row.mediaSource=CatalogItem.Source(Id:"v1",Path:"/private/video.mkv")
    let data=try JSONEncoder().encode(row.sanitized()), text=String(decoding:data,as:UTF8.self)
    #expect(!text.contains("secret"));#expect(!text.contains("/private/"));#expect(!text.contains("https"))
    #expect(try JSONDecoder().decode(UnifiedRecord.self,from:data).mediaSource?.Id == "v1")
}
@Test func unifiedLargeMetadataSearchKeepsStableGroups() {
    let rows=(1...10_000).map { unified("item-\($0)",title:"电影 \($0)",providers:["Tmdb":String($0)]) }
    let found=UnifiedLibraryGrouping.works(rows,query:"电影 9999")
    #expect(found.count == 1);#expect(found.first?.id == "Movie:tmdb:9999")
}
