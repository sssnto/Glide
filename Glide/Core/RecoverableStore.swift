import Foundation

/// Versioned atomic snapshots. Preserve the last decodable snapshot before replacing it.
struct RecoverableStore<Value: Codable> {
    private struct Header: Decodable { var schema: Int }
    private struct Envelope: Codable { var schema: Int; var value: Value }
    private enum StoreError: Error { case unsupportedSchema }
    let file: URL
    var backup: URL { file.appendingPathExtension("backup") }

    func load() throws -> (value: Value, recovered: Bool)? {
        guard FileManager.default.fileExists(atPath: file.path) else {
            if FileManager.default.fileExists(atPath: backup.path) { return (try decode(Data(contentsOf: backup)), true) }
            return nil
        }
        do { return (try decode(Data(contentsOf: file)), false) }
        catch StoreError.unsupportedSchema { throw MediaError.message("本机数据来自更新版本，请更新应用后再使用。") }
        catch {
            guard FileManager.default.fileExists(atPath: backup.path) else { throw error }
            return (try decode(Data(contentsOf: backup)), true)
        }
    }

    func save(_ value: Value) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(schema: 1, value: value))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous = try? Data(contentsOf: file) {
            if let header = try? JSONDecoder().decode(Header.self, from: previous), header.schema != 1 {
                throw MediaError.message("本机数据来自更新版本，已保留原文件。")
            }
            if (try? decode(previous)) != nil {
                if previous == data { return }
                try write(previous, to: backup)
            }
        }
        try write(data, to: file)
    }

    private func decode(_ data: Data) throws -> Value {
        guard try JSONDecoder().decode(Header.self, from: data).schema == 1 else { throw StoreError.unsupportedSchema }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.value
    }
    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
