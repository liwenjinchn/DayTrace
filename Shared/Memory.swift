import Foundation
import CryptoKit

enum MemoryCategory: String, Codable, CaseIterable {
    case person, preference, plan, fact
    var label: String { switch self { case .person: return "人物"; case .preference: return "偏好"; case .plan: return "计划"; case .fact: return "事实" } }
}
enum MemorySubject: String, Codable {
    case record, user, other, unknown
    var label: String { switch self { case .record: return "录音中的陈述"; case .user: return "关于本人"; case .other: return "关于他人"; case .unknown: return "主体不明" } }
}
struct MemoryEvidence: Codable, Equatable { var sourceID: String; var quote: String }
struct MemoryCandidate: Codable, Equatable {
    var content: String
    var topic: String
    var category: MemoryCategory
    var subject: MemorySubject
    var uncertain: Bool
    var evidence: [MemoryEvidence]
}
struct MemoryRevision: Codable, Equatable {
    var content: String
    var changedAt: Date
}
struct PersonalMemory: Codable, Equatable, Identifiable {
    enum Status: String, Codable, CaseIterable {
        case active, needsReview, disabled, sourceMissing
        var label: String {
            switch self { case .active: return "生效中"; case .needsReview: return "待核实"; case .disabled: return "已停用"; case .sourceMissing: return "来源已失效" }
        }
    }
    var id = UUID()
    var content: String
    var topic: String
    var category: MemoryCategory
    var subject: MemorySubject
    var sources: [SourceExcerpt]
    var status: Status
    var created: Date
    var updated: Date
    var userEdited = false
    var revision = 1
    var history: [MemoryRevision] = []
    var lostSourceIDs: [String] = []
    var contentKey: String
    var topicKey: String
}
struct MemoryContext: Codable, Equatable, Identifiable {
    var id: UUID
    var content: String
    var revision: Int
    var subject: MemorySubject
    var userEdited: Bool
    var sourceIDs: [String]
}
struct MemoryState: Codable, Equatable {
    var schemaVersion = 1
    var items: [PersonalMemory] = []
    var appliedJobs: Set<UUID> = []
    // Suppress at source-excerpt granularity, not a model's mutable paraphrase/ID.
    // Hashes allow a deleted memory's wording to be removed from the library.
    var blockedSourceIDs: Set<String> = []
    var blockedContentKeys: Set<String> = []
    var blockedTopicKeys: Set<String> = []
}

