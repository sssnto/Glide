import Foundation

/// SFNT name tables carry aliases in several languages. CoreText's preferred
/// family/name attributes alone do not expose all names used by ASS authors.
enum FontNameTable {
    static func names(_ data: Data) -> Set<String> {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }
        guard let format = u16(0), format <= 1, let count = u16(2), count <= 4096,
              let strings = u16(4), strings >= 6 + count * 12, strings <= bytes.count,
              6 + count * 12 <= bytes.count else { return [] }
        var names = Set<String>()
        for index in 0..<count {
            let start = 6 + index * 12
            guard let platform = u16(start), let nameID = u16(start + 6), [1, 4, 6, 16, 21].contains(nameID),
                  let length = u16(start + 8), let offset = u16(start + 10), length > 0,
                  strings + offset + length <= bytes.count else { continue }
            let encoding: String.Encoding
            switch platform { case 0, 3: encoding = .utf16BigEndian; case 1: encoding = .macOSRoman; default: continue }
            let value = Data(bytes[(strings + offset)..<(strings + offset + length)])
            guard let name = String(data: value, encoding: encoding)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)), !name.isEmpty else { continue }
            names.insert(name)
        }
        return names
    }
}
