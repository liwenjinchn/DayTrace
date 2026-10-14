import Foundation
import CryptoKit

struct AIService: Codable, Equatable {
    var endpoint: String
    var model: String
    func validate() throws {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AutomaticReviewError.invalidSettings }
    }
}

enum AutomaticReviewError: LocalizedError {
    case invalidSettings, unavailable, stale
    var errorDescription: String? {
        switch self {
        case .invalidSettings: return "请输入完整 HTTPS 接口、模型和 1–100 次的调用上限。"
        case .unavailable: return "自动复盘存储不可用，已停止外发并保留原文件。"
        case .stale: return "原文或授权已变化，本次结果不再发布。"
        }
    }
}

struct AutomaticReviewPolicy: Codable, Equatable {
    var service: AIService
    var callsPer24Hours: Int
    var consentedAt: Date
    var enabled: Bool
    var generateMemories: Bool? = nil
    var generateHighlights: Bool? = nil
    var tokensPer24Hours: Int? = nil
}

struct ReviewInput: Codable, Equatable {
    var day: Date
    var timeZone: String
    var version: String
    var sources: [SourceExcerpt]
    var totalRecordings: Int
    var totalSources: Int
    var pendingRecordings: Int
    var generateMemories: Bool? = nil
    var generateHighlights: Bool? = nil
    var contexts: [ContextSample]? = nil

    var dayVersion: String? = nil
    var batchIndex: Int? = nil
    var batchCount: Int? = nil

    static func candidates(clips: [Clip], now: Date, calendar: Calendar = .current, generateMemories: Bool = false, generateHighlights: Bool = false, contexts: [ContextSample] = []) throws -> [ReviewInput] {
        var grouped: [Date: [Clip]] = [:]
        for clip in clips { for day in TimelineRules.days(clip, calendar: calendar) { grouped[day, default: []].append(clip) } }
        return try grouped.keys.sorted().flatMap { day -> [ReviewInput] in
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: day),
                  let eligibleAt = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow),
                  now >= eligibleAt else { return [] }
            let daily = grouped[day]!.sorted { $0.started == $1.started ? $0.id < $1.id : $0.started < $1.started }
            let sources = Journal.dailySources(daily.filter { $0.status == "ready" }, day: day, calendar: calendar)
            guard !sources.isEmpty else { return [] }
            // Hash all input, including records outside this bounded request, so late
            // arrivals invalidate a prior generation even when its first 8 sources match.
            struct Version: Encodable {
                struct Record: Encodable { var id: String; var status: String; var started: Date; var duration: Double }
                var promptVersion = 2
                var day: Date; var timeZone: String; var records: [Record]; var sources: [SourceExcerpt]
                var generateMemories: Bool? = nil
    var generateHighlights: Bool? = nil
    var contexts: [ContextSample]? = nil
            }
            let selected = contexts.filter { sample in sources.contains { let time = $0.started.addingTimeInterval($0.offset); return time >= sample.start && time < sample.end } }.sorted { $0.id < $1.id }
            let snapshot = Version(day: day, timeZone: calendar.timeZone.identifier,
                records: daily.map { Version.Record(id: $0.id, status: $0.status, started: $0.started, duration: $0.duration) }, sources: sources, generateMemories: generateMemories ? true : nil, generateHighlights: generateHighlights ? true : nil, contexts: selected.isEmpty ? nil : selected)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let version = SHA256.hash(data: try encoder.encode(snapshot)).map { String(format: "%02x", $0) }.joined()
            let count = (sources.count + 7) / 8
            return stride(from: 0, to: sources.count, by: 8).map { offset in
                let batch = Array(sources[offset..<min(offset + 8, sources.count)])
                let batchContexts = Array(selected.filter { sample in batch.contains { let time = $0.started.addingTimeInterval($0.offset); return time >= sample.start && time < sample.end } }.prefix(32))
                let batchVersion = SHA256.hash(data: Data("\(version)|batch-v1|\(offset / 8)".utf8)).map { String(format: "%02x", $0) }.joined()
                return ReviewInput(day: day, timeZone: calendar.timeZone.identifier, version: batchVersion,
                    sources: batch, totalRecordings: daily.count, totalSources: sources.count,
                    pendingRecordings: daily.filter { $0.status != "ready" }.count, generateMemories: generateMemories ? true : nil, generateHighlights: generateHighlights ? true : nil, contexts: batchContexts.isEmpty ? nil : batchContexts,
                    dayVersion: version, batchIndex: offset / 8, batchCount: count)
            }
        }
    }
}

struct AutomaticReviewJob: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case pending, running, succeeded, uncertain, cancelled
        var label: String {
            switch self {
            case .pending: return "等待处理"
            case .running: return "请求中"
            case .succeeded: return "已完成"
            case .uncertain: return "结果未确认，需手动决定重试"
            case .cancelled: return "来源变化，已取消"
            }
        }
    }
    var id = UUID()
    var input: ReviewInput
    var state: State = .pending
}

