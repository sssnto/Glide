import UIKit
import AVFoundation

/// Visible tiles only, at most two thumbnail decoders. Reuses the directory index
/// and persists small JPEGs; never downloads a whole movie for a cover.
@MainActor enum WebDAVArtwork {
    private static let gate = ArtworkWorkGate(limit: 2)
    private static var active=0
    private static var folders=0
    private static var misses: [String:Date]=[:]
    private static let compatibilityLibrary = VLCLibrary(options: ["--quiet", "--no-video-title-show"])
    static func clearMisses() { misses.removeAll() }
#if DEBUG
    private(set) static var qaStats: [String:Int] = [:]
    private static var evidence: [[String:Any]]=[]
    private static func record(_ stage: String, count: Int = 0, error: Error? = nil) {
        guard ProcessInfo.processInfo.arguments.contains("--glide-webdav-presentation-fixture") || ProcessInfo.processInfo.arguments.contains("--glide-webdav-artwork-probe") || ProcessInfo.processInfo.arguments.contains("--glide-webdav-artwork-investigate") else { return }
        var value:[String:Any]=["stage":stage,"count":count]
        if let error { value["errorDomain"]=(error as NSError).domain;value["errorCode"]=(error as NSError).code }
        evidence.append(value)
        let file=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("WebDAVArtworkQA.json")
        if let data=try? JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:file,options:.atomic) }
    }
