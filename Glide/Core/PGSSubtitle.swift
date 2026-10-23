import Foundation

/// SUP display sets stay compressed in memory. Only the current display set is
/// rasterized, independently of the video decoder and its HDR output.
struct PGSSubtitle: Sendable {
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumPixels = 4096 * 2160
    struct Rect: Sendable, Equatable { var x: Int; var y: Int; var width: Int; var height: Int }
    struct Object: Sendable {
        var width: Int; var height: Int; var expected: Int; var rle: Data; var complete: Bool
    }
    struct Layer: Sendable {
        var object: Object; var x: Int; var y: Int; var crop: Rect?; var window: Rect?
    }
    struct Cue: Sendable {
        var start: Double; var end: Double; var width: Int; var height: Int
        var palette: [UInt32]; var layers: [Layer]
    }
    struct Raster: Sendable { var rect: Rect; var rgba: Data }
    let cues: [Cue]
    var compressedBytes: Int
    func index(at time: Double, delay: Double = 0) -> Int? {
        let value = time - delay
        guard value.isFinite else { return nil }
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= value { low = mid + 1 } else { high = mid }
        }
        guard low > 0, value < cues[low - 1].end else { return nil }
        return low - 1
    }
    static func parse(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else { throw Failure.limit }
        var input = Reader(data), objects: [Int: Object] = [:], palettes: [Int: [UInt32]] = [:]
        var windows: [Int: Rect] = [:], references: [(Int, Int, Int, Int, Rect?)] = []
        var width = 0, height = 0, paletteID = 0, start = 0.0, cues: [Cue] = []
        var lastPTS: UInt32?, wrap: UInt64 = 0, retained = 0, pending = false
        while input.remaining > 0 {
            try Task.checkCancellation()
            guard try input.u16() == 0x5047 else { throw Failure.invalid }
            let pts = try input.u32(); _ = try input.u32()
            let kind = try input.byte(), length = try input.u16()
            var part = Reader(try input.take(length))
            switch kind {
            case 0x16:
                guard part.remaining >= 11 else { throw Failure.invalid }
                if let lastPTS, pts < lastPTS, UInt64(lastPTS) - UInt64(pts) > UInt64(UInt32.max) / 2 { wrap += 1 << 32 }
                lastPTS = pts
                start = Double(wrap + UInt64(pts)) / 90_000
                guard cues.last.map({ start >= $0.start }) ?? true else { throw Failure.invalid }
                if !cues.isEmpty { cues[cues.count - 1].end = start }
                width = try part.u16(); height = try part.u16()
                guard width > 0, height > 0, width <= 4096, height <= 2160 else { throw Failure.limit }
                _ = try part.byte(); _ = try part.u16()
                let state = try part.byte()
                if state & 0xc0 != 0 { objects = [:]; palettes = [:]; windows = [:] }
                _ = try part.byte(); paletteID = Int(try part.byte())
                let count = Int(try part.byte())
                guard count <= 2 else { throw Failure.invalid }
                references = []
                for _ in 0..<count {
                    let id = try part.u16(), window = Int(try part.byte()), flags = try part.byte()
                    let x = try part.u16(), y = try part.u16()
                    var crop: Rect?
                    if flags & 0x80 != 0 { crop = Rect(x: try part.u16(), y: try part.u16(), width: try part.u16(), height: try part.u16()) }
                    references.append((id, window, x, y, crop))
                }
                pending = true
            case 0x17:
                let count = Int(try part.byte())
                guard count <= 2 else { throw Failure.invalid }
                for _ in 0..<count {
                    let id = Int(try part.byte())
                    windows[id] = Rect(x: try part.u16(), y: try part.u16(), width: try part.u16(), height: try part.u16())
                }
            case 0x14:
                let id = Int(try part.byte()); _ = try part.byte()
                guard part.remaining % 5 == 0, palettes[id] != nil || palettes.count < 8 else { throw Failure.invalid }
                var palette = palettes[id] ?? Array(repeating: UInt32(0), count: 256)
                while part.remaining > 0 {
                    let index = Int(try part.byte()), y = Double(try part.byte()) - 16
                    let cr = Double(try part.byte()) - 128, cb = Double(try part.byte()) - 128, alpha = UInt32(try part.byte())
                    func component(_ value: Double) -> UInt32 { UInt32(min(255, max(0, value.rounded()))) * alpha / 255 }
                    let r = component(1.164384 * y + (height > 576 ? 1.792741 : 1.596027) * cr)
                    let g = component(1.164384 * y - (height > 576 ? 0.213249 : 0.391762) * cb - (height > 576 ? 0.532909 : 0.812968) * cr)
                    let b = component(1.164384 * y + (height > 576 ? 2.112402 : 2.017232) * cb)
                    palette[index] = r << 24 | g << 16 | b << 8 | alpha
                }
                palettes[id] = palette
            case 0x15:
                let id = try part.u16(); _ = try part.byte(); let flags = try part.byte()
                if flags & 0x80 != 0 {
                    let expected = try part.u24() - 4, w = try part.u16(), h = try part.u16()
                    guard expected > 0, expected <= maximumBytes, w > 0, h > 0,
                          w <= width, h <= height, objects[id] != nil || objects.count < 64 else { throw Failure.invalid }
                    objects[id] = Object(width: w, height: h, expected: expected, rle: Data(), complete: false)
                }
                guard var object = objects[id], !object.complete, object.rle.count + part.remaining <= object.expected else { throw Failure.invalid }
                object.rle.append(try part.take(part.remaining))
                object.complete = flags & 0x40 != 0
                if object.complete, object.rle.count != object.expected { throw Failure.invalid }
                objects[id] = object
            case 0x80:
                guard pending else { throw Failure.invalid }
                pending = false
                if references.isEmpty { continue }
                guard let palette = palettes[paletteID], cues.count < 30_000 else { throw Failure.invalid }
                var layers: [Layer] = []
                for (id, window, x, y, crop) in references {
                    guard let object = objects[id], object.complete, x < width, y < height else { throw Failure.invalid }
                    retained += object.rle.count
                    guard retained <= maximumBytes * 2 else { throw Failure.limit }
                    layers.append(Layer(object: object, x: x, y: y, crop: crop, window: windows[window]))
                }
                cues.append(Cue(start: start, end: .infinity, width: width, height: height, palette: palette, layers: layers))
            default: break
            }
        }
        guard !pending, !cues.isEmpty else { throw Failure.invalid }
        return Self(cues: cues, compressedBytes: data.count)
    }
    /// Returns tightly bounded, premultiplied RGBA rectangles, not full canvases.
    static func rasterize(_ cue: Cue) throws -> [Raster] {
        var rasters: [Raster] = [], pixels = 0
        for layer in cue.layers {
            try Task.checkCancellation()
            let object = layer.object
            pixels += object.width * object.height
            guard pixels <= maximumPixels else { throw Failure.limit }
            var input = Reader(object.rle), row = 0, column = 0
            var indices = [UInt8](repeating: 0, count: object.width * object.height)
            while input.remaining > 0, row < object.height {
                let value = try input.byte()
                var count = 1, color = value
                if value == 0 {
                    let flags = try input.byte()
                    count = Int(flags & 0x3f)
                    if flags & 0x40 != 0 { count = count << 8 | Int(try input.byte()) }
                    color = flags & 0x80 != 0 ? try input.byte() : 0
                    if count == 0 { row += 1; column = 0; continue }
                }
                guard count <= object.width - column else { throw Failure.invalid }
                let base = row * object.width + column
                for n in base..<(base + count) { indices[n] = color }
                column += count
            }
            guard row == object.height || (row == object.height - 1 && column == object.width) else { throw Failure.invalid }
            let crop = layer.crop ?? Rect(x: 0, y: 0, width: object.width, height: object.height)
            guard crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
                  crop.x + crop.width <= object.width, crop.y + crop.height <= object.height else { throw Failure.invalid }
            let window = layer.window ?? Rect(x: 0, y: 0, width: cue.width, height: cue.height)
            let x = max(layer.x, window.x), y = max(layer.y, window.y)
            let right = min(layer.x + crop.width, window.x + window.width, cue.width)
            let bottom = min(layer.y + crop.height, window.y + window.height, cue.height)
            guard x < right, y < bottom else { continue }
            var rgba = Data(count: (right - x) * (bottom - y) * 4)
            rgba.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                for dy in 0..<(bottom - y) {
                    for dx in 0..<(right - x) {
                        let value = cue.palette[Int(indices[(crop.y + y - layer.y + dy) * object.width + crop.x + x - layer.x + dx])]
                        let offset = (dy * (right - x) + dx) * 4
                        bytes[offset] = UInt8((value >> 24) & 255); bytes[offset + 1] = UInt8((value >> 16) & 255)
                        bytes[offset + 2] = UInt8((value >> 8) & 255); bytes[offset + 3] = UInt8(value & 255)
                    }
                }
            }
            rasters.append(Raster(rect: Rect(x: x, y: y, width: right - x, height: bottom - y), rgba: rgba))
        }
        return rasters
    }
    enum Failure: Error, LocalizedError {
        case invalid, limit
        var errorDescription: String? { self == .limit ? "PGS 字幕超出大小或画面限制。" : "PGS 字幕数据不完整或格式不支持。" }
    }
    private struct Reader {
        let data: Data; var offset = 0
        init(_ data: Data) { self.data = data }
        var remaining: Int { data.count - offset }
        mutating func byte() throws -> UInt8 {
            guard remaining > 0 else { throw Failure.invalid }
            defer { offset += 1 }; return data[data.startIndex + offset]
        }
        mutating func u16() throws -> Int { try Int(byte()) << 8 | Int(byte()) }
        mutating func u24() throws -> Int { try u16() << 8 | Int(byte()) }
        mutating func u32() throws -> UInt32 { try UInt32(u16()) << 16 | UInt32(u16()) }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw Failure.invalid }
            defer { offset += count }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
        }
    }
}
