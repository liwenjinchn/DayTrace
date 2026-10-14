import XCTest
@testable import DayTraceCore

@MainActor final class AutomaticReviewTests: XCTestCase {
    @MainActor final class Fixture {
        let root: URL
        var runner: AutomaticReviewRunner
        var clock = Date(timeIntervalSince1970: 300_000)
        var service = AIService(endpoint: "https://example.invalid/v1/chat/completions", model: "synthetic")
        var clips: [Clip] = []
        var deleted: Set<String> = []
        var completed: Set<UUID> = []
        var published: [UUID] = []
        var sends = 0
        var beforeResponse: (() async throws -> Void)?
        var fail = false
        var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            runner = AutomaticReviewRunner(root: root)
            clips = [Self.clip(start: 1000)]
        }
        static func clip(start: Double) -> Clip {
            let id = UUID().uuidString
            return Clip(id: id, started: Date(timeIntervalSince1970: start), duration: 30, marks: [], file: id + ".m4a",
                digest: String(repeating: "a", count: 64), transcript: [WordSpan(id: "0", offset: 1, duration: 2, text: "合成测试：明天核对计划")], status: "ready")
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func inputs() throws -> [ReviewInput] { try ReviewInput.candidates(clips: clips.filter { !deleted.contains($0.id) }, now: clock, calendar: calendar) }
        func approve(_ limit: Int = 2) throws { try runner.approve(service: service, limit: limit, now: clock) }
        func run() async throws {
            try await runner.run(service: { self.service }, inputs: { try self.inputs() }, completed: { self.completed },
                deleted: { self.deleted }, now: { self.clock }, ready: { true }, send: { destination, sources, _, _, _ in
                    self.sends += 1
                    // Exercise the actual request encoder/response decoder inside the production runner.
                    let request = try AIWire.request(service: destination, key: "synthetic-test-key", question: AIWire.reviewQuestion, sources: sources)
                    XCTAssertEqual(request.url?.absoluteString, self.service.endpoint)
                    XCTAssertEqual(request.httpMethod, "POST")
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                    XCTAssertNil(body["audio"]); XCTAssertNil(body["health"]); XCTAssertNil(body["location"])
                    XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("synthetic-test-key"))
                    try await self.beforeResponse?()
                    if self.fail { throw URLError(.timedOut) }
                    let answer = GroundedAnswer(answer: "合成复盘", sourceIDs: [sources[0].id])
                    let content = String(decoding: try JSONEncoder().encode(answer), as: UTF8.self)
                    let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]], "usage": ["total_tokens": 77]])
                    return try AIWire.decode(data, sources: sources)
                }, publish: { job, _ in self.completed.insert(job.id); self.published.append(job.id) })
        }
    }
    func testConsentIsRequiredAndChangedDestinationBlocksSending() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try await f.run(); XCTAssertEqual(f.sends, 0)
        try f.approve(); f.service.model = "changed"
        try await f.run(); XCTAssertEqual(f.sends, 0)
        f.service.model = "synthetic"; f.service.endpoint = "https://other.invalid/chat/completions"
        try await f.run(); XCTAssertEqual(f.sends, 0)
    }
    func testSyntheticRequestPublishesOnceAndPersistsUsageWithoutKey() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.approve(); try await f.run(); try await f.run()
        XCTAssertEqual(f.sends, 1); XCTAssertEqual(f.published.count, 1)
        XCTAssertEqual(f.runner.state.requests[0].totalTokens, 77)
        XCTAssertEqual(f.runner.state.jobs[0].state, .succeeded)
        let data = try Data(contentsOf: f.root.appendingPathComponent("automatic-reviews.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-test-key"))
        f.runner = AutomaticReviewRunner(root: f.root)
        try await f.run(); XCTAssertEqual(f.sends, 1)
    }
    func testBudgetReservedAcrossRestartAndReleasedAfter24Hours() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.clips.append(Fixture.clip(start: 87_400))
        try f.approve(1); try await f.run()
        XCTAssertEqual(f.sends, 1)
        f.runner = AutomaticReviewRunner(root: f.root)
        try await f.run(); XCTAssertEqual(f.sends, 1)
        f.clock.addTimeInterval(86_401)
        try await f.run(); XCTAssertEqual(f.sends, 2)
    }
    func testTimeoutNeverAutomaticallyRetriesAndManualRetryConsumesBudget() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.approve(1); f.fail = true
        try await f.run(); XCTAssertEqual(f.runner.state.jobs[0].state, .uncertain)
        f.runner = AutomaticReviewRunner(root: f.root)
        try await f.run(); XCTAssertEqual(f.sends, 1)
        try f.runner.retry(f.runner.state.jobs[0].id)
        try await f.run(); XCTAssertEqual(f.sends, 1)
        f.clock.addTimeInterval(86_401); f.fail = false
        try await f.run(); XCTAssertEqual(f.sends, 2); XCTAssertEqual(f.published.count, 1)
    }
    func testDeletionWhileRequestInFlightRejectsResponseAndScrubsSnapshot() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.approve(); f.beforeResponse = { f.deleted.insert(f.clips[0].id) }
        try await f.run()
        XCTAssertEqual(f.published.count, 0)
        XCTAssertEqual(f.runner.state.jobs[0].state, .cancelled)
        XCTAssertTrue(f.runner.state.jobs[0].input.sources.isEmpty)
        XCTAssertFalse(String(decoding: try Data(contentsOf: f.root.appendingPathComponent("automatic-reviews.json")), as: UTF8.self).contains("合成测试"))
    }
    func testConsentRevokedDuringRequestRejectsResult() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.approve(); f.beforeResponse = { try f.runner.pause() }
        try await f.run(); XCTAssertEqual(f.published.count, 0); XCTAssertEqual(f.sends, 1)
        XCTAssertEqual(f.runner.state.jobs[0].state, .uncertain)
    }
    func testLateInputCancelsOldVersionAndCreatesOneNewVersion() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.approve(); f.beforeResponse = { f.clips.append(Fixture.clip(start: 2000)) }
        try await f.run()
        XCTAssertEqual(f.published.count, 0); XCTAssertEqual(f.runner.state.jobs.count, 2)
        XCTAssertEqual(f.runner.state.jobs[0].state, .cancelled)
        f.beforeResponse = nil; try await f.run()
        XCTAssertEqual(f.sends, 2); XCTAssertEqual(f.published.count, 1)
    }
    func testInterruptedRequestIsUncertainButCommittedOutputWins() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.approve()
        try f.runner.reconcile(inputs: f.inputs(), completed: [], deleted: [])
        var state = f.runner.state
        state.jobs[0].state = .running
        state.requests.append(AIRequestAudit(jobID: state.jobs[0].id, service: f.service, sentAt: f.clock, sourceIDs: []))
        try AutomaticReviewDisk.save(state, to: f.root)
        f.runner = AutomaticReviewRunner(root: f.root)
        XCTAssertEqual(f.runner.state.jobs[0].state, .uncertain)
        try await f.run(); XCTAssertEqual(f.sends, 0)
        f.completed.insert(state.jobs[0].id)
        try await f.run(); XCTAssertEqual(f.runner.state.jobs[0].state, .succeeded)
        XCTAssertEqual(f.sends, 0)
    }
    func testCorruptStateBlocksExternalRequestsAndPreservesFile() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let file = f.root.appendingPathComponent("automatic-reviews.json")
        let data = Data("corrupt".utf8); try data.write(to: file)
        f.runner = AutomaticReviewRunner(root: f.root)
        XCTAssertFalse(f.runner.healthy)
        XCTAssertThrowsError(try f.approve())
        try await f.run(); XCTAssertEqual(f.sends, 0)
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testScheduleAndInputVersionIncludeBeyondFirstEightSources() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.clock = Date(timeIntervalSince1970: 115_199)
        XCTAssertTrue(try f.inputs().isEmpty)
        f.clock.addTimeInterval(1)
        XCTAssertEqual(try f.inputs().count, 1)
        f.clips = (0..<9).map { Fixture.clip(start: Double(1000 + $0 * 100)) }
        let first = try XCTUnwrap(f.inputs().first)
        XCTAssertEqual(first.sources.count, 8); XCTAssertEqual(first.totalSources, 9)
        f.clips[8].transcript[0].text = "更新第九条"
        let next = try XCTUnwrap(f.inputs().first)
        XCTAssertEqual(first.sources, next.sources); XCTAssertNotEqual(first.version, next.version)
    }
    func testUnknownUsageAndInvalidCitations() async throws {
        let source = SourceExcerpt(id: "s", clipID: "c", offset: 0, text: "合成", started: Date())
        func payload(_ id: String) throws -> Data {
            let content = String(decoding: try JSONEncoder().encode(GroundedAnswer(answer: "合成", sourceIDs: [id])), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        }
        XCTAssertNil(try AIWire.decode(payload("s"), sources: [source]).totalTokens)
        XCTAssertThrowsError(try AIWire.decode(payload("invented"), sources: [source]))
        XCTAssertThrowsError(try AIWire.request(service: AIService(endpoint: "http://example.invalid", model: "m"), key: "test", question: "q", sources: [source]))
    }
    func testReentrantWakeupDoesNotSendDuplicateRequest() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.approve(); f.beforeResponse = { try await f.run() }
        try await f.run()
        XCTAssertEqual(f.sends, 1); XCTAssertEqual(f.published.count, 1)
    }
    func testFailedQueueWritePreventsSending() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.approve()
        let file = f.root.appendingPathComponent("automatic-reviews.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { try await f.run(); XCTFail("Expected a persistence failure") } catch { }
        XCTAssertEqual(f.sends, 0); XCTAssertFalse(f.runner.healthy)
    }
    func testServiceChangedDuringRequestCannotPublishOldResponse() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.approve(); f.beforeResponse = { f.service.model = "new-model" }
        try await f.run()
        XCTAssertEqual(f.sends, 1); XCTAssertTrue(f.published.isEmpty)
        try await f.run(); XCTAssertEqual(f.sends, 1)
    }
    func testReviewJobIDSurvivesDiskRoundTrip() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let input = try XCTUnwrap(f.inputs().first)
        let job = AutomaticReviewJob(input: input)
        let review = SavedDailyReview(day: input.day, answer: GroundedAnswer(answer: "合成", sourceIDs: [input.sources[0].id]),
            sources: input.sources, totalRecordings: input.totalRecordings, automaticJobID: job.id, inputVersion: input.version)
        try Journal.saveReviews([review], to: f.root)
        XCTAssertEqual(try Journal.loadReviews(from: f.root).first?.automaticJobID, job.id)
    }

    func testReturningInputRestoresUnsentWorkButNotAnUncertainPaidAttempt() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let inputs = try f.inputs()
        try f.runner.reconcile(inputs: inputs, completed: [], deleted: [])
        try f.runner.reconcile(inputs: [], completed: [], deleted: [])
        XCTAssertEqual(f.runner.state.jobs[0].state, .cancelled)
        try f.runner.reconcile(inputs: inputs, completed: [], deleted: [])
        XCTAssertEqual(f.runner.state.jobs[0].state, .pending)
        try f.approve(); f.fail = true; try await f.run()
        try f.runner.reconcile(inputs: [], completed: [], deleted: [])
        try f.runner.reconcile(inputs: inputs, completed: [], deleted: [])
        XCTAssertEqual(f.runner.state.jobs[0].state, .uncertain)
        try await f.run(); XCTAssertEqual(f.sends, 1)
    }

    func testWholeDayBatchesResumeAcrossBudgetWindowsWithoutRepeating() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.clips = (0..<25).map { Fixture.clip(start: Double(1000 + $0 * 100)) }
        let inputs = try f.inputs()
        XCTAssertEqual(inputs.count, 4)
        XCTAssertEqual(inputs.map { $0.sources.count }, [8,8,8,1])
        XCTAssertEqual(Set(inputs.flatMap { $0.sources.map(\.id) }).count, 25)
        XCTAssertEqual(Set(inputs.compactMap(\.dayVersion)).count, 1)
        XCTAssertEqual(Set(inputs.map(\.version)).count, 4)
        try f.approve(2); try await f.run()
        XCTAssertEqual(f.sends, 2)
        XCTAssertEqual(f.runner.state.jobs.filter { $0.state == .pending }.count, 2)
        f.runner = AutomaticReviewRunner(root: f.root)
        try await f.run(); XCTAssertEqual(f.sends, 2)
        f.clock.addTimeInterval(86401); try await f.run()
        XCTAssertEqual(f.sends, 4)
        XCTAssertEqual(f.runner.state.jobs.filter { $0.state == .succeeded }.count, 4)
        try await f.run(); XCTAssertEqual(f.sends, 4)
    }

}