struct AIRequestAudit: Codable, Equatable, Identifiable {
    var id = UUID()
    var jobID: UUID
    var service: AIService
    var sentAt: Date
    var sourceIDs: [String]
    var outcome: String = "结果未确认"
    var totalTokens: Int? = nil
    var reservedTokens: Int? = nil
    var generateMemories: Bool? = nil
    var generateHighlights: Bool? = nil
    var contexts: [ContextSample]? = nil
}

struct AutomaticReviewState: Codable, Equatable {
    var schemaVersion = 1
    var policy: AutomaticReviewPolicy? = nil
    var jobs: [AutomaticReviewJob] = []
    var requests: [AIRequestAudit] = []
    func callsUsed(now: Date) -> Int {
        // Future timestamps also count if the device clock moves backwards.
        requests.filter { $0.sentAt > now.addingTimeInterval(-86400) }.count
    }
    func tokensUsed(now: Date) -> Int {
        requests.filter { $0.sentAt > now.addingTimeInterval(-86400) }.reduce(0) { $0 + max($1.totalTokens ?? 0, $1.reservedTokens ?? 0) }
    }
    func validate() throws {
        guard schemaVersion == 1, Set(jobs.map(\.id)).count == jobs.count,
              Set(requests.map(\.id)).count == requests.count,
              jobs.allSatisfy({ $0.input.version.count == 64 && $0.input.totalRecordings >= 0 && $0.input.totalSources >= $0.input.sources.count }),
              requests.allSatisfy({ ($0.totalTokens == nil || (0...100000000).contains($0.totalTokens!)) && ($0.reservedTokens == nil || (0...20000000).contains($0.reservedTokens!)) }) else { throw AutomaticReviewError.unavailable }
        if let policy {
            try policy.service.validate()
            guard (1...100).contains(policy.callsPer24Hours), policy.tokensPer24Hours == nil || (1024...1000000).contains(policy.tokensPer24Hours!) else { throw AutomaticReviewError.invalidSettings }
        }
    }
}

