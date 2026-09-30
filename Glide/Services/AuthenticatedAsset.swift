import AVFoundation
import UniformTypeIdentifiers

/// Public resource-loader API for authenticated progressive WebDAV playback.
/// Each AVFoundation byte-range request streams incrementally; the full movie is never buffered in RAM.
final class AuthenticatedAsset: NSObject, AVAssetResourceLoaderDelegate {
    let asset: AVURLAsset
    private let remoteURL: URL
    private let headers: [String: String]
    private let allowsCellular: Bool
    private var transfers: [ObjectIdentifier: RangeTransfer] = [:]
    init(url: URL, headers: [String: String], allowsCellular: Bool = true) {
        self.allowsCellular = allowsCellular
        remoteURL = url
        self.headers = headers
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = "glide-dav"
        asset = AVURLAsset(url: components.url!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: .main)
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(request)
        let transfer = RangeTransfer(url: remoteURL, headers: headers, allowsCellular: allowsCellular, loading: request) { [weak self] in self?.transfers.removeValue(forKey: key) }
        transfers[key] = transfer
        transfer.start()
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        transfers.removeValue(forKey: ObjectIdentifier(request))?.cancel()
    }
    func cancel() { let current = transfers.values; transfers.removeAll(); current.forEach { $0.cancel() } }
    deinit { transfers.values.forEach { $0.cancel() } }
}

private final class RangeTransfer: NSObject, URLSessionDataDelegate {
    let url: URL
    let headers: [String: String]
    let allowsCellular: Bool
    let loading: AVAssetResourceLoadingRequest
    let completion: () -> Void
    var session: URLSession?
    var task: URLSessionDataTask?
    var offset: Int64 = 0
    var finished = false
    init(url: URL, headers: [String: String], allowsCellular: Bool, loading: AVAssetResourceLoadingRequest, completion: @escaping () -> Void) {
        self.url = url; self.headers = headers; self.allowsCellular = allowsCellular; self.loading = loading; self.completion = completion
    }
    func start() {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = allowsCellular
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let data = loading.dataRequest {
            offset = max(data.requestedOffset, data.currentOffset)
            let end = data.requestedOffset + Int64(data.requestedLength) - 1
            request.setValue(data.requestsAllDataToEndOfResource ? "bytes=\(offset)-" : "bytes=\(offset)-\(max(offset, end))", forHTTPHeaderField: "Range")
        } else { request.setValue("bytes=0-1", forHTTPHeaderField: "Range") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        task = session?.dataTask(with: request)
        task?.resume()
    }
    func cancel() { guard !finished else { return }; finished = true; task?.cancel(); session?.invalidateAndCancel(); session = nil }
    func finish(_ error: Error? = nil) {
        guard !finished else { return }
        finished = true
        if let error { loading.finishLoading(with: error) } else { loading.finishLoading() }
        task?.cancel(); session?.invalidateAndCancel(); session = nil
        completion()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else {
            completionHandler(.cancel); finish(MediaError.message("NAS 视频请求失败，请检查凭据和文件权限。")); return
        }
        guard offset == 0 || http.statusCode == 206 else {
            completionHandler(.cancel); finish(MediaError.message("此 WebDAV 服务器不支持视频分段读取，请改用 Jellyfin。")); return
        }
        if let info = loading.contentInformationRequest {
            let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int64($0) }
            info.contentLength = total ?? response.expectedContentLength
            info.isByteRangeAccessSupported = http.statusCode == 206 || http.value(forHTTPHeaderField: "Accept-Ranges") == "bytes"
            info.contentType = UTType(filenameExtension: url.pathExtension)?.identifier ?? response.mimeType.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.movie.identifier
        }
        completionHandler(.allow)
        if loading.dataRequest == nil { finish() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, let request = loading.dataRequest else { return }
        let remaining = request.requestedOffset + Int64(request.requestedLength) - request.currentOffset
        if request.requestsAllDataToEndOfResource { request.respond(with: data) }
        else if remaining > 0 { request.respond(with: data.prefix(Int(min(Int64(data.count), remaining)))) }
        if !request.requestsAllDataToEndOfResource, request.currentOffset >= request.requestedOffset + Int64(request.requestedLength) { finish() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url, ServerURL.sameOrigin(url, next) else { completionHandler(nil); return }
        var request = request
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        completionHandler(request)
    }
}
