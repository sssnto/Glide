import Foundation

struct JellyfinRotationClient {
    private struct Failure:Decodable { let errorCode:String }
    let target:JellyfinRotationTarget
    private func requireSafeServer() async throws {
        let general:JellyfinRotationCapability=try await request("Capabilities")
        guard general.protocolVersion == 1 else { throw JellyfinRotationFailure.code("protocol_unsupported") }
        guard general.available else { throw JellyfinRotationFailure.code(general.reason ?? "permission_denied") }
        guard general.supportsSafePublication else { throw JellyfinRotationFailure.code("plugin_update_required") }
    }
    func capability() async throws -> JellyfinRotationCapability {
        try await requireSafeServer()
        let result:JellyfinRotationCapability=try await request("Items/\(target.itemID)/Rotation",query:["mediaSourceId":target.mediaSourceID])
        guard result.protocolVersion == 1,result.itemId?.lowercased() == target.itemID.lowercased(),
              result.mediaSourceId?.lowercased() == target.mediaSourceID.lowercased(),result.version?.isEmpty == false else {
            throw JellyfinRotationFailure.code("source_changed")
        }
        return result
    }
    func jobs() async throws -> [JellyfinRotationJob] { try await request("Items/\(target.itemID)/Jobs",query:["mediaSourceId":target.mediaSourceID]) }
    func submit(_ body:JellyfinRotationRequest) async throws -> JellyfinRotationJob {
        // Pending POST retries must also refuse the unsafe old plugin.
        try await requireSafeServer()
        return try await request("Jobs",method:"POST",body:JSONEncoder().encode(body))
    }
    func job(_ id:UUID) async throws -> JellyfinRotationJob { try await request("Jobs/\(id.uuidString)") }
    func verify(_ id:UUID) async throws -> JellyfinRotationJob { try await request("Jobs/\(id.uuidString)/Verify",method:"POST") }
    private func request<T:Decodable>(_ path:String,query:[String:String]=[:],method:String="GET",body:Data?=nil) async throws -> T {
        try await Self.request(server:target.server,path:path,query:query,method:method,body:body)
    }
    static func request<T:Decodable>(server:MediaServer,path:String,query:[String:String]=[:],method:String="GET",body:Data?=nil) async throws -> T {
        guard let token=Credentials.read(server.id) else { throw JellyfinRotationFailure.code("permission_denied") }
        let url=ServerURL.endpoint(server.address,"GlideToolkit/"+path,query:query)
        var request=URLRequest(url:url);request.httpMethod=method;request.httpBody=body
        request.setValue(MediaClient.shared.authorization(token,server:server),forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        if body != nil { request.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let (data,response)=try await MediaClient.shared.session.data(for:request)
        guard let http=response as? HTTPURLResponse,data.count<2*1024*1024 else { throw JellyfinRotationFailure.code("invalid_response") }
        if !(200..<300).contains(http.statusCode) {
            let code=(try? JSONDecoder().decode(Failure.self,from:data))?.errorCode
            throw JellyfinRotationFailure.code(code ?? ([404,405].contains(http.statusCode) ? "plugin_missing" : [401,403].contains(http.statusCode) ? "permission_denied" : "server_failed"))
        }
        return try JSONDecoder().decode(T.self,from:data)
    }
}

@MainActor enum JellyfinRotationJournal {
    struct State:Codable { var pending:[JellyfinRotationPending]=[] }
    private static var store:RecoverableStore<State> {
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        return RecoverableStore(file:root.appendingPathComponent("JellyfinRotation/pending-v1.json"))
    }
    static func pending(_ target:JellyfinRotationTarget) throws -> JellyfinRotationPending? { try store.load()?.value.pending.first { $0.matches(target) } }
    static func save(_ pending:JellyfinRotationPending) throws {
        var state=try store.load()?.value ?? State();state.pending.removeAll { $0.sourceID==pending.sourceID && $0.videoID==pending.videoID && $0.request.mediaSourceId==pending.request.mediaSourceId };state.pending.append(pending)
        try store.save(state)
    }
    static func remove(_ target:JellyfinRotationTarget) throws {
        var state=try store.load()?.value ?? State();state.pending.removeAll { $0.matches(target) };try store.save(state)
    }
}
