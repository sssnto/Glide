import Foundation
import Testing
@testable import GlideCore

@Test func smbLocationsKeepCredentialsOutAndSpecialNamesRoundTrip() throws {
    let url = try SMBLocation.parse(address: "192.168.1.10:1445", share: "家庭 视频/电影 #100%")
    let root = try SMBLocation(url)
    #expect(root.host == "192.168.1.10:1445")
    #expect(root.share == "家庭 视频")
    #expect(root.path == "电影 #100%")
    let child = try root.child("片段 # %25 中文.mkv", directory: false)
    #expect(try root.relativePath(child) == "电影 #100%/片段 # %25 中文.mkv")
    #expect(child.query == nil && child.fragment == nil && child.user == nil && child.password == nil)
    #expect(DirectoryScope.contains(root: url, child: child))
    #expect(try SMBLocation.parse(address: "SMB://NAS:445/media/") == SMBLocation.parse(address: "nas", share: "media"))
    #expect(try SMBLocation(SMBLocation.parse(address: "smb://[::1]:1445", share: "media")).host == "[::1]:1445")
    #expect(ServerURL.sameOrigin(URL(string: "smb://nas/media")!, URL(string: "smb://nas:445/media/a.jpg")!))
}

@Test func smbRejectsTraversalCrossShareAndAccountURLs() throws {
    for address in ["smb://u:pw@host/media", "smb://host/media?pw=secret", "smb://host/media#secret", "smb://host/media/%2e%2e", "smb://host/media/%2Fother", "smb://host/media/%5Cother", "smb://host", "https://host/media"] {
        #expect(throws: (any Error).self) { _ = try SMBLocation(URL(string: address)!) }
    }
    let root = try SMBLocation(SMBLocation.parse(address: "HOST", share: "media/private"))
    for child in ["smb://host/other/private/movie.mp4", "smb://other/media/private/movie.mp4", "smb://host:1445/media/private/movie.mp4", "smb://host/media/private2/movie.mp4"] {
        #expect(throws: (any Error).self) { _ = try root.relativePath(URL(string: child)!) }
    }
    #expect(try root.relativePath(URL(string: "smb://host:445/media/private/movie.mp4")!) == "private/movie.mp4")
}

@Test func smbConfigurationMigratesOldSourcesAndKeepsIdentitySeparate() throws {
    let id = UUID()
    let legacy = Data("{\"id\":\"\(id)\",\"name\":\"NAS\",\"kind\":\"webDAV\",\"address\":\"https://nas/video\",\"username\":\"alice\"}".utf8)
    let old = try JSONDecoder().decode(MediaServer.self, from: legacy)
    #expect(old.kind == .webDAV && old.smb == nil)
    #expect(old.remembersPlayback == nil)
    let source = MediaServer(name: "NAS", kind: .smb, address: try SMBLocation.parse(address: "nas", share: "video"), username: "alice", smb: SMBOptions(guest: false, domain: "HOME", encrypted: true), remembersPlayback: true)
    let data = try JSONEncoder().encode(source)
    #expect(try JSONDecoder().decode(MediaServer.self, from: data) == source)
    #expect(SourceKind.smb.capabilities.contains(.recursiveQueue))
    #expect(!String(decoding: data, as: UTF8.self).contains("password"))
    #expect(DirectoryBookmark(sourceID: source.id, name: "Video", jellyPath: [], davPath: [source.address]).id != DirectoryBookmark(sourceID: UUID(), name: "Video", jellyPath: [], davPath: [source.address]).id)
}

@Test func onlyTypedSMBResourcesEnterNetworkCompatibilityRoute() {
    #expect(PlaybackEngineSelection.resolve(preferred: .avPlayer, localFile: false, hasHeaders: false, smb: true) == .vlc)
    #expect(PlaybackEngineSelection.resolve(preferred: .vlc, localFile: false, hasHeaders: true, smb: true) == .avPlayer)
    #expect(PlaybackEngineSelection.resolve(preferred: .vlc, localFile: false, hasHeaders: false) == .avPlayer)
}