enum AutomaticReviewDisk {
    static func load(from root: URL) throws -> AutomaticReviewState {
        let url = root.appendingPathComponent("automatic-reviews.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return AutomaticReviewState() }
        let state = try JSONDecoder().decode(AutomaticReviewState.self, from: Data(contentsOf: url))
        try state.validate(); return state
    }
    static func save(_ state: AutomaticReviewState, to root: URL) throws {
        try state.validate()
        let url = root.appendingPathComponent("automatic-reviews.json")
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}

struct AIReply { var answer: GroundedAnswer; var totalTokens: Int?; var memoryCandidates: [MemoryCandidate] = []; var highlightCandidates: [HighlightCandidate] = [] }

// One owner serializes reservations before I/O. Dependencies are injectable so tests
// exercise the same runner with synthetic requests and no credentials or real audio.
@MainActor final class AutomaticReviewRunner {
    private(set) var state: AutomaticReviewState
    private(set) var healthy = true
    private(set) var busy = false
    var onChange: ((AutomaticReviewState) -> Void)?
    private let root: URL
    init(root: URL) {
        self.root = root
        do {
            state = try AutomaticReviewDisk.load(from: root)
            for i in state.jobs.indices where state.jobs[i].state == .running {
                // No provider idempotency guarantee: never automatically retry an
                // interrupted paid request whose response may have been lost.
                state.jobs[i].state = .uncertain
            }
            try AutomaticReviewDisk.save(state, to: root)
        } catch { state = AutomaticReviewState(); healthy = false }
    }
    private func commit(_ updated: AutomaticReviewState) throws {
        guard healthy else { throw AutomaticReviewError.unavailable }
        do { try AutomaticReviewDisk.save(updated, to: root) }
        catch { healthy = false; throw AutomaticReviewError.unavailable }
        state = updated; onChange?(state)
    }
    func approve(service: AIService, limit: Int, now: Date, generateMemories: Bool = false, generateHighlights: Bool = false, tokensPer24Hours: Int? = nil) throws {
        try service.validate()
        guard (1...100).contains(limit) else { throw AutomaticReviewError.invalidSettings }
        guard tokensPer24Hours == nil || tokensPer24Hours! >= 1024 else { throw AutomaticReviewError.invalidSettings }
        var next = state
        next.policy = AutomaticReviewPolicy(service: service, callsPer24Hours: limit, consentedAt: now, enabled: true, generateMemories: generateMemories ? true : nil, generateHighlights: generateHighlights ? true : nil, tokensPer24Hours: tokensPer24Hours)
        try commit(next)
    }
    func pause() throws {
        var next = state; next.policy?.enabled = false; try commit(next)
    }
    func retry(_ id: UUID) throws {
        var next = state
        guard let i = next.jobs.firstIndex(where: { $0.id == id }), next.jobs[i].state == .uncertain else { return }
        next.jobs[i].state = .pending
        try commit(next)
    }
    func reconcile(inputs: [ReviewInput], completed: Set<UUID>, deleted: Set<String>) throws {
        var next = state
        for i in next.jobs.indices {
            let removed = next.jobs[i].input.sources.contains { deleted.contains($0.clipID) }
            if removed {
                next.jobs[i].input.sources.removeAll { deleted.contains($0.clipID) }
                next.jobs[i].input.contexts = nil
                for a in next.requests.indices where next.requests[a].jobID == next.jobs[i].id { next.requests[a].contexts = nil }
                next.jobs[i].state = .cancelled
            } else if completed.contains(next.jobs[i].id) { next.jobs[i].state = .succeeded }
            else if !inputs.contains(where: { $0.version == next.jobs[i].input.version }) {
                next.jobs[i].state = .cancelled
            } else if next.jobs[i].state == .cancelled,
                      inputs.contains(where: { $0.version == next.jobs[i].input.version && $0.sources == next.jobs[i].input.sources }) {
                // A purpose/time-window switch may make an unchanged input eligible again.
                // Restore unsent work, but never automatically repeat a possibly paid attempt.
                next.jobs[i].state = next.requests.contains(where: { $0.jobID == next.jobs[i].id }) ? .uncertain : .pending
            }
        }
        for input in inputs where !input.sources.isEmpty && !input.sources.contains(where: { deleted.contains($0.clipID) }) {
            if !next.jobs.contains(where: { $0.input.version == input.version }) {
                next.jobs.append(AutomaticReviewJob(input: input))
            }
        }
        if next != state { try commit(next) }
    }
    func run(service: () -> AIService, inputs: () throws -> [ReviewInput], completed: () -> Set<UUID>,
             deleted: () throws -> Set<String>, now: () -> Date = Date.init,
             ready: () -> Bool, send: (AIService, [SourceExcerpt], Bool, Bool, [ContextSample]) async throws -> AIReply,
             publish: (AutomaticReviewJob, AIReply) throws -> Void) async throws {
        guard !busy, healthy else { return }
        busy = true; defer { busy = false }
        while true {
            try reconcile(inputs: inputs(), completed: completed(), deleted: deleted())
            guard ready(), let policy = state.policy, policy.enabled, policy.service == service(),
                  state.callsUsed(now: now()) < policy.callsPer24Hours,
                  let i = state.jobs.firstIndex(where: { $0.state == .pending && ($0.input.generateMemories == true) == (policy.generateMemories == true) && ($0.input.generateHighlights == true) == (policy.generateHighlights == true) }) else { return }
            let job = state.jobs[i]
            let estimate = try AIWire.request(service: policy.service, key: "budget-estimate", question: AIWire.reviewQuestion, sources: job.input.sources,
                generateMemories: policy.generateMemories == true, generateHighlights: policy.generateHighlights == true, contexts: job.input.contexts ?? []).httpBody!.count + 4096 + AIWire.outputLimit
            if let limit = policy.tokensPer24Hours, state.tokensUsed(now: now()) + estimate > limit { return }
            var reserved = state; reserved.jobs[i].state = .running
            let audit = AIRequestAudit(jobID: job.id, service: policy.service, sentAt: now(), sourceIDs: job.input.sources.map(\.id), generateMemories: policy.generateMemories, generateHighlights: policy.generateHighlights, contexts: job.input.contexts)
            var budgetedAudit = audit; budgetedAudit.reservedTokens = estimate
            reserved.requests.append(budgetedAudit)
            try commit(reserved) // Budget and attempt land in the same atomic file before sending.
            do {
                let reply = try await send(policy.service, job.input.sources, policy.generateMemories == true, policy.generateHighlights == true, job.input.contexts ?? [])
                try reconcile(inputs: inputs(), completed: completed(), deleted: deleted())
                guard ready(), state.policy == policy, service() == policy.service,
                      let current = state.jobs.first(where: { $0.id == job.id }), current.state == .running,
                      try inputs().contains(where: { $0.version == job.input.version }) else { throw AutomaticReviewError.stale }
                _ = try reply.answer.checked(against: job.input.sources)
                try publish(job, reply) // Output first; startup recognizes its stable job ID.
                var done = state
                if let j = done.jobs.firstIndex(where: { $0.id == job.id }) { done.jobs[j].state = .succeeded }
                if let a = done.requests.firstIndex(where: { $0.id == audit.id }) {
                    done.requests[a].outcome = "已保存复盘"; done.requests[a].totalTokens = reply.totalTokens
                }
                try commit(done)
            } catch {
                // Error descriptions can contain URLs/provider content; store a fixed
                // safe status instead of arbitrary transport payloads or credentials.
                var failed = state
                if let j = failed.jobs.firstIndex(where: { $0.id == job.id }), failed.jobs[j].state == .running { failed.jobs[j].state = .uncertain }
                if let a = failed.requests.firstIndex(where: { $0.id == audit.id }) { failed.requests[a].outcome = "未发布；可能已计费，重试前请核对" }
                try commit(failed)
                return // A failing provider must not burn through the remaining queue.
            }
        }
    }
}
