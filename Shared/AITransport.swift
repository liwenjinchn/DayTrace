import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum AITransport {
    // Classify provider errors without exposing echoed prompts, credentials, or arbitrary server text.
    static func failureMessage(data: Data, status: Int) -> String {
        let fallback = "服务请求失败（HTTP \(status)）。"
        guard data.count <= 65536,
              let value = try? JSONSerialization.jsonObject(with: data),
              let root = (value as? [String: Any]) ?? (value as? [[String: Any]])?.first,
              let error = root["error"] as? [String: Any] else { return fallback }
        let message = (error["message"] as? String ?? "").lowercased()
        let details = error["details"] as? [[String: Any]] ?? []
        let reasons = details.compactMap { $0["reason"] as? String }
        let hint: String
        if reasons.contains("API_KEY_INVALID") || message.contains("api key not valid") {
            hint = "API 密钥无效，请重新保存该服务的密钥。"
        } else if message.contains("api key was reported as leaked") {
            hint = "Google 已停用被标记为泄露的密钥，请在 AI Studio 更换。"
        } else if (message.contains("user location is not supported") || message.contains("user location not supported")) {
            hint = "Google 不支持当前网络出口所在地区。"
        } else if reasons.contains("API_KEY_SERVICE_BLOCKED") || reasons.contains("API_KEY_HTTP_REFERRER_BLOCKED") || reasons.contains("API_KEY_IP_ADDRESS_BLOCKED") {
            hint = "API 密钥的服务或来源限制拒绝了本次请求。"
        } else if error["status"] as? String == "INVALID_ARGUMENT" {
            hint = "服务判定请求参数无效。"
        } else if status == 429 {
            hint = "服务额度或请求频率达到限制。"
        } else { return fallback }
        return fallback + hint
    }
    static func send(_ request: URLRequest, configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .timedOut {
            throw NSError(domain: NSURLErrorDomain, code: error.code.rawValue, userInfo: [NSLocalizedDescriptionKey: "请求超时，未收到完整响应；服务端可能已处理，请勿连续重复点击。"])
        }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw NSError(domain: "AI", code: 3, userInfo: [NSLocalizedDescriptionKey: failureMessage(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)])
        }
        return data
    }
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct OutboundRequest: Codable, Identifiable {
    var id = UUID()
    var time = Date()
    var service: AIService
    var question: String
    var sources: [SourceExcerpt]
    var memories: [MemoryContext]
    var contexts: [ContextSample]
    var outcome = "结果未知，可能已计费"
    var invalidated = false
}
enum OutboundLog {
    static func load(_ root: URL) throws -> [OutboundRequest] {
        let url = root.appendingPathComponent("outbound-requests.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([OutboundRequest].self, from: Data(contentsOf: url))
    }
    static func save(_ items: [OutboundRequest], root: URL) throws {
        let url = root.appendingPathComponent("outbound-requests.json")
        try JSONEncoder().encode(items).write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    static func begin(_ item: OutboundRequest, root: URL) throws { try save([item] + load(root), root: root) }
    static func finish(_ id: UUID, root: URL) throws {
        var items = try load(root)
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].outcome = "收到可解析响应；是否发布见任务或历史记录" }
        try save(items, root: root)
    }
    static func redact(root: URL, deleted: Set<String>) throws {
        var items = try load(root)
        for i in items.indices where items[i].sources.contains(where: { deleted.contains($0.clipID) }) {
            items[i].sources.removeAll { deleted.contains($0.clipID) }
            items[i].memories = []; items[i].contexts = []; items[i].invalidated = true
        }
        try save(items, root: root)
    }
}