#endif
    static func folder(server: MediaServer,directory: DAVEntry,pixels: Int) async -> UIImage? {
        guard server.kind == .webDAV,DirectoryScope.contains(root:server.address,child:directory.url) else { return nil }
        let identity=DirectoryCacheIdentity(server)
        let key=identity.filename+directory.id
        if let date=misses[key],Date().timeIntervalSince(date)<60 { return nil }
        do {
            while folders>=2 { try await Task.sleep(for:.milliseconds(75)) }
            try Task.checkCancellation();folders+=1;defer { folders-=1 }
            let entries=try await DirectoryCoverCandidates.find(root:directory.url,fetch:{ url in
                if let listing=await DirectoryListingCache.shared.listing(identity,directory:url) { return listing.entries }
                return try await MediaClient.shared.webDAV(server:server,directory:url)
            })
#if DEBUG
            record("candidates",count:entries.count)
#endif
            for entry in entries {
                try Task.checkCancellation()
                if DirectoryScope.isVideo(entry.url) {
                    if let result=await image(server:server,file:entry.url,modified:entry.modifiedAt,pixels:pixels) { return result }
                } else if let result=try? await ArtworkCache.shared.image(server:server,url:entry.url,pixels:pixels,version:entry.modifiedAt.map { String($0.timeIntervalSince1970) } ?? "") { return result }
            }
            misses[key]=Date();if misses.count>200 { misses.removeAll() }
        } catch {
#if DEBUG
            record("folder-failed",error:error)
#endif
        }
        return nil
    }
    static func image(server: MediaServer,file: URL,modified: Date?,pixels: Int) async -> UIImage? {
        guard server.kind == .webDAV, WebDAVPlaybackPolicy.accepts(file:file,root:server.address) else { return nil }
        let identity=DirectoryCacheIdentity(server).filename
        let key="dav-frame-v2:"+identity+file.absoluteString+":"+(modified.map { String($0.timeIntervalSince1970) } ?? "")
        let scope=MediaCache.scope(server)
        if let date=misses[key],Date().timeIntervalSince(date)<60 { return nil }
        do {
            try Task.checkCancellation()
            if let cached=await MediaCache.shared.cachedData(scope:scope,key:key,ttl:7*86400) {
#if DEBUG
                qaStats["cacheHits",default:0]+=1
#endif
                return try await ArtworkCache.shared.image(data:cached,pixels:min(pixels,640))
            }
            // A quick fling should not start decoding every prefetched lazy tile.
            try await Task.sleep(for:.milliseconds(200))
            let permit=try await gate.acquire(key:key)
            defer { Task { await gate.release(permit) } }
            try Task.checkCancellation()
            if let cached=await MediaCache.shared.cachedData(scope:scope,key:key,ttl:7*86400) {
                return try await ArtworkCache.shared.image(data:cached,pixels:min(pixels,640))
            }
            let epoch=await MediaCache.shared.epoch(scope:scope)
            active+=1;defer { active-=1 }
#if DEBUG
            qaStats["generated",default:0]+=1;qaStats["peakActive"]=max(qaStats["peakActive",default:0],active)
#endif
            let data=try await generate(server:server,file:file)
            try Task.checkCancellation()
            try await MediaCache.shared.storeThumbnail(data,scope:scope,key:key,epoch:epoch)
            return try await ArtworkCache.shared.image(data:data,pixels:min(pixels,640))
        } catch {
            if !Task.isCancelled, !(error is CancellationError) { misses[key]=Date();if misses.count>200 { misses.removeAll() } }
#if DEBUG
            record("image-failed",error:error)
#endif
            return nil
        }
    }
    private static func generate(server: MediaServer,file: URL) async throws -> Data {
        let image:CGImage
        if WebDAVPlaybackPolicy.prefersCompatibility(file) { image=try await compatibleFrame(server:server,file:file) }
        else {
            do { image=try await nativeFrame(server:server,file:file) }
            catch {
                try Task.checkCancellation()
                image=try await compatibleFrame(server:server,file:file)
            }
        }
        return try await Task.detached(priority:.utility) {
            guard let data=UIImage(cgImage:image).jpegData(compressionQuality:0.78) else { throw MediaError.message("无法生成视频封面。") }
            return data
        }.value
    }
    private static func nativeFrame(server: MediaServer,file: URL) async throws -> CGImage {
        let loader=AuthenticatedAsset(url:file,headers:["Authorization":MediaClient.shared.basic(server:server)],allowsCellular:PlaybackPreferences.cellularPlayback)
        let generator=AVAssetImageGenerator(asset:loader.asset)
        generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:640,height:640)
        let timeout=Task { try? await Task.sleep(for:.seconds(12));if !Task.isCancelled { generator.cancelAllCGImageGeneration();loader.cancel() } }
        defer { timeout.cancel();generator.cancelAllCGImageGeneration();loader.cancel() }
        let frame=try await withTaskCancellationHandler {
            let duration=try await loader.asset.load(.duration).seconds
            let seconds=duration.isFinite && duration>0 ? min(2,duration*0.1) : 0
            return try await generator.image(at:CMTime(seconds:seconds,preferredTimescale:600))
        } onCancel: { generator.cancelAllCGImageGeneration();Task { @MainActor in loader.cancel() } }
#if DEBUG
        qaStats["nativeFrames",default:0]+=1;record("frame-decoded",count:frame.image.width)
#endif
        try Task.checkCancellation()
        return frame.image
    }
    private static func compatibleFrame(server: MediaServer,file: URL) async throws -> CGImage {
        let bridge=WebDAVPlaybackBridge(url:file,headers:["Authorization":MediaClient.shared.basic(server:server)],allowsCellular:PlaybackPreferences.cellularPlayback)
        defer { bridge.stop() }
        let url=try await bridge.start()
        let extractor=GlideVLCFrameExtractor(library:compatibilityLibrary,url:url)
        let frame:CGImage=try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                extractor.start { image,error in
                    if let image { continuation.resume(returning:image) }
                    else { continuation.resume(throwing:error ?? MediaError.message("无法解码视频预览。")) }
                }
            }
        } onCancel: { extractor.cancel();bridge.stop() }
        try Task.checkCancellation()
#if DEBUG
        qaStats["compatibilityFrames",default:0]+=1;record("compatible-frame-decoded",count:frame.width)
#endif
        return frame
    }
}
