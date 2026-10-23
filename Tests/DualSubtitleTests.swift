import Foundation
import Testing
@testable import GlideCore

struct DualSubtitleTests {
    @Test func primaryMemoryKeyPreservesLegacyIdentityAndSecondaryIsSeparate() {
        let key = "source:account:root:video"
        #expect(SubtitleLane.primary.memoryKey(key) == key)
        #expect(SubtitleLane.secondary.memoryKey(key) != key)
        #expect(SubtitleLane.secondary.memoryKey(key) != SubtitleLane.secondary.memoryKey(key + "other"))
    }
    @Test func legacyMemoryAndSecondaryOffsetsRoundTripIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SubtitleMemoryStore(directory: directory), base = "legacy-video"
        let primary = SubtitleMemory(sourceID: UUID(), videoID: "v", revision: nil, choice: .sidecar(name: "film.zh.srt", digest: "zh"), delay: 1.2)
        let secondary = SubtitleMemory(sourceID: primary.sourceID, videoID: "v", revision: nil, choice: .sidecar(name: "film.en.vtt", digest: "en"), delay: -0.7)
        try store.set(primary, for: base)
        try store.set(secondary, for: SubtitleLane.secondary.memoryKey(base))
        let saved = try store.load().value
        #expect(saved[base] == primary)
        #expect(saved[SubtitleLane.secondary.memoryKey(base)] == secondary)
        try store.set(nil, for: SubtitleLane.secondary.memoryKey(base))
        #expect(try store.load().value[base] == primary)
    }
    @Test func twoImportedCopiesSurviveOffAndOtherLaneReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SubtitleMemoryStore(directory: directory)
        let a = try store.makeImportedCopy(Data("zh".utf8), extension: "srt")
        let main = SubtitleMemory(sourceID: nil, videoID: "v", revision: nil, choice: .imported(file: a, name: "zh.srt", digest: "a"), delay: 0)
        // Persist each import as soon as created, just like the production session.
        try store.set(main, for: "v")
        let b = try store.makeImportedCopy(Data("en".utf8), extension: "vtt")
        let next = SubtitleMemory(sourceID: nil, videoID: "v", revision: nil, choice: .off, delay: 2, importedCopy: ImportedSubtitleCopy(file: b, name: "en.vtt", digest: "b"))
        try store.set(next, for: SubtitleLane.secondary.memoryKey("v"))
        try store.set(SubtitleMemory(sourceID: nil, videoID: "v", revision: nil, choice: .off, delay: 0, importedCopy: main.choice.importedCopy), for: "v")
        #expect(FileManager.default.fileExists(atPath: try store.importedURL(a).path))
        #expect(FileManager.default.fileExists(atPath: try store.importedURL(b).path))
    }
    @Test func videoRemovalClearsBothLanesWithoutRemovingAnotherVideo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SubtitleMemoryStore(directory: directory)
        for key in ["v", SubtitleLane.secondary.memoryKey("v"), "other"] {
            try store.set(SubtitleMemory(sourceID: nil, videoID: key == "other" ? "other" : "v", revision: nil, choice: .off, delay: 0), for: key)
        }
        try store.remove(videoID: "v")
        #expect(Set(try store.load().value.keys) == ["other"])
    }
    @Test func sharedClockRespectsIndependentPositiveAndNegativeDelays() {
        let zh = [SubtitleCue(start: 1, end: 3, text: "中文")], en = [SubtitleCue(start: 2, end: 4, text: "English")]
        #expect(SubtitleCue.visible(zh, time: 2, delay: 1) == "中文")
        #expect(SubtitleCue.visible(en, time: 2, delay: -1) == "English")
        #expect(SubtitleCue.visible(zh, time: 4, delay: 1) == nil)
        #expect(SubtitleCue.visible(en, time: 3, delay: -1) == nil)
        #expect(SubtitleCue.visible(zh, time: 0, delay: -1) == "中文")
    }
    @Test func pendingImportSurvivesOtherLaneCollectionAndReleasesWhenAbandoned() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SubtitleMemoryStore(directory: directory)
        let name = try store.makeImportedCopy(Data("pending".utf8), extension: "srt")
        let file = try store.importedURL(name)
        var lease: SubtitleImportLease? = SubtitleImportLease(file: file)
        try withExtendedLifetime(lease) {
            try store.set(SubtitleMemory(sourceID: nil, videoID: "other", revision: nil, choice: .off, delay: 0), for: "other")
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        lease = nil
        try store.set(nil, for: "other")
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

}
