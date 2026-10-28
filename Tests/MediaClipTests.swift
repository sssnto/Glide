import Foundation
import Testing
@testable import GlideCore

struct MediaClipTests {
    private func clip(start: Double = 2, end: Double = 5) -> MediaClip {
        let video = Video(id: "local-a", title: "原创", subtitle: "", url: URL(string: "https://example.com/private?token=secret"), artwork: URL(string: "https://example.com/art"), duration: 12)
        return MediaClip(moment: MediaMoment(video: video, reference: MomentReference(kind: .local, videoID: video.id, accountID: "user", revision: "v1"), position: start, duration: 12, name: "精彩"), end: end)
    }
    @Test func validatesIntervalsAndSanitizesMetadata() throws {
        let valid = try clip().validated()
        #expect(valid.length == 3)
        #expect(valid.moment.video.url == nil && valid.moment.video.artwork == nil)
        for bounds in [(2.0,2.0),(2,2.4),(4,3),(-1,3),(2,13),(Double.nan,3),(2,Double.infinity)] {
            #expect(throws: (any Error).self) { try clip(start: bounds.0, end: bounds.1).validated() }
        }
    }
    @Test func cursorNeverResumesOutsideClip() {
        let value = clip()
        #expect(value.resume(3) == 3)
        for time: Double? in [nil, -2, 1, 5, 6, .nan, .infinity] { #expect(value.resume(time) == 2) }
    }
    @Test func sameVideoDifferentIntervalsRemainSeparate() throws {
        var state = ClipLibrarySnapshot(); let a = clip(), b = clip(start: 6, end: 9)
        try state.save(a, to: nil, newName: "旅行")
        let id = try #require(state.collections.first?.id)
        try state.save(b, to: id); try state.save(a, to: id)
        #expect(state.clips.count == 2)
        #expect(state.collections[0].clipIDs == [a.id,b.id])
    }
    @Test func reorderCoverAndDeletionKeepReferencesConsistent() throws {
        var state = ClipLibrarySnapshot(); let a = clip(), b = clip(start: 6, end: 9)
        try state.save(a, to: nil, newName: "旅行"); let id = state.collections[0].id
        try state.save(b, to: id)
        var collection = state.collections[0]; collection.clipIDs = [b.id,a.id]; collection.coverID = b.id
        try state.update(collection)
        state.record(collectionID: id, clipID: b.id, position: 7, finished: false)
        #expect(state.entries(state.collections[0]).map(\.id) == [b.id,a.id])
        state.removeClip(b.id)
        #expect(state.collections[0].coverID == nil && state.collections[0].cursor == nil)
        #expect(state.clips.count == 1 && state.collections[0].clipIDs == [a.id])
    }
    @Test func progressBelongsToCollectionAndSurvivesSnapshot() throws {
        var state = ClipLibrarySnapshot(); let a = clip()
        try state.save(a, to: nil, newName: "A"); let first = state.collections[0].id
        try state.save(a, to: nil, newName: "B"); let second = state.collections[0].id
        state.record(collectionID: first, clipID: a.id, position: 999, finished: true)
        #expect(state.collections.first { $0.id == first }?.cursor?.position == a.end)
        #expect(state.collections.first { $0.id == second }?.cursor == nil)
        let restored = try JSONDecoder().decode(ClipLibrarySnapshot.self, from: JSONEncoder().encode(state))
        #expect(restored == state)
        #expect(restored.clips[0].moment.video.url == nil)
    }
    @Test func invalidReferencesAndLimitsRejected() throws {
        var state = ClipLibrarySnapshot(); let a = clip()
        #expect(throws: (any Error).self) { try state.save(a, to: UUID()) }
        #expect(state.clips.isEmpty)
        try state.save(a, to: nil, newName: "A")
        var group = state.collections[0]; group.clipIDs = [a.id,a.id]
        #expect(throws: (any Error).self) { try state.update(group) }
        group.clipIDs = [UUID()]
        #expect(throws: (any Error).self) { try state.update(group) }
        group.clipIDs = [a.id]; group.name = "  "
        #expect(throws: (any Error).self) { try state.update(group) }
    }
    @Test func deletingCollectionRetainsClipsAndOriginalIdentity() throws {
        var state = ClipLibrarySnapshot(); let a = clip()
        try state.save(a, to: nil, newName: "A")
        state.collections.removeAll()
        #expect(state.clips.count == 1 && state.clips[0].moment.reference == a.moment.reference)
    }
}
