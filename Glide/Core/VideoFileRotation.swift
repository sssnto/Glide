import Foundation

enum VideoQuarterTurn: Int, Codable, CaseIterable, Identifiable, Sendable {
    case original = 0, clockwise = 1, upsideDown = 2, counterclockwise = 3
    var id: Int { rawValue }
    var degrees: Int { rawValue * 90 }
    var swapsAxes: Bool { rawValue % 2 == 1 }
    var title: String { switch self { case .original: "原方向"; case .clockwise: "右转 90°"; case .upsideDown: "旋转 180°"; case .counterclockwise: "左转 90°" } }
}

enum VideoFileRotationError: Error, LocalizedError {
    case unsupportedFile, invalidContainer, multipleVideoTracks, unsupportedMatrix, fileChanged
    var errorDescription: String? {
        switch self {
        case .unsupportedFile: "目前支持 MP4、MOV 和 M4V 的无重编码方向修正。请选择对应原文件。"
        case .invalidContainer: "视频容器无法完整校验，已保留原文件。"
        case .multipleVideoTracks: "此文件含多个视频轨道，暂不自动修改方向。"
        case .unsupportedMatrix: "此文件使用暂不支持的画面变换，已保留原文件。"
        case .fileChanged: "原文件已发生变化，请重新读取并预览后再保存。"
        }
    }
}

struct VideoRotationPatch: Equatable, Sendable {
    let fileSize: UInt64
    let matrixOffset: UInt64
    let original: Data
    let replacement: Data
    let width: Double
    let height: Double
    let turn: VideoQuarterTurn
}

/// ISO BMFF track-matrix edit. Sample data, offsets, audio, subtitles and metadata stay byte-identical.
/// Always apply to a staged copy; publishing/replacing the original is a separate transaction.
enum VideoFileRotation {
    private struct Box {
        var type: String
        var payload: UInt64
        var end: UInt64
    }
    static func inspect(_ file: URL, turn: VideoQuarterTurn) throws -> VideoRotationPatch {
        guard ["mp4", "mov", "m4v"].contains(file.pathExtension.lowercased()) else { throw VideoFileRotationError.unsupportedFile }
        try regularFile(file)
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let roots = try boxes(handle, from: 0, to: size)
        let movies = roots.filter { $0.type == "moov" }
        guard movies.count == 1 else { throw VideoFileRotationError.invalidContainer }
        let movie = movies[0], children = try boxes(handle, from: movie.payload, to: movie.end)
        guard !children.contains(where: { $0.type == "cmov" }) else { throw VideoFileRotationError.unsupportedFile }
        var headers = [Box]()
        for track in children where track.type == "trak" {
            let trackBoxes = try boxes(handle, from: track.payload, to: track.end)
            let media = trackBoxes.filter { $0.type == "mdia" }
            guard media.count == 1 else { throw VideoFileRotationError.invalidContainer }
            let mediaBoxes = try boxes(handle, from: media[0].payload, to: media[0].end)
            let handlers = mediaBoxes.filter { $0.type == "hdlr" }
            guard handlers.count == 1, handlers[0].end - handlers[0].payload >= 12 else { throw VideoFileRotationError.invalidContainer }
            let handler = try read(handle, at: handlers[0].payload + 8, count: 4)
            if handler == Data("vide".utf8) {
                let values = trackBoxes.filter { $0.type == "tkhd" }
                guard values.count == 1 else { throw VideoFileRotationError.invalidContainer }
                headers.append(values[0])
            }
        }
        guard headers.count == 1 else {
            if headers.count > 1 { throw VideoFileRotationError.multipleVideoTracks }
            throw VideoFileRotationError.invalidContainer
        }
        let header = headers[0], version = try read(handle, at: header.payload, count: 1)[0]
        guard version <= 1 else { throw VideoFileRotationError.invalidContainer }
        let offset = header.payload + (version == 1 ? 52 : 40)
        guard offset <= header.end, header.end - offset >= 44 else { throw VideoFileRotationError.invalidContainer }
        let data = try read(handle, at: offset, count: 44)
        let matrix = (0..<9).map { Int32(bitPattern: u32(data, $0 * 4)) }
        let w = u32(data, 36), h = u32(data, 40)
        guard w > 0, h > 0 else { throw VideoFileRotationError.invalidContainer }
        let result = try rotated(matrix, width: w, height: h, turn: turn)
        let bytes = result.reduce(into: Data()) { data, number in
            var big = number.bigEndian; withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }
        return VideoRotationPatch(fileSize: size, matrixOffset: offset, original: Data(data.prefix(36)), replacement: bytes,
                                  width: Double(w) / 65536, height: Double(h) / 65536, turn: turn)
    }

