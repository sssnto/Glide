import Foundation
import CryptoKit
import UIKit
import ImageIO

/// Purgeable, account-scoped cache. No tokens or resolved playback URLs are stored as metadata.
actor MediaCache {
    static let shared = MediaCache()
    private let memory = NSCache<NSString, NSData>()
    private var flights: [String: Task<Data, Error>] = [:]
    private var versions: [String: Int] = [:]
    private let root: URL
    init() {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GlideMediaCache-v1")
        memory.totalCostLimit = 32 * 1024 * 1024
    }
    static func scope(_ server: MediaServer) -> String { server.id.uuidString + "-" + server.kind.rawValue + "-" + (server.userID ?? "dav") }
    private func file(scope: String, key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(scope).appendingPathComponent(hash)
    }
    func data(scope: String, key: String, ttl: TimeInterval, refresh: Bool = false, fetch: @escaping () async throws -> Data) async throws -> Data {
        let identity = scope + ":" + key, url = file(scope: scope, key: key)
        if !refresh, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < ttl {
            if let cached = memory.object(forKey: identity as NSString) { return cached as Data }
            if let cached = try? Data(contentsOf: url) { memory.setObject(cached as NSData, forKey: identity as NSString, cost: cached.count); return cached }
        }
        if let flight = flights[identity] { return try await flight.value }
        let version = versions[scope, default: 0]
        let task = Task { try await fetch() }; flights[identity] = task
        defer { flights[identity] = nil }
        let data = try await task.value
        guard version == versions[scope, default: 0] else { throw CancellationError() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if data.count <= 15 * 1024 * 1024 {
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            memory.setObject(data as NSData, forKey: identity as NSString, cost: data.count)
            trim()
        }
        return data
    }
    func clear(server: MediaServer) {
        let scope = Self.scope(server); versions[scope, default: 0] += 1
        for (key, task) in flights where key.hasPrefix(scope + ":") { task.cancel() }
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: root.appendingPathComponent(scope))
    }
    private var lastTrim = Date.distantPast
    private func trim() {
        guard Date().timeIntervalSince(lastTrim) > 60 else { return }; lastTrim = Date()
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var entries: [(URL, Int, Date)] = []; var size = 0
        for case let url as URL in files {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let bytes = v.fileSize ?? 0; size += bytes; entries.append((url, bytes, v.contentModificationDate ?? .distantPast))
        }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where size > 256 * 1024 * 1024 {
            try? FileManager.default.removeItem(at: entry.0); size -= entry.1
        }
    }
}

actor ArtworkCache {
    static let shared = ArtworkCache()
    private let decoded = NSCache<NSString, UIImage>()
    init() { decoded.totalCostLimit = 48 * 1024 * 1024 }
    func image(server: MediaServer, url: URL, pixels: Int, version: String = "") async throws -> UIImage {
        guard ServerURL.sameOrigin(server.address, url) else { throw MediaError.message("图片地址与媒体来源不匹配。") }
        let key = MediaCache.scope(server) + url.absoluteString + version + String(pixels)
        if let value = decoded.object(forKey: key as NSString) { return value }
        guard let credential = Credentials.read(server.id) else { throw MediaError.message("请重新登录。") }
        let data = try await MediaCache.shared.data(scope: MediaCache.scope(server), key: "art:" + url.absoluteString + version, ttl: 7 * 86400) {
            if server.kind == .smb { return try await SMBSourceProvider.image(server: server, url: url) }
            let header = server.kind.isCatalogSource ? MediaClient.shared.authorization(credential, server: server) : MediaClient.shared.basic(server: server, password: credential)
            let data = try await MediaClient.shared.request(url, headers: ["Authorization": header])
            if server.kind == .webDAV && data.count > 16 * 1024 * 1024 { throw MediaError.message("预览图片过大。") }
            return data
        }
        try Task.checkCancellation()
        if let value = decoded.object(forKey: key as NSString) { return value }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw MediaError.message("图片不可用。") }
        let image = UIImage(cgImage: cg)
        decoded.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        return image
    }
    func image(data: Data, pixels: Int) throws -> UIImage {
        try Task.checkCancellation()
        let key = "offline-art:" + String(data.hashValue) + ":" + String(pixels)
        if let value = decoded.object(forKey: key as NSString) { return value }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw MediaError.message("图片不可用。") }
        let image = UIImage(cgImage: cg)
        decoded.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        return image
    }
    func clear() { decoded.removeAllObjects() }
}

extension MediaClient {
    func cached<T: Codable>(_ type: T.Type, server: MediaServer, path: String, query: [String: String] = [:], refresh: Bool = false) async throws -> T {
        guard let token = Credentials.read(server.id) else { throw MediaError.message("请重新登录 \(server.kind.title)。") }
        let url = ServerURL.endpoint(server.address, path, query: query)
        let data = try await MediaCache.shared.data(scope: MediaCache.scope(server), key: "metadata:" + url.absoluteString, ttl: 900, refresh: refresh) {
            let raw = try await self.request(url, headers: ["Authorization": self.authorization(token, server: server)])
            // Decode/re-encode known display fields, excluding server paths and stream credentials.
            return try JSONEncoder().encode(JSONDecoder().decode(T.self, from: raw))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
