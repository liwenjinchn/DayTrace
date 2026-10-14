import XCTest
@testable import DayTraceCore

final class MemoryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 300_000)
    func source(_ id: String = "clip:0", text: String = "录音中提到周末去公园散步") -> SourceExcerpt {
        SourceExcerpt(id: id, clipID: String(id.split(separator: ":")[0]), offset: 0, text: text, started: now)
    }
    func candidate(_ source: SourceExcerpt, content: String = "录音中提到周末去公园", subject: MemorySubject = .record) -> MemoryCandidate {
        MemoryCandidate(content: content, topic: "周末计划", category: .plan, subject: subject, uncertain: false,
                        evidence: [MemoryEvidence(sourceID: source.id, quote: source.text)])
    }
    func inserted(_ c: MemoryCandidate, sources: [SourceExcerpt]) -> MemoryState {
        MemoryRules.ingest([c], jobID: UUID(), sources: sources, into: MemoryState(), now: now)
    }
    func testEvidenceRequiresKnownSourceAndActualQuote() {
        let s = source(); var c = candidate(s)
        XCTAssertTrue(MemoryRules.valid(c, sources: [s]))
        c.evidence[0].sourceID = "made-up"; XCTAssertFalse(MemoryRules.valid(c, sources: [s]))
        c.evidence[0].sourceID = s.id; c.evidence[0].quote = "不在原文中的话"
        XCTAssertFalse(MemoryRules.valid(c, sources: [s]))
        c.evidence[0].quote = "去"; XCTAssertFalse(MemoryRules.valid(c, sources: [s]))
        XCTAssertTrue(inserted(c, sources: [s]).items.isEmpty)
    }
    func testOnlyRecordObservationsAutomaticallyBecomeActive() {
        let s = source()
        XCTAssertEqual(inserted(candidate(s), sources: [s]).items[0].status, .active)
        for subject in [MemorySubject.user, .other, .unknown] {
            let state = inserted(candidate(s, subject: subject), sources: [s])
            XCTAssertEqual(state.items[0].status, .needsReview)
            XCTAssertTrue(MemoryRules.contexts(state, sources: [s]).isEmpty)
        }
        var uncertain = candidate(s); uncertain.uncertain = true
        XCTAssertEqual(inserted(uncertain, sources: [s]).items[0].status, .needsReview)
    }
    func testJobReplayAndDuplicateContentDoNotCreateDuplicates() {
        let s = source(); let job = UUID(); let c = candidate(s)
        let once = MemoryRules.ingest([c], jobID: job, sources: [s], into: MemoryState(), now: now)
        XCTAssertEqual(MemoryRules.ingest([c], jobID: job, sources: [s], into: once, now: now), once)
        XCTAssertEqual(MemoryRules.ingest([c], jobID: UUID(), sources: [s], into: once, now: now).items, once.items)
    }
    func testEditWinsOverRephrasedResponseAndStoresHistory() throws {
        let s = source(); let initial = inserted(candidate(s), sources: [s]); let id = initial.items[0].id
        let edited = try MemoryRules.edit(id, content: "用户更正后的计划", in: initial, now: now)
        var rephrased = candidate(s, content: "换一种说法重新生成")
        rephrased.topic = "模型换了主题"
        let replay = MemoryRules.ingest([rephrased], jobID: UUID(), sources: [s], into: edited, now: now)
        XCTAssertEqual(replay.items.count, 1)
        XCTAssertEqual(replay.items[0].content, "用户更正后的计划")
        XCTAssertEqual(replay.items[0].history[0].content, initial.items[0].content)
    }
    func testDisableAndDeleteSurviveParaphrasesAndRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let s = source(); let initial = inserted(candidate(s), sources: [s]); let id = initial.items[0].id
        let disabled = try MemoryRules.setStatus(id, active: false, in: initial, now: now)
        XCTAssertTrue(MemoryRules.contexts(disabled, sources: [s]).isEmpty)
        let removed = MemoryRules.delete(id, from: disabled)
        try MemoryDisk.save(removed, to: root)
        var rephrased = candidate(s, content: "新的措辞"); rephrased.topic = "新主题"
        let recovered = try MemoryDisk.load(from: root)
        XCTAssertTrue(MemoryRules.ingest([rephrased], jobID: UUID(), sources: [s], into: recovered, now: now).items.isEmpty)
        let json = String(decoding: try Data(contentsOf: root.appendingPathComponent("memories.json")), as: UTF8.self)
        XCTAssertFalse(json.contains(initial.items[0].content)); XCTAssertFalse(json.contains(s.text))
    }
    func testSameTopicConflictExcludesBothUntilUserConfirms() throws {
        let s1 = source(); let s2 = source("second:0", text: "录音中提到周末不去公园")
        let initial = inserted(candidate(s1), sources: [s1])
        let conflict = MemoryRules.ingest([candidate(s2, content: "录音中提到周末不去公园")], jobID: UUID(), sources: [s2], into: initial, now: now)
        XCTAssertEqual(conflict.items.count, 2)
        XCTAssertTrue(conflict.items.allSatisfy { $0.status == .needsReview })
        XCTAssertTrue(MemoryRules.contexts(conflict, sources: [s1, s2]).isEmpty)
        let confirmed = try MemoryRules.setStatus(conflict.items[1].id, active: true, in: conflict, now: now)
        XCTAssertEqual(MemoryRules.contexts(confirmed, sources: [s1, s2]).count, 1)
    }
    func testPartialSourceDeletionRequiresRecheckAndClearsSnapshot() throws {
        let s1 = source(); let s2 = source("second:0")
        var c = candidate(s1); c.evidence.append(MemoryEvidence(sourceID: s2.id, quote: s2.text))
        let initial = inserted(c, sources: [s1, s2])
        let pruned = MemoryRules.reconcile(initial, current: [s2], deleted: [s1.clipID])
        XCTAssertEqual(pruned.items[0].sources, [s2]); XCTAssertEqual(pruned.items[0].status, .needsReview)
        XCTAssertTrue(MemoryRules.contexts(pruned, sources: [s2]).isEmpty)
        let gone = MemoryRules.reconcile(pruned, current: [], deleted: [s1.clipID, s2.clipID])
        XCTAssertEqual(gone.items[0].status, .sourceMissing); XCTAssertTrue(gone.items[0].sources.isEmpty)
        XCTAssertThrowsError(try MemoryRules.setStatus(gone.items[0].id, active: true, in: gone, now: now))
    }
    func testTranscriptChangeCannotKeepOldSourceActive() {
        let original = source(); let state = inserted(candidate(original), sources: [original])
        var changed = original; changed.text = "完全不同的转写"
        let reconciled = MemoryRules.reconcile(state, current: [changed], deleted: [])
        XCTAssertEqual(reconciled.items[0].status, .sourceMissing)
        XCTAssertTrue(MemoryRules.contexts(reconciled, sources: [changed]).isEmpty)
    }
    func testContextRequiresAllCurrentSourcesAndChangesAfterEdit() throws {
        let s = source(); let state = inserted(candidate(s), sources: [s])
        let snapshot = MemoryRules.contexts(state, sources: [s])
        XCTAssertTrue(MemoryRules.contexts(state, sources: []).isEmpty)
        let edited = try MemoryRules.edit(state.items[0].id, content: "手动纠正", in: state, now: now)
        XCTAssertNotEqual(MemoryRules.contexts(edited, sources: [s]), snapshot)
    }
    func testCorruptMemoryFileIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("memories.json"); let data = Data("broken".utf8)
        try data.write(to: file); XCTAssertThrowsError(try MemoryDisk.load(from: root))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testOldConsentDoesNotGrantMemoryGenerationAndModeChangesInputVersion() throws {
        let service = AIService(endpoint: "https://example.invalid/chat/completions", model: "test")
        let old = AutomaticReviewPolicy(service: service, callsPer24Hours: 3, consentedAt: now, enabled: true)
        let decoded = try JSONDecoder().decode(AutomaticReviewPolicy.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.generateMemories)
        let id = UUID().uuidString
        let clip = Clip(id: id, started: Date(timeIntervalSince1970: 1000), duration: 30, marks: [], file: id + ".m4a", digest: String(repeating: "a", count: 64),
                        transcript: [WordSpan(id: "0", offset: 0, duration: 1, text: "合成原文")], status: "ready")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let oldInput = try ReviewInput.candidates(clips: [clip], now: now, calendar: calendar)
        let newInput = try ReviewInput.candidates(clips: [clip], now: now, calendar: calendar, generateMemories: true)
        XCTAssertNotEqual(oldInput[0].version, newInput[0].version)
        XCTAssertNil(oldInput[0].generateMemories); XCTAssertEqual(newInput[0].generateMemories, true)
    }
    func testWireIgnoresUnrequestedMemoriesAndSeparatesMemoryContextFromEvidence() throws {
        let s = source(); let c = candidate(s)
        struct Payload: Encodable { var answer = "复盘"; var sourceIDs: [String]; var memories: [MemoryCandidate] }
        let payload = Payload(sourceIDs: [s.id], memories: [c])
        let content = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        XCTAssertTrue(try AIWire.decode(response, sources: [s]).memoryCandidates.isEmpty)
        XCTAssertEqual(try AIWire.decode(response, sources: [s], generateMemories: true).memoryCandidates, [c])
        let contexts = MemoryRules.contexts(inserted(c, sources: [s]), sources: [s])
        let request = try AIWire.request(service: AIService(endpoint: "https://example.invalid/chat/completions", model: "test"), key: "synthetic-key", question: "问题", sources: [s], memories: contexts)
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("MemoryContext")); XCTAssertTrue(body.contains("not independent evidence"))
        XCTAssertFalse(body.contains("synthetic-key")); XCTAssertFalse(body.contains("Also return memories"))
    }
    func testStagedResponseRecoveryAcrossTwoDiskCommits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = source(); let c = candidate(source); let job = UUID()
        let staged = SavedDailyReview(day: now, answer: GroundedAnswer(answer: "复盘", sourceIDs: [source.id]), sources: [source],
            totalRecordings: 1, automaticJobID: job, memoryCandidates: [c])
        // A blocked journal destination makes the second commit fail after memory is durable.
        let journal = root.appendingPathComponent("daily-reviews.json")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        XCTAssertThrowsError(try MemoryBatchDisk.replay(reviews: [staged], state: MemoryState(), current: [source], deleted: [], root: root, now: now))
        let committed = try MemoryDisk.load(from: root)
        XCTAssertEqual(committed.items.count, 1); XCTAssertTrue(committed.appliedJobs.contains(job))
        try FileManager.default.removeItem(at: journal)
        try Journal.saveReviews([staged], to: root) // The unchanged staged response survives the failed commit.
        let recovered = try MemoryBatchDisk.replay(reviews: Journal.loadReviews(from: root), state: committed, current: [source], deleted: [], root: root, now: now)
        XCTAssertEqual(recovered.memories.items.count, 1)
        XCTAssertNil(recovered.reviews[0].memoryCandidates)
        XCTAssertEqual(recovered.memories, committed)
    }
    func testStagedResponseCannotRestoreDeletedMemoryOrSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = source(); let c = candidate(source)
        let existing = inserted(c, sources: [source])
        let removed = MemoryRules.delete(existing.items[0].id, from: existing)
        let staged = SavedDailyReview(day: now, answer: GroundedAnswer(answer: "复盘", sourceIDs: [source.id]), sources: [source],
            totalRecordings: 1, automaticJobID: UUID(), memoryCandidates: [c])
        let result = try MemoryBatchDisk.replay(reviews: [staged], state: removed, current: [source], deleted: [], root: root, now: now)
        XCTAssertTrue(result.memories.items.isEmpty)
        let gone = try MemoryBatchDisk.replay(reviews: [staged], state: MemoryState(), current: [], deleted: [source.clipID], root: root, now: now)
        XCTAssertTrue(gone.memories.items.isEmpty); XCTAssertNil(gone.reviews[0].memoryCandidates)
    }
    @MainActor func testRunnerGeneratesMemoriesThroughWireAndDurableBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = AutomaticReviewRunner(root: root)
        let service = AIService(endpoint: "https://example.invalid/chat/completions", model: "synthetic")
        try runner.approve(service: service, limit: 2, now: now, generateMemories: true)
        let source = source(); let c = candidate(source)
        let input = ReviewInput(day: now.addingTimeInterval(-86400), timeZone: "UTC", version: String(repeating: "a", count: 64),
            sources: [source], totalRecordings: 1, totalSources: 1, pendingRecordings: 0, generateMemories: true)
        var reviews: [SavedDailyReview] = []; var memoryState = MemoryState(); var sends = 0
        for _ in 0..<2 {
            try await runner.run(service: { service }, inputs: { [input] }, completed: { Set(reviews.compactMap(\.automaticJobID)) },
                deleted: { [] }, now: { self.now }, ready: { true }, send: { target, sources, enabled, _, _ in
                    sends += 1; XCTAssertTrue(enabled)
                    let request = try AIWire.request(service: target, key: "synthetic-key", question: AIWire.reviewQuestion, sources: sources, generateMemories: enabled)
                    XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("Also return memories"))
                    struct Payload: Encodable { var answer = "合成复盘"; var sourceIDs: [String]; var memories: [MemoryCandidate] }
                    let payload = Payload(sourceIDs: [source.id], memories: [c])
                    let content = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
                    let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
                    return try AIWire.decode(response, sources: sources, generateMemories: enabled)
                }, publish: { job, reply in
                    let staged = SavedDailyReview(day: input.day, answer: reply.answer, sources: input.sources, totalRecordings: 1,
                        automaticJobID: job.id, memoryCandidates: reply.memoryCandidates)
                    try Journal.saveReviews([staged], to: root)
                    let recovered = try MemoryBatchDisk.replay(reviews: [staged], state: memoryState, current: [source], deleted: [], root: root, now: self.now)
                    reviews = recovered.reviews; memoryState = recovered.memories
                })
        }
        XCTAssertEqual(sends, 1); XCTAssertEqual(memoryState.items.count, 1)
        XCTAssertEqual(try MemoryDisk.load(from: root).items.count, 1)
        XCTAssertNil(try Journal.loadReviews(from: root)[0].memoryCandidates)
        XCTAssertEqual(runner.state.requests[0].generateMemories, true)
    }

}
