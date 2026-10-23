import Foundation
import Testing
@testable import GlideCore

struct SubtitleSelectionTests {
    @Test func serverSubtitleIdentityRequiresMatchingSourceIndexAndFormat() throws {
        let stream = CatalogItem.Stream(Index: 13, Type: "Subtitle", DisplayTitle: "简体中文", Language: "zho", Codec: "subrip")
        let saved = SubtitleServerTrack(mediaSourceID: "version-a", stream: stream)
        #expect(saved.match(in: [stream], mediaSourceID: "version-a") == stream)
        #expect(saved.match(in: [stream], mediaSourceID: "version-b") == nil)
        var changed = stream; changed.Codec = "pgssub"
        #expect(saved.match(in: [changed], mediaSourceID: "version-a") == nil)
        changed = stream; changed.Index = 14
        #expect(saved.match(in: [changed], mediaSourceID: "version-a") == nil)
        changed = stream; changed.Language = "eng"
        #expect(saved.match(in: [changed], mediaSourceID: "version-a") == nil)
    }
    @Test func serverSubtitleMemoryRoundTripsWithoutSubtitleBody() throws {
        let stream = CatalogItem.Stream(Index: 13, Type: "Subtitle", DisplayTitle: "简体中文", Language: "zho", Codec: "subrip")
        let choice = SubtitleChoice.server(SubtitleServerTrack(mediaSourceID: "version-a", stream: stream))
        let memory = SubtitleMemory(sourceID: UUID(), videoID: "episode", revision: nil, choice: choice, delay: 0.7)
        #expect(try JSONDecoder().decode(SubtitleMemory.self, from: JSONEncoder().encode(memory)) == memory)
        #expect(choice.suppressesEmbedded && choice.managedFile == nil)
        let legacy = Data(#"{"embedded":{"_0":{"engine":"avPlayer","id":"subtitle-1","name":"English","language":"eng","forced":false}}}"#.utf8)
        if case .embedded(let old) = try JSONDecoder().decode(SubtitleChoice.self, from: legacy) { #expect(old.id == "subtitle-1") }
        else { Issue.record("Legacy embedded choice was not preserved") }
    }
    @Test func sameLanguageServerVariantsRemainDistinct() {
        let first = CatalogItem.Stream(Index: 13, Type: "Subtitle", Language: "zho", Codec: "subrip")
        let second = CatalogItem.Stream(Index: 14, Type: "Subtitle", Language: "zho", Codec: "subrip")
        let a = SubtitleServerTrack(mediaSourceID: "v", stream: first), b = SubtitleServerTrack(mediaSourceID: "v", stream: second)
        #expect(a != b && a.name != b.name)
        #expect(a.match(in: [second, first], mediaSourceID: "v") == first)
    }
    private func candidate(_ name: String, video: String = "第 1 集.mp4") -> SidecarSubtitle? {
        SidecarSubtitleMatch.candidate(videoName: video, url: URL(fileURLWithPath: "/fixtures/" + name))
    }
    @Test func exactStemLanguageAndEpisodeBoundaries() {
        #expect(candidate("第 1 集.SRT")?.language == nil)
        #expect(candidate("第 1 集.zh-Hans.srt")?.language == "zh-Hans")
        #expect(candidate("第 1 集.繁體.vtt")?.language == "zh-Hant")
        #expect(candidate("第 1 集.eng.forced.vtt")?.forced == true)
        for name in ["第 10 集.srt", "第 1 集2.srt", "第 1 集.下一集.srt", "第 1 集.zh.en.srt"] {
            #expect(candidate(name) == nil)
        }
        #expect(candidate("Movie.zh-CN.SRT", video: "movie.MKV")?.language == "zh-Hans")
        #expect(candidate("家庭 # @+%&.srt", video: "家庭 # @+%&.mp4") != nil)
    }
    @Test func ambiguousCandidatesRequireUniquePreference() throws {
        let chinese = try #require(candidate("第 1 集.zh-Hans.srt"))
        let traditional = try #require(candidate("第 1 集.zh-Hant.srt"))
        let english = try #require(candidate("第 1 集.en.vtt"))
        #expect(SidecarSubtitleMatch.automatic([chinese, english], language: "", forcedOnly: false) == nil)
        #expect(SidecarSubtitleMatch.automatic([chinese, english], language: "zh", forcedOnly: false) == chinese)
        #expect(SidecarSubtitleMatch.automatic([chinese, traditional], language: "zh", forcedOnly: false) == nil)
        #expect(SidecarSubtitleMatch.automatic([chinese, traditional], language: "zh-CN", forcedOnly: false) == chinese)
        #expect(SidecarSubtitleMatch.automatic([chinese], language: "off", forcedOnly: false) == nil)
        #expect(SidecarSubtitleMatch.automatic([chinese], language: "zh", forcedOnly: true) == nil)
        let forced = try #require(candidate("第 1 集.zh.forced.srt"))
        #expect(SidecarSubtitleMatch.automatic([forced, chinese], language: "zh", forcedOnly: true) == forced)
    }
    @Test func identitySeparatesAccountRootAndPath() throws {
        let sourceID = UUID()
        var server = MediaServer(id: sourceID, name: "NAS", kind: .smb, address: URL(string: "smb://nas/media/")!, username: "alice")
        var video = Video(id: "file", title: "同名.mp4", subtitle: "", sourceID: sourceID, url: server.address.appendingPathComponent("甲/同名.mp4"))
        let original = try SubtitleIdentity(video: video, server: server)
        server.username = "bob"
        #expect(try SubtitleIdentity(video: video, server: server) != original)
        server.username = "alice"; video.url = server.address.appendingPathComponent("乙/同名.mp4")
        #expect(try SubtitleIdentity(video: video, server: server) != original)
        video.url = URL(string: "smb://nas/other/同名.mp4")
        #expect(throws: (any Error).self) { try SubtitleIdentity(video: video, server: server) }
    }
    @Test func importedIdentitySurvivesSandboxRelocation() throws {
        let id = UUID()
        var server = MediaServer(id: id, name: "导入", kind: .local, address: URL(fileURLWithPath: "/sandbox/a/ImportedMedia"), username: "")
        let video = Video(id: "local", title: "same.mp4", subtitle: "", sourceID: id, localRelativePath: "same.mp4")
        let first = try SubtitleIdentity(video: video, server: server)
        server.address = URL(fileURLWithPath: "/sandbox/b/ImportedMedia")
        #expect(try SubtitleIdentity(video: video, server: server) == first)
        server.localBookmark = Data("stable-directory-bookmark".utf8)
        let authorized = try SubtitleIdentity(video: video, server: server)
        server.address = URL(fileURLWithPath: "/sandbox/c/AuthorizedDirectory")
        #expect(try SubtitleIdentity(video: video, server: server) == authorized)
        server.localBookmark = Data("different-directory-bookmark".utf8)
        #expect(try SubtitleIdentity(video: video, server: server) != authorized)
    }
    @Test func documentLimitsEncodingAndClock() throws {
        let srt = Data("\u{feff}1\r\n00:00:01,000 --> 00:00:04,000\r\n字幕甲\r\n\r\n2\r\n00:00:04,000 --> 00:00:08,000\r\n字幕乙\r\n".utf8)
        let cues = try SubtitleDocument.parse(srt)
        #expect(SubtitleCue.visible(cues, time: 4.5, delay: 1) == "字幕甲")
        #expect(SubtitleCue.visible(cues, time: 4.5, delay: 0) == "字幕乙")
        #expect(throws: (any Error).self) { try SubtitleDocument.parse(Data([0xff, 0xfe, 0x41])) }
        #expect(throws: (any Error).self) { try SubtitleDocument.parse(Data()) }
        #expect(throws: (any Error).self) { try SubtitleDocument.parse(Data(repeating: 65, count: 2_000_001)) }
        #expect(try SubtitleDocument.parse(Data("WEBVTT\n\n00:01.000 --> 00:03.000 align:start\nVTT text\n".utf8)).count == 1)
    }
    @Test func embeddedMemorySurvivesEngineChangeWithoutGuessingAmongLanguages() {
        let saved = SubtitleEmbeddedTrack(engine: .avPlayer, id: "subtitle-0", name: "中文", language: "zho", forced: false)
        let chinese = PlaybackTrack(id: "subtitle-7", kind: .subtitle, displayName: "Track 2", language: "chi", forced: false)
        #expect(saved.match(in: [chinese], engine: .vlc) == chinese)
        let second = PlaybackTrack(id: "subtitle-9", kind: .subtitle, displayName: "Commentary", language: "zh", forced: false)
        #expect(saved.match(in: [chinese, second], engine: .vlc) == nil)
    }
    @Test func managedCopySurvivesOriginalDeletionAndStoreRecreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("source.srt"), data = Data("subtitle".utf8)
        try data.write(to: original)
        let store = SubtitleMemoryStore(directory: root.appendingPathComponent("state"))
        let file = try store.makeImportedCopy(Data(contentsOf: original), extension: "srt")
        let entry = SubtitleMemory(sourceID: nil, videoID: "a", revision: nil, choice: .imported(file: file, name: "source.srt", digest: "hash"), delay: 1.5)
        try store.set(entry, for: "a"); try FileManager.default.removeItem(at: original)
        let restored = SubtitleMemoryStore(directory: store.directory)
        #expect(try restored.load().value["a"] == entry)
        #expect(try Data(contentsOf: restored.importedURL(file)) == data)
        #expect(throws: (any Error).self) { try restored.importedURL("../source.srt") }
        #expect(throws: (any Error).self) { try restored.makeImportedCopy(Data(repeating: 0, count: 2_000_001), extension: "srt") }
    }
    @Test func backupRetainsPreviousCopyAndCorruptionDoesNotEraseMemory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SubtitleMemoryStore(directory: root)
        let file = try store.makeImportedCopy(Data("first".utf8), extension: "srt")
        var entry = SubtitleMemory(sourceID: UUID(), videoID: "a", revision: SubtitleRevision(size: 50, modified: Date(timeIntervalSince1970: 1)), choice: .imported(file: file, name: "first.srt", digest: "hash"), delay: 2)
        try store.set(entry, for: "a")
        entry.choice = .off; try store.set(entry, for: "a")
        #expect(FileManager.default.fileExists(atPath: try store.importedURL(file).path))
        try Data("broken".utf8).write(to: root.appendingPathComponent("selection-v1.json"))
        let restored = try store.load()
        #expect(restored.recovered)
        #expect(restored.value["a"]?.choice.managedFile == file)
        #expect(restored.value["a"]?.safeDelay == 2)
    }
    @Test func sourceRemovalAndOffMemoryStayIsolated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SubtitleMemoryStore(directory: root), first = UUID(), second = UUID()
        let a = SubtitleMemory(sourceID: first, videoID: "a", revision: nil, choice: .off, delay: .infinity)
        let b = SubtitleMemory(sourceID: second, videoID: "b", revision: nil, choice: .off, delay: 3)
        try store.set(a, for: "a"); try store.set(b, for: "b")
        #expect(a.safeDelay == 0)
        try store.remove(sourceID: first)
        #expect(try store.load().value == ["b": b])
    }
    @Test func disabledImportedCopyRemainsAvailableAfterOtherVideosChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SubtitleMemoryStore(directory: root)
        let file = try store.makeImportedCopy(Data("saved".utf8), extension: "srt")
        let saved = ImportedSubtitleCopy(file: file, name: "original.srt", digest: "hash")
        let off = SubtitleMemory(sourceID: nil, videoID: "a", revision: nil, choice: .off, delay: 1.5, importedCopy: saved)
        try store.set(off, for: "a")
        try store.set(SubtitleMemory(sourceID: nil, videoID: "b", revision: nil, choice: .off, delay: 0), for: "b")
        try store.set(nil, for: "b")
        #expect(try store.load().value["a"]?.importedCopy == saved)
        #expect(try Data(contentsOf: store.importedURL(file)) == Data("saved".utf8))
    }
}

