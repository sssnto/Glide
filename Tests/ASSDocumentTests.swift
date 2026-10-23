import Testing
import Foundation
@testable import GlideCore

struct ASSDocumentTests {
    private let script = #"""
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360
    [V4+ Styles]
    Format: Name, Fontname, Fontsize
    Style: Default,Original Font,24
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Comment: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,Never visible
    Dialogue: 0,0:00:01.23,0:00:03.45,Default,,0,0,0,,{\fnSecond Font\1c&H0000FF&\move(0,0,20,20)\fad(200,200)}中文{\r}\NText, with a comma
    Dialogue: 1,0:00:00.50,0:00:01.00,Default,,0,0,0,,{\p1}m 0 0 l 50 50{\p0}
    """#
    @Test func originalBytesAndEffectsRemainUntouched() throws {
        let data = Data(script.utf8), document = try ASSDocument.parse(data)
        #expect(document.data == data)
        #expect(document.cues.count == 1)
        #expect(document.cues[0].start == 1.23)
        #expect(document.cues[0].text == "中文\nText, with a comma")
        #expect(document.requestedFonts == ["Original Font", "Second Font"])
    }
    @Test func badTimesDoNotEnterTranscriptButDoNotRewriteScript() throws {
        let text = script.replacingOccurrences(of: "0:00:01.23", with: "0:99:01.23")
        let data = Data(text.utf8), document = try ASSDocument.parse(data)
        #expect(document.cues.isEmpty)
        #expect(document.data == data)
    }
    @Test func rejectsNonScriptsOversizeAndNonUTF8() throws {
        #expect(throws: (any Error).self) { try ASSDocument.parse(Data("ordinary SRT".utf8)) }
        #expect(throws: (any Error).self) { try ASSDocument.parse(Data(repeating: 0xff, count: 10)) }
        #expect(throws: (any Error).self) { try ASSDocument.parse(Data(repeating: 65, count: SubtitleDocument.maximumBytes + 1)) }
    }
    @Test func managedOriginalASSCopiesRetainRawStyles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SubtitleMemoryStore(directory: dir), data = Data(script.utf8)
        let name = try store.makeImportedCopy(data, extension: "ass")
        #expect(try Data(contentsOf: store.importedURL(name)) == data)
        #expect(SidecarSubtitleMatch.candidate(videoName: "episode.mkv", url: URL(fileURLWithPath: "/tmp/episode.zh.ass"))?.language != nil)
    }
}
