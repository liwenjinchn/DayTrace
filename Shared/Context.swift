import Foundation

enum ContextCategory: String, Codable { case health, location }
struct ContextSample: Codable, Equatable, Identifiable {
    var id: String
    var category: ContextCategory
    var label: String
    var value: String
    var start: Date
    var end: Date
    var origin: String
}
struct ContextConsent: Codable, Equatable {
    var service: AIService
    var health: Bool
    var location: Bool
}
struct ContextState: Codable {
    var samples: [ContextSample] = []
    var consent: ContextConsent? = nil
}
enum ContextRules {
    static func select(_ samples: [ContextSample], sources: [SourceExcerpt], consent: ContextConsent?, service: AIService) -> [ContextSample] {
        guard let consent, consent.service == service else { return [] }
        return samples.filter { sample in
            (sample.category == .health ? consent.health : consent.location) && sources.contains {
                let time = $0.started.addingTimeInterval($0.offset)
                return time >= sample.start && time < sample.end
            }
        }.sorted { $0.id < $1.id }.prefix(32).map { $0 }
    }
    static func load(_ root: URL) throws -> ContextState {
        let url = root.appendingPathComponent("context.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ContextState() }
        let state = try JSONDecoder().decode(ContextState.self, from: Data(contentsOf: url))
        guard state.samples.allSatisfy({ $0.start < $0.end && $0.value.count <= 300 && $0.label.count <= 100 }) else { throw ArchiveFailure.invalidClip }
        return state
    }
    static func save(_ state: ContextState, root: URL) throws {
        let url = root.appendingPathComponent("context.json")
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