    static func apply(_ patch: VideoRotationPatch, toStagedFile file: URL) throws {
        try regularFile(file)
        let handle = try FileHandle(forUpdating: file); defer { try? handle.close() }
        guard try handle.seekToEnd() == patch.fileSize,
              try read(handle, at: patch.matrixOffset, count: 36) == patch.original else { throw VideoFileRotationError.fileChanged }
        try handle.seek(toOffset: patch.matrixOffset); try handle.write(contentsOf: patch.replacement); try handle.synchronize()
        guard try read(handle, at: patch.matrixOffset, count: 36) == patch.replacement else { throw VideoFileRotationError.fileChanged }
    }

    static func rotated(_ matrix: [Int32], width: UInt32, height: UInt32, turn: VideoQuarterTurn) throws -> [Int32] {
        guard matrix.count == 9, matrix[2] == 0, matrix[5] == 0, matrix[8] == 1 << 30 else { throw VideoFileRotationError.unsupportedMatrix }
        guard turn != .original else { return matrix }
        var a = Int64(matrix[0]), b = Int64(matrix[1]), c = Int64(matrix[3]), d = Int64(matrix[4])
        var tx = Int64(matrix[6]), ty = Int64(matrix[7])
        guard [a,b,c,d].allSatisfy({ abs($0) <= 8 * 65536 }), a * d - b * c != 0 else { throw VideoFileRotationError.unsupportedMatrix }
        for _ in 0..<turn.rawValue { (a,b,c,d,tx,ty) = (-b,a,-d,c,-ty,tx) }
        let corners: [(Int64, Int64)] = [(0,0),(Int64(width),0),(0,Int64(height)),(Int64(width),Int64(height))]
        let minX = corners.map { (a * $0.0 + c * $0.1) / 65536 + tx }.min()!
        let minY = corners.map { (b * $0.0 + d * $0.1) / 65536 + ty }.min()!
        tx -= minX; ty -= minY
        let values: [Int64] = [a,b,0,c,d,0,tx,ty,1 << 30]
        guard values.allSatisfy({ $0 >= Int64(Int32.min) && $0 <= Int64(Int32.max) }) else { throw VideoFileRotationError.unsupportedMatrix }
        return values.map { Int32($0) }
    }

    private static func boxes(_ handle: FileHandle, from start: UInt64, to end: UInt64) throws -> [Box] {
        guard start <= end else { throw VideoFileRotationError.invalidContainer }
        var offset = start, result = [Box]()
        while offset < end {
            try Task.checkCancellation()
            guard end - offset >= 8, result.count < 100_000 else { throw VideoFileRotationError.invalidContainer }
            let head = try read(handle, at: offset, count: 8)
            var size = UInt64(u32(head, 0)), header: UInt64 = 8
            if size == 1 {
                guard end - offset >= 16 else { throw VideoFileRotationError.invalidContainer }
                let ext = try read(handle, at: offset + 8, count: 8)
                size = UInt64(u32(ext, 0)) << 32 | UInt64(u32(ext, 4)); header = 16
            } else if size == 0 { size = end - offset }
            guard size >= header, size <= end - offset else { throw VideoFileRotationError.invalidContainer }
            let type = String(bytes: head.suffix(4), encoding: .ascii) ?? ""
            result.append(Box(type: type, payload: offset + header, end: offset + size)); offset += size
        }
        return result
    }
    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { throw VideoFileRotationError.invalidContainer }
        return data
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<offset+4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
    private static func regularFile(_ file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard file.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true else { throw VideoFileRotationError.unsupportedFile }
    }
}