enum MemoryRules {
    static func normalized(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }
    static func key(_ value: String) -> String { SHA256.hash(data: Data(normalized(value).utf8)).map { String(format: "%02x", $0) }.joined() }
    static func topicKey(_ candidate: MemoryCandidate) -> String { key(candidate.subject.rawValue + ":" + candidate.category.rawValue + ":" + candidate.topic) }
    static func valid(_ candidate: MemoryCandidate, sources: [SourceExcerpt]) -> Bool {
        guard (1...600).contains(candidate.content.trimmingCharacters(in: .whitespacesAndNewlines).count),
              (1...80).contains(candidate.topic.trimmingCharacters(in: .whitespacesAndNewlines).count),
              !candidate.evidence.isEmpty, candidate.evidence.count <= 8,
              Set(candidate.evidence.map(\.sourceID)).count == candidate.evidence.count else { return false }
        return candidate.evidence.allSatisfy { evidence in
            let quote = normalized(evidence.quote)
            return quote.count >= 4 && sources.contains { $0.id == evidence.sourceID && normalized($0.text).contains(quote) }
        }
    }
    static func ingest(_ candidates: [MemoryCandidate], jobID: UUID, sources: [SourceExcerpt],
                       into state: MemoryState, now: Date) -> MemoryState {
        guard !state.appliedJobs.contains(jobID) else { return state }
        var next = state
        for candidate in candidates.prefix(12) where valid(candidate, sources: sources) {
            let contentKey = key(candidate.content); let topicKey = topicKey(candidate)
            let ids = Set(candidate.evidence.map(\.sourceID))
            guard ids.isDisjoint(with: next.blockedSourceIDs), !next.blockedContentKeys.contains(contentKey),
                  !next.blockedTopicKeys.contains(topicKey) else { continue }
            let evidence = sources.filter { ids.contains($0.id) }
            if let i = next.items.firstIndex(where: { $0.contentKey == contentKey && $0.subject == candidate.subject }) {
                // An exact duplicate may add provenance, never replace user decisions.
                if !next.items[i].userEdited && (next.items[i].status == .active || next.items[i].status == .needsReview) {
                    let before = next.items[i]
                    for source in evidence where !next.items[i].sources.contains(where: { $0.id == source.id }) { next.items[i].sources.append(source) }
                    if candidate.uncertain { next.items[i].status = .needsReview }
                    if next.items[i] != before { next.items[i].revision += 1; next.items[i].updated = now }
                }
                continue
            }
            let conflicts = next.items.indices.filter { next.items[$0].topicKey == topicKey && next.items[$0].contentKey != contentKey && next.items[$0].status != .disabled }
            for i in conflicts where !next.items[i].userEdited && next.items[i].status == .active {
                next.items[i].status = .needsReview; next.items[i].revision += 1; next.items[i].updated = now
            }
            // No trusted speaker identity is available. Only source-level observations
            // can be active automatically; claims about a person require confirmation.
            let active = candidate.subject == .record && !candidate.uncertain && conflicts.isEmpty
            next.items.append(PersonalMemory(content: candidate.content, topic: candidate.topic, category: candidate.category,
                subject: candidate.subject, sources: evidence, status: active ? .active : .needsReview,
                created: now, updated: now, contentKey: contentKey, topicKey: topicKey))
        }
        next.appliedJobs.insert(jobID)
        return next
    }
    private static func protect(_ item: PersonalMemory, in state: inout MemoryState) {
        state.blockedSourceIDs.formUnion(item.sources.map(\.id)); state.blockedSourceIDs.formUnion(item.lostSourceIDs)
        state.blockedContentKeys.insert(item.contentKey); state.blockedContentKeys.insert(key(item.content))
        state.blockedTopicKeys.insert(item.topicKey)
    }
    static func edit(_ id: UUID, content: String, in state: MemoryState, now: Date) throws -> MemoryState {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...600).contains(text.count), let i = state.items.firstIndex(where: { $0.id == id }) else { throw ArchiveFailure.invalidSources }
        var next = state; protect(next.items[i], in: &next)
        next.items[i].history.append(MemoryRevision(content: next.items[i].content, changedAt: now))
        next.items[i].content = text; next.items[i].userEdited = true
        next.items[i].revision += 1; next.items[i].updated = now
        next.blockedContentKeys.insert(key(text))
        return next
    }
    static func setStatus(_ id: UUID, active: Bool, in state: MemoryState, now: Date) throws -> MemoryState {
        guard let i = state.items.firstIndex(where: { $0.id == id }), !active || !state.items[i].sources.isEmpty else { throw ArchiveFailure.invalidSources }
        var next = state; protect(next.items[i], in: &next)
        next.items[i].status = active ? .active : .disabled
        // Explicit confirmation, like an edit, takes priority over future generation.
        next.items[i].userEdited = true; next.items[i].revision += 1; next.items[i].updated = now
        return next
    }
    static func delete(_ id: UUID, from state: MemoryState) -> MemoryState {
        guard let item = state.items.first(where: { $0.id == id }) else { return state }
        var next = state; protect(item, in: &next); next.items.removeAll { $0.id == id }
        return next
    }
    static func reconcile(_ state: MemoryState, current: [SourceExcerpt], deleted: Set<String>) -> MemoryState {
        var next = state
        for i in next.items.indices {
            let lost = next.items[i].sources.filter { deleted.contains($0.clipID) || !current.contains($0) }
            guard !lost.isEmpty else { continue }
            protect(next.items[i], in: &next)
            let lostIDs = Set(lost.map(\.id))
            next.items[i].lostSourceIDs = Array(Set(next.items[i].lostSourceIDs).union(lostIDs)).sorted()
            next.items[i].sources.removeAll { lostIDs.contains($0.id) }
            if next.items[i].status != .disabled {
                next.items[i].status = next.items[i].sources.isEmpty ? .sourceMissing : .needsReview
            }
            next.items[i].revision += 1
        }
        return next
    }
    static func contexts(_ state: MemoryState, sources: [SourceExcerpt]) -> [MemoryContext] {
        state.items.filter { item in
            item.status == .active && !item.sources.isEmpty && item.sources.allSatisfy { sources.contains($0) }
        }.prefix(8).map { MemoryContext(id: $0.id, content: $0.content, revision: $0.revision, subject: $0.subject,
                                      userEdited: $0.userEdited, sourceIDs: $0.sources.map(\.id)) }
    }
}

enum MemoryDisk {
    static func load(from root: URL) throws -> MemoryState {
        let url = root.appendingPathComponent("memories.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return MemoryState() }
        let state = try JSONDecoder().decode(MemoryState.self, from: Data(contentsOf: url))
        guard state.schemaVersion == 1, Set(state.items.map(\.id)).count == state.items.count,
              state.items.allSatisfy({ $0.revision > 0 && !$0.content.isEmpty }) else { throw ArchiveFailure.invalidSources }
        return state
    }
    static func save(_ state: MemoryState, to root: URL) throws {
        let url = root.appendingPathComponent("memories.json")
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}

// Reviews stage the response before this step. Commit memory effects before clearing
// the staged payload; appliedJobs makes a crash between those two writes replay-safe.
enum MemoryBatchDisk {
    static func replay(reviews: [SavedDailyReview], state: MemoryState, current: [SourceExcerpt],
                       deleted: Set<String>, root: URL, now: Date) throws -> (reviews: [SavedDailyReview], memories: MemoryState) {
        var nextReviews = reviews
        var nextState = MemoryRules.reconcile(state, current: current, deleted: deleted)
        for i in nextReviews.indices {
            guard let candidates = nextReviews[i].memoryCandidates, let jobID = nextReviews[i].automaticJobID else { continue }
            let sources = nextReviews[i].sources
            if !sources.isEmpty, sources.allSatisfy({ current.contains($0) && !deleted.contains($0.clipID) }),
               (nextReviews[i].invalidatedSourceIDs ?? []).isEmpty {
                nextState = MemoryRules.ingest(candidates, jobID: jobID, sources: sources, into: nextState, now: now)
            }
            nextReviews[i].memoryCandidates = nil
        }
        if nextState != state { try MemoryDisk.save(nextState, to: root) }
        if nextReviews != reviews { try Journal.saveReviews(nextReviews, to: root) }
        return (nextReviews, nextState)
    }
}
