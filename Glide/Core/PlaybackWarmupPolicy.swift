import Foundation

/// A small moving window follows the actual queue, including its shuffled order.
enum PlaybackWarmupPolicy {
    static let maximumItems = 3
    static let initialHeadBytes = 2 * 1024 * 1024
    static let headBytes = 16 * 1024 * 1024
    static let secondaryHeadBytes = 4 * 1024 * 1024
    static let segmentedTargetBytes = 32 * 1024 * 1024
    static func segmentedSeconds(bitrate: Int?) -> Double {
        guard let bitrate, bitrate > 0 else { return 8 }
        return min(16, max(4, Double(segmentedTargetBytes) * 8 / Double(bitrate)))
    }
    static let tailBytes = 256 * 1024
    static let lifetime: TimeInterval = 180
    static let requestDeadline: TimeInterval = 6
    static func indices(current: Int, count: Int, direction: Int = 1) -> [Int] {
        guard current >= 0, current < count else { return [] }
        let step = direction < 0 ? -1 : 1
        return [current + step, current + step * 2, current - step].filter { $0 >= 0 && $0 < count }
    }
    static func allowsNetwork(satisfied: Bool, wifi: Bool, expensive: Bool, constrained: Bool, lowPower: Bool) -> Bool {
        satisfied && wifi && !expensive && !constrained && !lowPower
    }
}

/// Only the beginning and end of a progressive file, never a full-file cache.
struct PlaybackStartupBytes {
    struct Chunk {
        let offset: Int64
        let data: Data
        var end: Int64 { offset + Int64(data.count) }
    }
    let length: Int64
    let validator: String?
    let mimeType: String?
    private(set) var head: Data
    private(set) var tail: Chunk?
    var byteCount: Int { head.count + (tail?.data.count ?? 0) }
    init?(head: Data, length: Int64, validator: String?, mimeType: String? = nil) {
        guard length > 0, !head.isEmpty, head.count <= PlaybackWarmupPolicy.headBytes, Int64(head.count) <= length else { return nil }
        self.head = head; self.length = length; self.validator = validator; self.mimeType = mimeType
    }
    mutating func appendHead(_ data: Data, offset: Int64, length: Int64, validator: String?) -> Bool {
        guard length == self.length, validator == self.validator, offset == Int64(head.count),
              !data.isEmpty, data.count <= PlaybackWarmupPolicy.headBytes - head.count,
              Int64(data.count) <= length - offset else { return false }
        head.append(data)
        if let tail, tail.offset < Int64(head.count) { self.tail = nil }
        return true
    }
    mutating func trimHead(to count: Int) {
        if count >= 0, head.count > count { head = head.subdata(in: 0..<count) }
    }
    mutating func appendTail(_ data: Data, offset: Int64, length: Int64, validator: String?) -> Bool {
        guard length == self.length, validator == self.validator, offset >= Int64(head.count),
              !data.isEmpty, data.count <= PlaybackWarmupPolicy.tailBytes,
              offset <= length, Int64(data.count) == length - offset else { return false }
        tail = Chunk(offset: offset, data: data); return true
    }
    func prefix(offset: Int64, count: Int) -> Data {
        guard offset >= 0, count > 0, offset < length else { return Data() }
        if offset < Int64(head.count) {
            let start = Int(offset), end = start + min(count, head.count - start)
            return head.subdata(in: start..<end)
        }
        if let tail, offset >= tail.offset, offset < tail.end {
            let start = Int(offset - tail.offset), end = start + min(count, tail.data.count - start)
            return tail.data.subdata(in: start..<end)
        }
        return Data()
    }
    static func range(_ contentRange: String?, offset: Int64, maximum: Int) -> (length: Int64, bytes: Int)? {
        guard maximum > 0, offset >= 0, let value = contentRange, value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/"), bounds = parts.first?.split(separator: "-") ?? []
        guard parts.count == 2, bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              let length = Int64(parts[1]), start == offset, end >= start, length > end,
              end - start < Int64(maximum) else { return nil }
        return (length, Int(end - start + 1))
    }
}
