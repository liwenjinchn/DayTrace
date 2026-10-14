import XCTest
import AVFoundation
@testable import DayTraceCore

final class PRDCompletionTests: XCTestCase {
    let password = "test-only-password-12345"
    func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    func clip(_ root: URL) throws -> Clip {
        let id = UUID().uuidString, file = id + ".m4a"
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        for i in 0..<16000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1)) * 0.1 }
        do { let audio = try AVAudioFile(forWriting: root.appendingPathComponent(file), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1]); try audio.write(from: buffer) }
        return Clip(id: id, started: Date(timeIntervalSince1970: 100), duration: 1, marks: [], file: file,
            digest: AudioVault.hash(try Data(contentsOf: root.appendingPathComponent(file))), transcript: [WordSpan(id: "0", offset: 0, duration: 1, text: "合成测试记录，讨论硬件设计方案")], status: "ready")
    }
    func testEncryptedRoundTripAndCorruptionPreservesCurrentLibrary() throws {
        let root = try folder(), other = try folder(), output = try folder()
        defer { for path in [root,other,output] { try? FileManager.default.removeItem(at: path) } }
        let c = try clip(root); try ArchiveDisk.save([c], to: root)
        try Data("do-not-export-secret".utf8).write(to: root.appendingPathComponent("credentials.json"))
        let file = output.appendingPathComponent("backup.daytrace")
        try EncryptedBackup.export(root: root, destination: file, password: password)
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(bytes.range(of: Data(c.transcript[0].text.utf8)))
        try ArchiveDisk.save([], to: other)
        XCTAssertThrowsError(try EncryptedBackup.restore(file: file, root: other, password: "wrong-password-1234"))
        XCTAssertTrue(try ArchiveDisk.load(from: other).isEmpty)
        try EncryptedBackup.restore(file: file, root: other, password: password)
        XCTAssertEqual(try ArchiveDisk.load(from: other), [c])
        XCTAssertEqual(AudioVault.hash(try Data(contentsOf: other.appendingPathComponent(c.file))), c.digest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("credentials.json").path))
        XCTAssertFalse(try AutomaticReviewDisk.load(from: other).policy?.enabled == true)
        XCTAssertNil(try ContextRules.load(other).consent)
        var broken = bytes; broken[broken.count / 2] ^= 0xff; try broken.write(to: file)
        XCTAssertThrowsError(try EncryptedBackup.restore(file: file, root: other, password: password))
        XCTAssertEqual(try ArchiveDisk.load(from: other), [c])
    }
    func testBackupRejectsReintroducingDeletedRecordingAndPathTraversal() throws {
        let root = try folder(), target = try folder(), out = try folder()
        defer { for p in [root,target,out] { try? FileManager.default.removeItem(at: p) } }
        let c = try clip(root); try ArchiveDisk.save([c], to: root); try ArchiveDisk.save([], to: target)
        try JSONEncoder().encode(Set([c.id])).write(to: target.appendingPathComponent("deleted-recordings.json"))
        let file = out.appendingPathComponent("b.daytrace")
        try EncryptedBackup.export(root: root, destination: file, password: password)
        XCTAssertThrowsError(try EncryptedBackup.restore(file: file, root: target, password: password))
        XCTAssertTrue(try ArchiveDisk.load(from: target).isEmpty)
        XCTAssertFalse(EncryptedBackup.allowed("../archive.json")); XCTAssertFalse(EncryptedBackup.allowed("keychain.json"))
    }
    func testRestoreJournalRollsBackInterruptedSwap() throws {
        let parent = try folder(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("DayTrace"), previous = parent.appendingPathComponent("daytrace-rollback-test"), stage = parent.appendingPathComponent("daytrace-stage-test")
        for p in [root,stage] { try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true) }
        try ArchiveDisk.save([], to: root)
        let tx = EncryptedBackup.Transaction(previous: previous.lastPathComponent, stage: stage.lastPathComponent)
        try JSONEncoder().encode(tx).write(to: parent.appendingPathComponent("DayTrace-restore.json"))
        try FileManager.default.moveItem(at: root, to: previous)
        try EncryptedBackup.recover(root)
        XCTAssertTrue(try ArchiveDisk.load(from: root).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }
    func testIndependentContextSwitchesTimeAndServiceBindingReachWire() throws {
        let source = SourceExcerpt(id: "s", clipID: UUID().uuidString, offset: 10, text: "合成原文", started: Date(timeIntervalSince1970: 100))
        let service = AIService(endpoint: "https://example.invalid/chat", model: "test")
        let health = ContextSample(id: "h", category: .health, label: "步数", value: "4321", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1000), origin: "synthetic")
        let location = ContextSample(id: "l", category: .location, label: "位置", value: "synthetic-place", start: health.start, end: health.end, origin: "synthetic")
        let contexts = ContextRules.select([health, location], sources: [source], consent: ContextConsent(service: service, health: true, location: false), service: service)
        XCTAssertEqual(contexts, [health])
        let request = try AIWire.request(service: service, key: "synthetic-key", question: "test", sources: [source], contexts: contexts)
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("4321")); XCTAssertFalse(body.contains("synthetic-place")); XCTAssertFalse(body.contains("synthetic-key"))
        XCTAssertTrue(ContextRules.select([health], sources: [source], consent: nil, service: service).isEmpty)
        XCTAssertTrue(ContextRules.select([health], sources: [source], consent: ContextConsent(service: service, health: true, location: true), service: AIService(endpoint: "https://other.invalid", model: "test")).isEmpty)
        var absent = source; absent.started = Date(timeIntervalSince1970: 2000)
        XCTAssertTrue(ContextRules.select([health], sources: [absent], consent: ContextConsent(service: service, health: true, location: true), service: service).isEmpty)
    }
    @MainActor func testTokenReservationBlocksRequestAndPersistsUnknownUsage() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let c = try clip(root), service = AIService(endpoint: "https://example.invalid/chat", model: "test")
        let input = try ReviewInput.candidates(clips: [c], now: .distantFuture)[0]
        let runner = AutomaticReviewRunner(root: root)
        try runner.approve(service: service, limit: 10, now: Date(), tokensPer24Hours: 1024)
        var sends = 0
        try await runner.run(service: { service }, inputs: { [input] }, completed: { [] }, deleted: { [] }, ready: { true }, send: { _,_,_,_,_ in sends += 1; throw ArchiveFailure.invalidSources }, publish: { _,_ in XCTFail() })
        XCTAssertEqual(sends, 0)
        try runner.approve(service: service, limit: 10, now: Date(), tokensPer24Hours: 20000)
        try await runner.run(service: { service }, inputs: { [input] }, completed: { [] }, deleted: { [] }, ready: { true }, send: { _,_,_,_,_ in
            sends += 1; XCTAssertGreaterThan(try AutomaticReviewDisk.load(from: root).tokensUsed(now: Date()), 0); throw ArchiveFailure.invalidSources
        }, publish: { _,_ in XCTFail() })
        XCTAssertEqual(sends, 1)
        XCTAssertGreaterThan(runner.state.tokensUsed(now: Date()), 0)
        XCTAssertEqual(runner.state.jobs[0].state, .uncertain)
    }
    func testPersistentIndexReconcilesDeletionAndModelChanges() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let c = try clip(root), sources = ArchiveRules.excerpts([c])
        var index = SearchIndex(model: "synthetic-v1")
        index.reconcile(sources: sources, vector: { _ in [1,0] }); try index.save(root)
        var loaded = try SearchIndex.load(root, model: "synthetic-v1")
        XCTAssertEqual(loaded.search("硬件设计"), sources)
        XCTAssertTrue(loaded.search("   ").isEmpty)
        XCTAssertTrue(loaded.search("硬件", since: Date()).isEmpty)
        loaded.reconcile(sources: [], vector: { _ in nil }); XCTAssertTrue(loaded.search("硬件").isEmpty)
        XCTAssertTrue(try SearchIndex.load(root, model: "new-model").entries.isEmpty)
    }
    func testNinetyDayKeywordBenchmark() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let start = Date(timeIntervalSince1970: 1000000)
        let sources = (0..<8640).map { i in SourceExcerpt(id: "\(i)", clipID: "synthetic-\(i)", offset: 0, text: "项目任务 编号\(i) 今天记录硬件方案和测试结果", started: start.addingTimeInterval(Double(i * 900))) }
        var index = SearchIndex(model: "keyword-only-benchmark")
        index.reconcile(sources: sources, vector: { _ in nil }); try index.save(root)
        let loaded = try SearchIndex.load(root, model: index.model)
        var durations: [Double] = []; var hits = 0
        for i in 0..<30 {
            let target = i * 277, began = Date()
            let result = loaded.search("编号\(target)", limit: 5)
            durations.append(Date().timeIntervalSince(began))
            if result.contains(where: { $0.id == "\(target)" }) { hits += 1 }
        }
        let p95 = durations.sorted()[28]
        XCTAssertEqual(hits, 30); XCTAssertLessThan(p95, 2)
        print("PRD_BENCHMARK documents=8640 synthetic_days=90 lexical_queries=30 hits=\(hits) p95_seconds=\(p95); semantic_quality_NOT_RUN")
    }
    func testCrossMidnightCoverageAndEventIdempotence() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var c = try clip(root)
        let today = Calendar.current.startOfDay(for: Date())
        c.started = today.addingTimeInterval(-5); c.duration = 10
        c.transcript = [WordSpan(id: "a", offset: 0, duration: 2, text: "昨天"), WordSpan(id: "b", offset: 6, duration: 2, text: "今天")]
        XCTAssertEqual(TimelineRules.seconds(c, day: today), 5)
        XCTAssertEqual(TimelineRules.seconds(c, day: today, hour: 0), 5)
        XCTAssertEqual(TimelineRules.seconds(c, day: today, hour: 23), 0)
        XCTAssertEqual(Journal.dailySources([c], day: today).map(\.text), ["今天"])
        let event = SessionEvent(sessionID: UUID().uuidString, kind: .pause, detail: "暂停")
        XCTAssertEqual(try SessionEvents.insert(event, root: root).count, 1)
        XCTAssertEqual(try SessionEvents.insert(event, root: root).count, 1)
        var conflict = event; conflict.detail = "冲突"; XCTAssertThrowsError(try SessionEvents.insert(conflict, root: root))
    }
    func testBackupFrameTruncationAndOversizedHeader() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("frames")
        for data in [Data([0, 0, 0]), Data([0,0,0,0,0,0,0,8,1,2]), Data([255,255,255,255,255,255,255,255])] {
            try data.write(to: file)
            let handle = try FileHandle(forReadingFrom: file)
            XCTAssertThrowsError(try EncryptedBackup.readFrame(handle)); try handle.close()
        }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let output = try FileHandle(forWritingTo: file)
        let payload = Data(repeating: 42, count: 2 * 1024 * 1024 + 17)
        try EncryptedBackup.writeFrame(payload, output); try output.close()
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        XCTAssertEqual(try EncryptedBackup.readFrame(input), payload)
    }
    func testOutboundAuditPersistsBeforeResultAndRedactsDeletedSources() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let c = try clip(root), sources = ArchiveRules.excerpts([c])
        let item = OutboundRequest(service: AIService(endpoint: "https://example.invalid/chat", model: "synthetic"), question: "test", sources: sources, memories: [], contexts: [])
        try OutboundLog.begin(item, root: root)
        XCTAssertEqual(try OutboundLog.load(root).count, 1)
        try OutboundLog.redact(root: root, deleted: [c.id])
        try OutboundLog.finish(item.id, root: root)
        let saved = try OutboundLog.load(root)[0]
        XCTAssertTrue(saved.sources.isEmpty)
        XCTAssertTrue(saved.invalidated)
    }

    func testLowSpaceGuardStopsBeforeReserveAndCannotOverflow() throws {
        let reserve: UInt64 = 64 * 1024 * 1024
        XCTAssertThrowsError(try StorageGuard.requireSpace(available: reserve, bytes: 0))
        XCTAssertThrowsError(try StorageGuard.requireSpace(available: reserve + 100, bytes: 100))
        XCTAssertThrowsError(try StorageGuard.requireSpace(available: UInt64.max, bytes: UInt64.max))
        XCTAssertNoThrow(try StorageGuard.requireSpace(available: reserve + 101, bytes: 100))
    }

}