struct ASSPlainTextTests {
    @Test func convertedBilingualASSRemovesFontColorAndResetCodes() throws {
        let chinese = #"{\fn原创中文字体\fs20\bord2\blur3\1c&HC8C8BF\shad1\b1}原创测试中文{\r}"#
        let english = #"{\fnOriginalFont\fs14\bord2\blur3\shad1\1c&H3DA8DB&\b1}Original test caption.{\r}"#
        let data = Data(("1\n00:00:01,000 --> 00:00:04,000\n" + chinese + "\n" + english).utf8)
        let cues = try SubtitleDocument.parse(data)
        #expect(cues == [.init(start: 1, end: 4, text: "原创测试中文\nOriginal test caption.")])
        #expect(SubtitleCue.visible(cues, time: 2, delay: 0) == "原创测试中文\nOriginal test caption.")
    }
    @Test func overridesAndBreaksWorkForServerASSAndConvertedSubrip() {
        #expect(ASSPlainText.render(#"{\an8\pos(200,300)}甲\N乙\h丙{\r}"#) == "甲\n乙\u{00a0}丙")
        #expect(ASSPlainText.render(#"甲\N乙"#, enabled: true) == "甲\n乙")
        #expect(ASSPlainText.render(#"{\q2}A\nB{\q0}\nC"#) == "A\nB C")
        #expect(ASSPlainText.render(#"{\q2}A{\r}B\nC"#) == "AB C")
    }
    @Test func drawingsAreHiddenButFollowingDialogueSurvives() {
        #expect(ASSPlainText.render(#"{\p1}m 0 0 l 100 0 100 100{\p0}对白"#) == "对白")
        #expect(ASSPlainText.render(#"{\p999999999999999999999}m 1 2{\rDefault}Text"#) == "Text")
        #expect(ASSPlainText.render(#"{\pbo20\pos(1,2)\clip(m 1 2 l 3 4)\t(0,100,\p1)}Caption"#) == "Caption")
        #expect(SubtitleCue.parse("1\n00:00:01,000 --> 00:00:02,000\n{\\p1}m 1 2 l 3 4").isEmpty)
    }
    @Test func plainBracesPathsAndMalformedTextAreNotDeleted() {
        let plain = #"Use {a,b} and C:\new\home\N; keep {unclosed"#
        #expect(ASSPlainText.render(plain) == plain)
        #expect(ASSPlainText.render(#"{\b1}Hello{\b0} {literal}"#) == "Hello {literal}")
        #expect(ASSPlainText.render(#"{comment}{\b1}Hello"#, enabled: true) == "Hello")
        #expect(ASSPlainText.render(#"{\b1 missing end Hello"#) == #"{\b1 missing end Hello"#)
    }
    @Test func timingHTMLAndAdjacentStylesRemainUsable() {
        let input = "WEBVTT\n\n00:01.250 --> 00:03.500 align:start\n<i>{\\b1}甲{\\b0}</i>{\\fnFont}乙\\N丙{\\r}"
        #expect(SubtitleCue.parse(input).first == SubtitleCue(start: 1.25, end: 3.5, text: "甲乙\n丙"))
        #expect(ASSPlainText.render(#"{\i1}{\b1}Test{\b0}{\i0}"#) == "Test")
    }
    @Test func manyCuesDoNotLoseCJKOrUnicode() {
        let data = (0..<2000).map { index in "\(index + 1)\n00:\(String(format: "%02d", index / 60)):\(String(format: "%02d", index % 60)),000 --> 01:00:00,000\n{\\fnFont\\b1}片段🙂e\u{301}\\NText{\\r}" }.joined(separator: "\n\n")
        let cues = SubtitleCue.parse(data)
        #expect(cues.count == 2000)
        #expect(cues.allSatisfy { $0.text == "片段🙂e\u{301}\nText" })
    }
}
