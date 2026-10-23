import Foundation

/// File sources share browsing and queue construction; catalog sources keep their API semantics.
@MainActor protocol DirectorySourceProvider {
    func entries(server: MediaServer, directory: URL?) async throws -> [DAVEntry]
}

@MainActor struct WebDAVSourceProvider: DirectorySourceProvider {
    func entries(server: MediaServer, directory: URL?) async throws -> [DAVEntry] {
        try await MediaClient.shared.webDAV(server: server, directory: directory)
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
