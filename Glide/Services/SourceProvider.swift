import Foundation
#if DEBUG
@MainActor enum DirectoryRequestQA {
    static var counts: [UUID:Int] = [:]
    static let session=UUID().uuidString
    static func record(_ event: String, sourceID: UUID, videos: Int) {
        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("DirectoryCacheUsage.json")
        var values=((try? Data(contentsOf:file)).flatMap { try? JSONSerialization.jsonObject(with:$0) } as? [[String:Any]]) ?? []
        values.append(["event":event,"videos":videos,"requests":counts[sourceID,default:0],"session":session,"time":ISO8601DateFormatter().string(from:Date()),"build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? ""])
        if let data=try? JSONSerialization.data(withJSONObject:Array(values.suffix(50)),options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:file,options:.atomic) }
    }
}
#endif

/// File sources share browsing and queue construction; catalog sources keep their API semantics.
@MainActor protocol DirectorySourceProvider {
    func entries(server: MediaServer, directory: URL?) async throws -> [DAVEntry]
}

@MainActor struct WebDAVSourceProvider: DirectorySourceProvider {
    func entries(server: MediaServer, directory: URL?) async throws -> [DAVEntry] {
#if DEBUG
        DirectoryRequestQA.counts[server.id,default:0]+=1
#endif
        return try await MediaClient.shared.webDAV(server: server, directory: directory)
    }
}

@MainActor struct LocalSourceProvider: DirectorySourceProvider {
    func entries(server: MediaServer, directory: URL?) async throws -> [DAVEntry] {
        let access = try LocalMediaStore.access(server)
        let relative = try LocalMediaIdentity.relativePath(root: server.address, file: directory ?? server.address)
        let target = try LocalMediaIdentity.fileURL(root: access.root, relativePath: relative)
        let operation = Task.detached {
            defer { withExtendedLifetime(access) {} }
            try Task.checkCancellation()
            return try LocalDirectoryIndex.entries(root: access.root, directory: target)
        }
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
}

@MainActor enum SourceProviders {
    static func directories(for kind: SourceKind) throws -> any DirectorySourceProvider {
        switch kind {
        case .smb: return SMBSourceProvider()
        case .webDAV: return WebDAVSourceProvider()
        case .local: return LocalSourceProvider()
        case .jellyfin, .emby: throw MediaError.message("媒体服务器目录使用媒体库接口。")
        }
    }
}
