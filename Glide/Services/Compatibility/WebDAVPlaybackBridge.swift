import Foundation
import Network

/// A per-input loopback endpoint for libVLC. Credentials stay in URLSession,
/// never in VLC URLs/options, logs, redirects to other origins, or disk files.
/// Range requests stream with backpressure; there is no whole-video download.
final class WebDAVPlaybackBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Glide.webdav.playback")
    private let url: URL
    private let headers: [String: String]
    private let allowsCellular: Bool
    private let path = "/" + UUID().uuidString + "/media"
    private var listener: NWListener?
    private var transfers: [UUID: WebDAVPlaybackTransfer] = [:]
    private var startup: CheckedContinuation<URL, Error>?
    private var stopped = false

    init(url: URL, headers: [String: String], allowsCellular: Bool) {
        self.url = url; self.headers = headers; self.allowsCellular = allowsCellular
    }
    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.stopped else { continuation.resume(throwing: CancellationError()); return }
                    self.startup = continuation
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self] state in
                            guard let self else { return }
                            if case .ready = state, let port = listener.port,
                               let local = URL(string: "http://127.0.0.1:\(port.rawValue)\(self.path)") {
                                self.startup?.resume(returning: local); self.startup = nil
                            } else if case .failed = state { self.shutdown() }
                        }
                        listener.newConnectionHandler = { [weak self] connection in
                            guard let self, !self.stopped, self.transfers.count < 4 else { connection.cancel(); return }
                            let id = UUID()
                            let transfer = WebDAVPlaybackTransfer(connection: connection, queue: self.queue, path: self.path,
                                url: self.url, headers: self.headers, allowsCellular: self.allowsCellular) { [weak self] in
                                    self?.transfers[id] = nil
                                }
                            self.transfers[id] = transfer; transfer.start()
                        }
                        listener.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                            if self?.startup != nil { self?.shutdown() }
                        }
                    } catch { self.startup?.resume(throwing: error); self.startup = nil; self.shutdown() }
                }
            }
        } onCancel: { self.stop() }
    }
    func stop() { queue.async { self.shutdown() } }
    private func shutdown() {
        guard !stopped else { return }; stopped = true
        startup?.resume(throwing: URLError(.cannotConnectToHost)); startup = nil
        listener?.newConnectionHandler = nil; listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        let active = Array(transfers.values); transfers.removeAll(); active.forEach { $0.cancel() }
    }
    deinit { listener?.cancel() }
}

/// All state and delegates run on the bridge's serial queue, outside main.
private final class WebDAVPlaybackTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let path: String
    private let url: URL
    private let headers: [String: String]
    private let allowsCellular: Bool
    private let finished: () -> Void
    private var header = Data()
    private var request: WebDAVBridgeHTTP.Request?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var done = false
    private var responseSent = false
    private var pendingBytes = 0
    private var pendingSends = 0
    private var completed = false
    private var rejecting = false
    init(connection: NWConnection, queue: DispatchQueue, path: String, url: URL, headers: [String: String], allowsCellular: Bool, finished: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.path = path; self.url = url
        self.headers = headers; self.allowsCellular = allowsCellular; self.finished = finished
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
        }
        connection.start(queue: queue); receive()
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.request == nil else { return }; self.cancel()
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - header.count) { [weak self] data, _, ended, error in
            guard let self, !self.done else { return }
            if let data { self.header.append(data) }
            if self.header.range(of: Data("\r\n\r\n".utf8)) != nil {
                guard let parsed = WebDAVBridgeHTTP.request(self.header, path: self.path) else { self.reject(400); return }
                self.request = parsed; self.fetch(parsed)
            } else if ended || error != nil || self.header.count >= 8192 { self.reject(400) }
            else { self.receive() }
        }
    }
    private func fetch(_ parsed: WebDAVBridgeHTTP.Request) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.allowsCellularAccess = allowsCellular; config.timeoutIntervalForRequest = 30
        let delegates = OperationQueue(); delegates.maxConcurrentOperationCount = 1; delegates.underlyingQueue = queue
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegates)
        self.session = session
        var upstream = URLRequest(url: url)
        upstream.httpMethod = parsed.head ? "HEAD" : "GET"
        upstream.allowsCellularAccess = allowsCellular
        headers.forEach { upstream.setValue($1, forHTTPHeaderField: $0) }
        upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        upstream.setValue(parsed.range ?? "bytes=0-", forHTTPHeaderField: "Range")
        task = session.dataTask(with: upstream); task?.resume()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Keep both TLS validation and the existing no-cross-origin credential rule.
        guard let next = request.url, ServerURL.sameOrigin(url, next), next.user == nil, next.password == nil else { completionHandler(nil); return }
        var request = request; headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(self.request?.range ?? "bytes=0-", forHTTPHeaderField: "Range")
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !done, let http = response as? HTTPURLResponse, let request else { completionHandler(.cancel); cancel(); return }
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? response.expectedContentLength
        let range = http.value(forHTTPHeaderField: "Content-Range")
        guard WebDAVBridgeHTTP.validResponse(status: http.statusCode, range: request.range ?? "bytes=0-", contentRange: range, length: length),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            completionHandler(.cancel); reject([401, 403, 404, 416].contains(http.statusCode) ? http.statusCode : 502); return
        }
        var fields = ["Connection": "close", "Cache-Control": "no-store"]
        if length >= 0 { fields["Content-Length"] = String(length) }
        if let range { fields["Content-Range"] = range }
        if http.statusCode == 206 || http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes" { fields["Accept-Ranges"] = "bytes" }
        if let mime = http.mimeType, mime.utf8.allSatisfy({ (32...126).contains($0) }) { fields["Content-Type"] = mime }
        responseSent = true
        let text = "HTTP/1.1 \(http.statusCode) OK\r\n" + fields.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, !self.done, error == nil else { completionHandler(.cancel); self?.cancel(); return }
            completionHandler(.allow)
        })
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !done, !rejecting else { return }
        // Suspend for each queued send; resume balances each suspend. Also bound
        // queued callbacks in case a URLSession implementation has read ahead.
        guard pendingBytes + data.count <= 2 * 1024 * 1024 else { cancel(); return }
        pendingBytes += data.count; pendingSends += 1; dataTask.suspend()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.done else { return }
            self.pendingBytes -= data.count; self.pendingSends -= 1
            if error != nil { self.cancel() }
            else if self.completed && self.pendingSends == 0 { self.finishResponse() }
            else { dataTask.resume() }
        })
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !done, !rejecting else { return }
        if error != nil { if responseSent { cancel() } else { reject(502) }; return }
        completed = true
        if pendingSends == 0 { finishResponse() }
    }
    private func finishResponse() {
        connection.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.cancel() })
    }
    private func reject(_ status: Int) {
        guard !done, !rejecting else { return }; rejecting = true
        responseSent = true; task?.cancel()
        connection.send(content: Data("HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), isComplete: true,
            completion: .contentProcessed { [weak self] _ in self?.cancel() })
    }
    func cancel() {
        guard !done else { return }; done = true
        task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil
        connection.stateUpdateHandler = nil; connection.cancel(); finished()
    }
}
