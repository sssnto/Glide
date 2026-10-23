import Foundation
import Testing
@testable import GlideCore

struct VideoNavigationTests {
    @Test func mapIsBoundedAndCoversLongVideoWithoutEndOfFileFrames() {
        let values = ContentMapPlan.segments(duration: 10_800)
        #expect(values.count == 24)
        #expect(values.first?.start == 0)
        #expect(values.last?.end == 10_800)
        #expect(values.allSatisfy { $0.start < $0.end && $0.start < 10_800 })
        for index in 1..<values.count { #expect(values[index - 1].end == values[index].start) }
    }
    @Test func refiningOnlySamplesSelectedWindow() {
        let range = MapSegment(start: 3600, end: 4050)
        let fine = ContentMapPlan.segments(duration: 7200, range: range)
        #expect(fine.count == 24)
        #expect(fine.allSatisfy { $0.start >= 3600 && $0.end <= 4050 })
        #expect(ContentMapPlan.segments(duration: 0.2).count == 1)
    }
    @Test func invalidRangesAndDurationsNeverCreateSamples() {
        for duration in [0, -1, Double.nan, .infinity] { #expect(ContentMapPlan.segments(duration: duration).isEmpty) }
        for range in [MapSegment(start: .nan, end: 20), MapSegment(start: 1, end: .infinity), MapSegment(start: 9, end: 2), MapSegment(start: 21, end: 22)] {
            #expect(ContentMapPlan.segments(duration: 20, range: range).isEmpty)
        }
    }
    private var info: TrickplayInfo { TrickplayInfo(Width: 160, Height: 90, TileWidth: 4, TileHeight: 3, ThumbnailCount: 30, Interval: 2000) }
    @Test func spriteIndexCoversRowsSheetsAndLastPartialSheet() {
        #expect(info.tile(at: 10) == .init(sheet: 0, x: 160, y: 90, time: 10))
        #expect(info.tile(at: 24) == .init(sheet: 1, x: 0, y: 0, time: 24))
        #expect(info.tile(at: 999) == .init(sheet: 2, x: 160, y: 90, time: 58))
        #expect(info.tile(at: 11.9)?.time == 10)
        #expect(info.tile(at: .nan) == nil)
    }
    @Test func untrustedSpriteMetadataCannotOverflowOrAllocateHugeImages() {
        var huge = info; huge.Width = Int.max
        #expect(!huge.valid && huge.tile(at: 1) == nil)
        huge = info; huge.TileHeight = 0; #expect(!huge.valid)
        huge = info; huge.Interval = 0; #expect(!huge.valid)
        huge = info; huge.Width = 1024; huge.Height = 1024; huge.TileWidth = 8; huge.TileHeight = 8
        #expect(!huge.valid)
        #expect(info.tile(at: -1) == nil)
    }
    @Test func serverVersionsNeverBorrowOtherChaptersOrTrickplay() throws {
        let json = #"{"MediaSources":[{"Id":"cut-a"},{"Id":"cut-b"}],"Chapters":[{"Name":"Opening","StartPositionTicks":20000000}],"Trickplay":{"cut-b":{"160":{"Width":160,"Height":90,"TileWidth":4,"TileHeight":3,"ThumbnailCount":30,"Interval":2000}}}}"#
        let metadata = try JSONDecoder().decode(VideoNavigationMetadata.self, from: Data(json.utf8))
        #expect(metadata.chapters(sourceID: "cut-a", duration: 60).first?.time == 2)
        #expect(metadata.chapters(sourceID: "cut-b", duration: 60).isEmpty)
        #expect(metadata.trickplay(sourceID: "cut-a") == nil)
        #expect(metadata.trickplay(sourceID: "CUT-B")?.Width == 160)
        #expect(metadata.source("missing") == nil)
    }
    @Test func chapterNavigationRejectsInvalidTimesAndDeduplicates() {
        let values = NavigationChapter.normalized([
            .init(id: "a", name: "A", time: 20), .init(id: "b", name: "B", time: 0),
            .init(id: "c", name: "C", time: 20), .init(id: "d", name: "D", time: .nan),
            .init(id: "e", name: "E", time: 30), .init(id: "f", name: "F", time: -1)], duration: 30)
        #expect(values.map(\.time) == [0, 20])
    }
    private var moment: MediaMoment {
        let video = Video(id: "item", title: "Authored", subtitle: "", url: URL(string: "https://u:secret@example.com/v?token=secret"), artwork: URL(string: "https://example.com/art?token=secret"))
        let reference = MomentReference(kind: .catalog, videoID: video.id, accountID: "user-a", mediaSourceID: "version-a", revision: "revision")
        return MediaMoment(video: video, reference: reference, position: 12, duration: 30, name: "  Birthday  ")
    }
    @Test func savedMomentsRemoveTransientURLsAndBoundNames() throws {
        var item = moment; item.name = String(repeating: "字", count: 100)
        let saved = try item.validated()
        #expect(saved.video.url == nil && saved.video.artwork == nil && saved.name.count == 80)
        let text = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        #expect(!text.contains("secret"))
        item.name = "  "; #expect(try item.validated().name == "时刻 00:12")
    }
    @Test func invalidMomentsCannotBePersisted() {
        for position in [-1, 30, Double.nan, .infinity] {
            var item = moment; item.position = position
            #expect(throws: (any Error).self) { try item.validated() }
        }
        var item = moment; item.reference.videoID = "other"
        #expect(throws: (any Error).self) { try item.validated() }
    }
    @Test func accountAndVersionIdentityAreIndependent() {
        var server = MediaServer(name: "Server", kind: .jellyfin, address: URL(string: "https://example.com")!, username: "user", userID: "user-a")
        var reference = moment.reference; reference.sourceID = server.id
        #expect(reference.matches(server))
        server.userID = "user-b"; #expect(!reference.matches(server))
        var changed = reference; changed.mediaSourceID = "version-b"; #expect(reference != changed)
        changed = reference; changed.revision = "replaced"; #expect(reference != changed)
    }
    @Test func momentsRecoverFromDamagedSnapshotAndKeepIdentityWhenRenamed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RecoverableStore<[MediaMoment]>(file: folder.appendingPathComponent("moments.json"))
        var saved = try moment.validated(); try store.save([saved])
        saved.name = "Changed"; try store.save([saved])
        #expect(try store.load()?.value.first?.id == saved.id)
        try Data("damaged".utf8).write(to: store.file)
        #expect(try store.load()?.recovered == true)
        #expect(try store.load()?.value.first?.name == "Birthday")
    }
}
