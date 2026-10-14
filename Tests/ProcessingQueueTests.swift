import XCTest
@testable import DayTraceCore

final class ProcessingQueueTests: XCTestCase {
    func testTimeIndexedTextPreservesChineseAndEnglishSpacing() throws {
        let words = [WordSpan(id: "0", offset: 0, duration: 0.1, text: "学", joinsPrevious: true), WordSpan(id: "1", offset: 0.1, duration: 0.1, text: "习 Python ", joinsPrevious: true), WordSpan(id: "2", offset: 0.2, duration: 0.1, text: "language。", joinsPrevious: true)]
        XCTAssertEqual(WordSpan.rendered(words), "学习 Python language。")
        let old = try JSONDecoder().decode(WordSpan.self, from: Data(#"{"id":"old","offset":0,"duration":1,"text":"hello"}"#.utf8))
        XCTAssertNil(old.joinsPrevious)
        XCTAssertEqual(WordSpan.rendered([old, old]), "hello hello")
    }
    func testSpeechUtteranceResetKeepsEarlierWordsAndReplacesRevisions() {
        var accumulator = SpeechTranscriptAccumulator()
        func word(_ text: String, _ offset: Double) -> WordSpan { WordSpan(id: "old", offset: offset, duration: 0.5, text: text) }
        accumulator.accept([word("第一句", 1), word("错词", 2)])
        accumulator.accept([word("第一句", 1), word("正确", 2)])
        accumulator.accept([word("第二句", 10)])
        accumulator.accept([]) // Empty final callbacks must not erase prior speech.
        XCTAssertEqual(accumulator.spans.map(\.text), ["第一句", "正确", "第二句"])
        accumulator.accept([word("第二句修正", 10), word("结尾", 11)])
        XCTAssertEqual(accumulator.spans.map(\.text), ["第一句", "正确", "第二句修正", "结尾"])
        XCTAssertEqual(accumulator.spans.map(\.id), ["0", "1", "2", "3"])
        XCTAssertEqual(accumulator.spans.map(\.offset), [1, 2, 10, 11])
    }
    func clip() -> Clip {
        let id = UUID().uuidString
        return Clip(id: id, started: Date(), duration: 30, marks: [], file: id + ".m4a", digest: String(repeating: "a", count: 64))
    }
    func testDuplicateReceiptDoesNotDuplicateJobsAndRecoveryKeepsAttempts() {
        let c = clip()
        var jobs = ProcessingQueue.reconcile([], clips: [c], deleted: [])
        jobs[0].state = .running; jobs[0].attempts = 1
        XCTAssertEqual(ProcessingQueue.reconcile(jobs, clips: [c], deleted: []).count, 1)
        XCTAssertEqual(ProcessingQueue.reconcile(jobs, clips: [c], deleted: [])[0].state, .running)
        let recovered = ProcessingQueue.reconcile(jobs, clips: [c], deleted: [], recovering: true)
        XCTAssertEqual(recovered[0].state, .pending)
        XCTAssertEqual(recovered[0].attempts, 1)
    }
    func testTranscriptCommitBeforeJobCommitDoesNotRepeatRecognition() {
        var c = clip()
        var jobs = ProcessingQueue.reconcile([], clips: [c], deleted: [])
        jobs[0].state = .running
        c.status = "ready"; c.transcript = [WordSpan(id: "0", offset: 0, duration: 1, text: "已保存")]
        XCTAssertEqual(ProcessingQueue.reconcile(jobs, clips: [c], deleted: [], recovering: true)[0].state, .succeeded)
    }
    func testDeletionWinsOverRecoveryEvenWithStaleArchive() {
        let c = clip()
        var jobs = ProcessingQueue.reconcile([], clips: [c], deleted: [])
        jobs[0].state = .running
        let result = ProcessingQueue.reconcile(jobs, clips: [c], deleted: [c.id], recovering: true)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].state, .cancelled)
        XCTAssertTrue(ProcessingQueue.reconcile([], clips: [c], deleted: [c.id]).isEmpty)
    }
    func testFailedJobDoesNotAutomaticallyRetryAndChangedInputCancelsOldJob() {
        var c = clip()
        var jobs = ProcessingQueue.reconcile([], clips: [c], deleted: [])
        jobs[0].state = .failed; jobs[0].failure = "unavailable"
        XCTAssertEqual(ProcessingQueue.reconcile(jobs, clips: [c], deleted: [], recovering: true)[0].state, .failed)
        c.digest = String(repeating: "b", count: 64)
        let revised = ProcessingQueue.reconcile(jobs, clips: [c], deleted: [])
        XCTAssertEqual(revised.map(\.state), [.cancelled, .pending])
    }
    func testRoundTripAndCorruptQueueRemainsUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = ProcessingQueue.reconcile([], clips: [clip()], deleted: [])
        try ProcessingQueue.save(jobs, to: root)
        XCTAssertEqual(try ProcessingQueue.load(from: root), jobs)
        let url = root.appendingPathComponent("transcription-jobs.json")
        let damaged = Data("broken archive".utf8)
        try damaged.write(to: url)
        XCTAssertThrowsError(try ProcessingQueue.load(from: root))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        try ProcessingQueue.save(jobs + jobs, to: root)
        XCTAssertThrowsError(try ProcessingQueue.load(from: root))
    }
    func testFailedAtomicSavePreservesPreviousJobs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = ProcessingQueue.reconcile([], clips: [clip()], deleted: [])
        try ProcessingQueue.save(jobs, to: root)
        // A non-directory parent deterministically models an unavailable storage target.
        let blockedRoot = root.appendingPathComponent("transcription-jobs.json")
        XCTAssertThrowsError(try ProcessingQueue.save([], to: blockedRoot))
        XCTAssertEqual(try ProcessingQueue.load(from: root), jobs)
    }

}
