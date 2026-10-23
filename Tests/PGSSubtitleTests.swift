import Foundation
import Testing
@testable import GlideCore

struct PGSSubtitleTests {
    private func be(_ n: Int, _ bytes: Int = 2) -> [UInt8] { (0..<bytes).reversed().map { UInt8((n >> ($0 * 8)) & 255) } }
    private func packet(_ type: UInt8, _ body: [UInt8], pts: Int = 90_000) -> [UInt8] {
        [0x50, 0x47] + be(pts, 4) + be(0, 4) + [type] + be(body.count) + body
    }
    private func pcs(pts: Int, clear: Bool = false, state: UInt8 = 0x80, crop: Bool = false) -> [UInt8] {
        packet(0x16, be(1920) + be(1080) + [0x10] + be(1) + [state, 0, 0, clear ? 0 : 1]
            + (clear ? [] : be(1) + [0, crop ? 0x80 : 0] + be(100) + be(900) + (crop ? be(1) + be(1) + be(1) + be(1) : [])), pts: pts)
    }
    private func fixture(fragmented: Bool = false, cropped: Bool = false, rle: [UInt8] = [1, 1, 0, 0, 1, 1, 0, 0]) -> Data {
        var value = pcs(pts: 90_000, crop: cropped)
        value += packet(0x14, [0, 0, 0, 16, 128, 128, 0, 1, 235, 128, 128, 255])
        let first = fragmented ? Array(rle.prefix(3)) : rle
        value += packet(0x15, be(1) + [0, fragmented ? 0x80 : 0xc0] + be(rle.count + 4, 3) + be(2) + be(2) + first)
        if fragmented { value += packet(0x15, be(1) + [0, 0x40] + Array(rle.dropFirst(3))) }
        value += packet(0x80, []) + pcs(pts: 270_000, clear: true, state: 0) + packet(0x80, [], pts: 270_000)
        return Data(value)
    }
    @Test func presentationClearsAndSeekUsesOriginalTimestamps() throws {
        let value = try PGSSubtitle.parse(fixture())
        #expect(value.cues.count == 1)
        #expect(value.index(at: 0.99) == nil)
        #expect(value.index(at: 1) == 0 && value.index(at: 2.99) == 0)
        #expect(value.index(at: 3) == nil)
        #expect(value.index(at: 1.5, delay: 1) == nil)
        #expect(value.index(at: 2, delay: 1) == 0)
        #expect(value.index(at: .nan) == nil)
        let raster = try #require(PGSSubtitle.rasterize(value.cues[0]).first)
        #expect(raster.rect == PGSSubtitle.Rect(x: 100, y: 900, width: 2, height: 2))
        #expect(raster.rgba == Data(repeating: 255, count: 16))
    }
    @Test func fragmentedObjectsAndCropRetainGeometryAndAlpha() throws {
        let track = try PGSSubtitle.parse(fixture(fragmented: true, cropped: true))
        let raster = try #require(PGSSubtitle.rasterize(track.cues[0]).first)
        #expect(raster.rect == PGSSubtitle.Rect(x: 100, y: 900, width: 1, height: 1))
        #expect(raster.rgba == Data(repeating: 255, count: 4))
        let transparent = try PGSSubtitle.parse(fixture(rle: [0, 2, 0, 0, 0, 2, 0, 0]))
        #expect(try PGSSubtitle.rasterize(transparent.cues[0]).first?.rgba == Data(repeating: 0, count: 16))
    }
    @Test func hostileTruncatedAndOversizedDataFailsWithoutAllocatingImages() throws {
        let data = fixture()
        // Every prefix before the first complete END must be rejected.
        let end = data.count - pcs(pts: 270_000, clear: true, state: 0).count - packet(0x80, [], pts: 270_000).count
        for n in 0..<end { #expect(throws: (any Error).self) { try PGSSubtitle.parse(data.prefix(n)) } }
        var invalid = data; invalid[0] = 0
        #expect(throws: (any Error).self) { try PGSSubtitle.parse(invalid) }
        let overflow = try PGSSubtitle.parse(fixture(rle: [0, 0x83, 1]))
        #expect(throws: (any Error).self) { try PGSSubtitle.rasterize(overflow.cues[0]) }
        let incomplete = try PGSSubtitle.parse(fixture(rle: [1]))
        #expect(throws: (any Error).self) { try PGSSubtitle.rasterize(incomplete.cues[0]) }
        var huge = data; huge[13] = 0x7f; huge[14] = 0xff
        #expect(throws: (any Error).self) { try PGSSubtitle.parse(huge) }
    }
    @Test func extendedRunsClipToWindowWithoutChangingPremultipliedAlpha() throws {
        var value = packet(0x16, be(1920) + be(1080) + [0x10] + be(1) + [0x80, 0, 0, 1] + be(1) + [0, 0] + be(5) + be(7))
        value += packet(0x17, [1, 0] + be(7) + be(8) + be(3) + be(1))
        value += packet(0x14, [0, 0, 1, 235, 128, 128, 128])
        let rle: [UInt8] = [0, 0xc0, 100, 1, 0, 0, 0, 0xc0, 100, 1, 0, 0]
        value += packet(0x15, be(1) + [0, 0xc0] + be(rle.count + 4, 3) + be(100) + be(2) + rle)
        value += packet(0x80, [])
        let track = try PGSSubtitle.parse(Data(value)), raster = try #require(PGSSubtitle.rasterize(track.cues[0]).first)
        #expect(raster.rect == PGSSubtitle.Rect(x: 7, y: 8, width: 3, height: 1))
        #expect(raster.rgba == Data(repeating: 128, count: 12))
    }
    @Test func corruptedSegmentsRemainBoundedAndNeverIndexOutsideData() {
        let original = fixture(fragmented: true)
        for position in original.indices {
            for byte: UInt8 in [0, 0xff] {
                var data = original; data[position] = byte
                if let track = try? PGSSubtitle.parse(data) {
                    for cue in track.cues { _ = try? PGSSubtitle.rasterize(cue) }
                }
            }
        }
    }
    @Test func ptsWrapAndNormalPaletteOnlyUpdatesReuseObjects() throws {
        let original = fixture()
        let firstEnd = original.count - pcs(pts: 270_000, clear: true, state: 0).count - packet(0x80, [], pts: 270_000).count
        var value = Array(original.prefix(firstEnd))
        value += pcs(pts: 180_000, state: 0)
        value += packet(0x14, [0, 1, 1, 235, 128, 128, 128], pts: 180_000) + packet(0x80, [], pts: 180_000)
        value += pcs(pts: 270_000, clear: true, state: 0) + packet(0x80, [], pts: 270_000)
        let track = try PGSSubtitle.parse(Data(value))
        #expect(track.cues.count == 2 && track.index(at: 2.2) == 1)
        #expect(try PGSSubtitle.rasterize(track.cues[1]).first?.rgba.first == 128)
        var wrapped = Array(original.prefix(firstEnd))
        wrapped.replaceSubrange(2..<6, with: be(Int(UInt32.max) - 10, 4))
        wrapped += pcs(pts: 20, clear: true, state: 0) + packet(0x80, [], pts: 20)
        let rollover = try PGSSubtitle.parse(Data(wrapped))
        #expect(rollover.cues[0].end > rollover.cues[0].start)
        #expect(rollover.cues[0].end - rollover.cues[0].start < 0.001)
    }
}
