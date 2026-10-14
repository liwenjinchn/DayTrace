import Foundation
import Security

enum KeyVault {
    static let service = "dev.daytrace.api"
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "provider"] }
    private struct Credential: Codable { var endpoint: String; var key: String }
    private static func raw() -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }
    // Legacy keys can be shown in the secure settings field for explicit rebinding,
    // but are never used by a request until saved for this exact endpoint.
    static func load() -> String {
        guard let data = raw() else { return "" }
        return (try? JSONDecoder().decode(Credential.self, from: data).key) ?? String(data: data, encoding: .utf8) ?? ""
    }
    static func load(endpoint: String) -> String {
        guard let data = raw(), let stored = try? JSONDecoder().decode(Credential.self, from: data), stored.endpoint == endpoint else { return "" }
        return stored.key
    }
    static func save(_ value: String, endpoint: String = "") throws {
        if value.isEmpty { let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }; return }
        try AIService(endpoint: endpoint, model: "credential-binding").validate()
        let data = try JSONEncoder().encode(Credential(endpoint: endpoint, key: value))
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil); guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    static func failure(_ code: OSStatus) -> Error { NSError(domain: "Keychain", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Unable to save API credential (\(code))."]) }
}

@MainActor struct AIClient {
    var endpoint: String
    var model: String
    var auditRoot: URL? = nil
    func ask(_ question: String, sources: [SourceExcerpt], memories: [MemoryContext] = [], contexts: [ContextSample] = []) async throws -> GroundedAnswer {
        try await askWithUsage(question, sources: sources, contexts: contexts, memories: memories).answer
    }
    func askWithUsage(_ question: String, sources: [SourceExcerpt], generateMemories: Bool = false, generateHighlights: Bool = false, contexts: [ContextSample] = [], memories: [MemoryContext] = []) async throws -> AIReply {
        let request = try AIWire.request(service: AIService(endpoint: endpoint, model: model),
            key: KeyVault.load(endpoint: endpoint), question: question, sources: sources, generateMemories: generateMemories, generateHighlights: generateHighlights, contexts: contexts, memories: memories)
        let audit = OutboundRequest(service: AIService(endpoint: endpoint, model: model), question: question, sources: sources, memories: memories, contexts: contexts)
        if let auditRoot { try OutboundLog.begin(audit, root: auditRoot) }
        let data = try await AITransport.send(request)
        try Task.checkCancellation()
        let reply = try AIWire.decode(data, sources: sources, generateMemories: generateMemories, generateHighlights: generateHighlights)
        if let auditRoot { try OutboundLog.finish(audit.id, root: auditRoot) }
        return reply
    }
}
