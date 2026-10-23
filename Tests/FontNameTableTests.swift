import Foundation
import Testing
@testable import GlideCore

struct FontNameTableTests {
    private func fixture() -> Data {
        let values = [(1, "文泉驿微米黑"), (1, "WenQuanYi Micro Hei"), (6, "WenQuanYiMicroHei"), (2, "Regular")]
        var header = Data(), strings = Data()
        func word(_ value: Int, to data: inout Data) { data.append(UInt8((value >> 8) & 255)); data.append(UInt8(value & 255)) }
        word(0, to: &header); word(values.count, to: &header); word(6 + values.count * 12, to: &header)
        for (id, name) in values {
            let bytes = name.data(using: .utf16BigEndian)!
            for value in [3, 1, 0x804, id, bytes.count, strings.count] { word(value, to: &header) }
            strings.append(bytes)
        }
        header.append(strings); return header
    }
    @Test func includesChineseAndEnglishAliasesWithoutTreatingStyleAsFamily() {
        #expect(FontNameTable.names(fixture()) == ["文泉驿微米黑", "WenQuanYi Micro Hei", "WenQuanYiMicroHei"])
    }
    @Test func incompleteOrCorruptTablesDoNotReadOutsideData() {
        let valid = fixture()
        for size in 0..<valid.count { _ = FontNameTable.names(valid.prefix(size)) }
        #expect(FontNameTable.names(Data(repeating: 255, count: 200)).isEmpty)
        #expect(FontNameTable.names(Data()).isEmpty)
    }
}
