import Foundation
import Testing
import AVFoundation
@testable import GlideCore

struct VideoFileRotationTests {
    private let unit: [Int32] = [65536,0,0,0,65536,0,0,0,1 << 30]
    private func bytes(_ values: [UInt32]) -> Data {
        values.reduce(into: Data()) { data, number in var big = number.bigEndian; withUnsafeBytes(of: &big) { data.append(contentsOf: $0) } }
    }
    private func atom(_ type: String, _ content: Data, extended: Bool = false) -> Data {
        (extended ? bytes([1]) + Data(type.utf8) + bytes([0, UInt32(content.count + 16)]) : bytes([UInt32(content.count + 8)]) + Data(type.utf8)) + content
    }
    private func track(version: UInt8 = 0, kind: String = "vide", extended: Bool = false) -> Data {
        var head = Data(repeating: 0, count: version == 1 ? 52 : 40); head[0] = version
        head.append(bytes(unit.map { UInt32(bitPattern: $0) })); head.append(bytes([1920 << 16, 1080 << 16]))
        let handler = atom("hdlr", Data(repeating: 0, count: 8) + Data(kind.utf8))
        return atom("trak", atom("tkhd", head) + atom("mdia", handler), extended: extended)
    }
    private func withFile(_ data: Data, _ body: (URL) throws -> Void) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try data.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        try body(file)
    }

    @Test func quarterTurnsComposeWithExistingOrientationAndKeepPositiveBounds() throws {
        let right = try VideoFileRotation.rotated(unit, width: 1920 << 16, height: 1080 << 16, turn: .clockwise)
        #expect(right == [0,65536,0,-65536,0,0,1080 << 16,0,1 << 30])
        let restored = try VideoFileRotation.rotated(right, width: 1920 << 16, height: 1080 << 16, turn: .counterclockwise)
        #expect(restored == unit)
        #expect(try VideoFileRotation.rotated(unit, width: 1920 << 16, height: 1080 << 16, turn: .original) == unit)
    }
    @Test func rotatedCopyChangesOnlyTheTrackMatrixAndPreservesEveryOtherByte() throws {
        let original = atom("ftyp", Data("isom0000".utf8)) + atom("moov", track() + track(kind: "soun") + track(kind: "subt")) + atom("mdat", Data((0..<2048).map { UInt8($0 % 251) }))
        try withFile(original) { file in
            let patch = try VideoFileRotation.inspect(file, turn: .clockwise)
            try VideoFileRotation.apply(patch, toStagedFile: file)
            let corrected = try Data(contentsOf: file), range = Int(patch.matrixOffset)..<Int(patch.matrixOffset + 36)
            #expect(corrected.count == original.count)
            #expect(Data(corrected[range]) == patch.replacement)
            #expect(corrected.prefix(range.lowerBound) == original.prefix(range.lowerBound))
            #expect(corrected.suffix(from: range.upperBound) == original.suffix(from: range.upperBound))
            #expect(patch.width == 1920 && patch.height == 1080)
        }
    }
    @Test func versionOneAndExtendedBoxesAreParsedWithoutRewritingOffsets() throws {
        try withFile(atom("moov", track(version: 1, extended: true), extended: true) + atom("mdat", Data(repeating: 42, count: 128))) { file in
            let patch = try VideoFileRotation.inspect(file, turn: .upsideDown)
            try VideoFileRotation.apply(patch, toStagedFile: file)
            #expect(try VideoFileRotation.inspect(file, turn: .upsideDown).replacement == Data(bytes(unit.map { UInt32(bitPattern: $0) })))
        }
    }
    @Test func malformedContainersAndAmbiguousVideoTracksAreRejectedWithoutMutation() throws {
        for data in [Data(), bytes([1000]) + Data("moov".utf8), atom("moov", track() + track()), atom("moov", track(kind: "soun"))] {
            try withFile(data) { file in
                #expect(throws: (any Error).self) { try VideoFileRotation.inspect(file, turn: .clockwise) }
                let unchanged = try Data(contentsOf: file)
                #expect(unchanged == data)
            }
        }
        var perspective = unit; perspective[2] = 1
        #expect(throws: VideoFileRotationError.unsupportedMatrix) { try VideoFileRotation.rotated(perspective, width: 65536, height: 65536, turn: .clockwise) }
    }
    @Test func fileChangesAfterInspectionPreventWriting() throws {
        try withFile(atom("moov", track())) { file in
            let patch = try VideoFileRotation.inspect(file, turn: .clockwise)
            var changed = try Data(contentsOf: file); changed.append(7); try changed.write(to: file)
            #expect(throws: VideoFileRotationError.fileChanged) { try VideoFileRotation.apply(patch, toStagedFile: file) }
            #expect(try Data(contentsOf: file) == changed)
        }
    }
    @Test func originalAuthoredMP4LoadsWithCorrectedTrackTransform() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let original = root.appendingPathComponent("Glide/Resources/demo0.mp4")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try FileManager.default.copyItem(at: original, to: file); defer { try? FileManager.default.removeItem(at: file) }
        let before = try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first!
        let size = try await before.load(.naturalSize), transform = try await before.load(.preferredTransform)
        let old = CGRect(origin: .zero, size: size).applying(transform)
        try VideoFileRotation.apply(VideoFileRotation.inspect(file, turn: .clockwise), toStagedFile: file)
        let track = try await AVURLAsset(url: file).loadTracks(withMediaType: .video).first!
        let updated = try await track.load(.preferredTransform)
        let new = CGRect(origin: .zero, size: size).applying(updated)
        #expect(abs(new.width - old.height) < 0.01 && abs(new.height - old.width) < 0.01)
        #expect(updated != transform)
    }
}
