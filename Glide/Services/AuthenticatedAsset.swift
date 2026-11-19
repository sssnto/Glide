import AVFoundation
import UniformTypeIdentifiers

/// Public resource-loader API for authenticated progressive WebDAV playback.
/// Each AVFoundation byte-range request streams incrementally; the full movie is never buffered in RAM.
final class AuthenticatedAsset: NSObject, AVAssetResourceLoaderDelegate {
    let asset: AVURLAsset
    private let remoteURL: URL
    private let headers: [String: String]
    private var allowsCellular: Bool
    private var transfers: [ObjectIdentifier: RangeTransfer] = [:]
    private var startup: PlaybackStartupBytes?
    var startupByteCount: Int { startup?.byteCount ?? 0 }
    var startupInfo: (length: Int64, validator: String?, headBytes: Int)? {
        startup.map { ($0.length, $0.validator, $0.head.count) }
    }
    func setAllowsCellular(_ value: Bool) { allowsCellular = value }
    func appendStartupHead(_ data: Data, offset: Int64, length: Int64, validator: String?) {
        _ = startup?.appendHead(data, offset: offset, length: length, validator: validator)
    }
    func trimStartupHead(to count: Int) { startup?.trimHead(to: count) }
    func appendStartupTail(_ data: Data, offset: Int64, length: Int64, validator: String?) {
        _ = startup?.appendTail(data, offset: offset, length: length, validator: validator)
    }
    init(url: URL, headers: [String: String], allowsCellular: Bool = true, startup: PlaybackStartupBytes? = nil) {
        self.startup = startup
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
        if let startup {
            if let info = request.contentInformationRequest {
                info.contentLength = startup.length; info.isByteRangeAccessSupported = true
                info.contentType = startup.mimeType.flatMap { UTType(mimeType: $0)?.identifier }
                    ?? UTType(filenameExtension: remoteURL.pathExtension)?.identifier ?? UTType.movie.identifier
            }
            if let data = request.dataRequest {
                let offset = max(data.requestedOffset, data.currentOffset)
                let end = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
                let requestedEnd = end.overflow ? Int64.max : end.partialValue
                let wantedEnd = data.requestsAllDataToEndOfResource ? startup.length : min(startup.length, requestedEnd)
                let remaining = max(0, wantedEnd - offset)
                let bytes = startup.prefix(offset: offset, count: Int(min(Int64(Int.max), max(0, remaining))))
                if !bytes.isEmpty { data.respond(with: bytes) }
                if data.currentOffset >= startup.length || (!data.requestsAllDataToEndOfResource && data.currentOffset >= requestedEnd) {
                    request.finishLoading(); return true
                }
            } else { request.finishLoading(); return true }
        }
        let key = ObjectIdentifier(request)
        let transfer = RangeTransfer(url: remoteURL, headers: headers, allowsCellular: allowsCellular, loading: request, startup: startup) { [weak self] in self?.transfers.removeValue(forKey: key) }
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
    let startup: PlaybackStartupBytes?
    var session: URLSession?
    var task: URLSessionDataTask?
    var offset: Int64 = 0
    var finished = false
    init(url: URL, headers: [String: String], allowsCellular: Bool, loading: AVAssetResourceLoadingRequest, startup: PlaybackStartupBytes?, completion: @escaping () -> Void) {
        self.url = url; self.headers = headers; self.allowsCellular = allowsCellular; self.loading = loading; self.startup = startup; self.completion = completion
    }
    func start() {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = allowsCellular
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let validator = startup?.validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let data = loading.dataRequest {
            offset = max(data.requestedOffset, data.currentOffset)
            let total = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
            let end = total.overflow ? Int64.max : total.partialValue - 1
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
        if let startup {
            let range = PlaybackStartupBytes.range(http.value(forHTTPHeaderField: "Content-Range"), offset: offset, maximum: Int.max)
            let validator = Self.validator(http)
            guard http.statusCode == 206, range?.length == startup.length,
                  startup.validator == nil || validator == startup.validator,
                  http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
                completionHandler(.cancel); finish(MediaError.message("预加载后视频文件已变化，请重新打开。")); return
            }
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
    static func validator(_ response: HTTPURLResponse) -> String? {
        if let etag = response.value(forHTTPHeaderField: "ETag"), !etag.hasPrefix("W/") { return etag }
        return response.value(forHTTPHeaderField: "Last-Modified")
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, let request = loading.dataRequest else { return }
        let total = request.requestedOffset.addingReportingOverflow(Int64(request.requestedLength))
        let end = total.overflow ? Int64.max : total.partialValue
        let remaining = max(0, end - request.currentOffset)
        if request.requestsAllDataToEndOfResource { request.respond(with: data) }
        else if remaining > 0 { request.respond(with: data.prefix(Int(min(Int64(data.count), remaining)))) }
        if !request.requestsAllDataToEndOfResource, request.currentOffset >= end { finish() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url, ServerURL.sameOrigin(url, next) else { completionHandler(nil); return }
        var request = request
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        completionHandler(request)
    }
}

/// A speculative request has a strict response/body limit even if the server ignores Range.
final class StartupRangeRead: NSObject, URLSessionDataDelegate {
    struct Result { let data: Data; let length: Int64; let validator: String?; let mimeType: String? }
    private let url: URL
    private let headers: [String: String]
    private let offset: Int64
    private let count: Int
    private let validator: String?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Result, Error>?
    private var body = Data()
    private var response: HTTPURLResponse?
    private var expected: (length: Int64, bytes: Int)?
    private var finished = false
    private init(url: URL, headers: [String: String], offset: Int64, count: Int, validator: String?) {
        self.url = url; self.headers = headers; self.offset = offset; self.count = count; self.validator = validator
    }
    @MainActor static func fetch(url: URL, headers: [String: String], offset: Int64, count: Int, validator: String? = nil) async throws -> Result {
        let operation = StartupRangeRead(url: url, headers: headers, offset: offset, count: count, validator: validator)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operation.continuation = continuation; operation.start()
            }
        } onCancel: { DispatchQueue.main.async { operation.finish(.failure(CancellationError())) } }
    }
    private func start() {
        guard !finished else { continuation?.resume(throwing: CancellationError()); continuation = nil; return }
        var request = URLRequest(url: url)
        request.allowsCellularAccess = false; request.allowsExpensiveNetworkAccess = false; request.allowsConstrainedNetworkAccess = false
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4; configuration.timeoutIntervalForResource = PlaybackWarmupPolicy.requestDeadline
        configuration.allowsCellularAccess = false; configuration.allowsExpensiveNetworkAccess = false; configuration.allowsConstrainedNetworkAccess = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        task = session?.dataTask(with: request); task?.resume()
    }
    private func finish(_ result: Swift.Result<Result, Error>) {
        guard !finished else { return }; finished = true
        let continuation = continuation; self.continuation = nil
        task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let range = PlaybackStartupBytes.range(http.value(forHTTPHeaderField: "Content-Range"), offset: offset, maximum: count),
              response.expectedContentLength < 0 || response.expectedContentLength == Int64(range.bytes),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
              validator == nil || RangeTransfer.validator(http) == validator else {
            completionHandler(.cancel); finish(.failure(URLError(.badServerResponse))); return
        }
        expected = range; self.response = http; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished, let expected, data.count <= expected.bytes - body.count else { finish(.failure(URLError(.dataLengthExceedsMaximum))); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        guard let expected, let response, body.count == expected.bytes else { finish(.failure(URLError(.badServerResponse))); return }
        finish(.success(Result(data: body, length: expected.length, validator: RangeTransfer.validator(response), mimeType: response.mimeType)))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url, ServerURL.sameOrigin(url, next) else { completionHandler(nil); return }
        var nextRequest = request
        headers.forEach { nextRequest.setValue($1, forHTTPHeaderField: $0) }
        nextRequest.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        nextRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let validator { nextRequest.setValue(validator, forHTTPHeaderField: "If-Range") }
        nextRequest.allowsCellularAccess = false; nextRequest.allowsConstrainedNetworkAccess = false; nextRequest.allowsExpensiveNetworkAccess = false
        completionHandler(nextRequest)
    }
}
