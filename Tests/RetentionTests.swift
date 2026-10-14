import XCTest
@testable import DayTraceCore

final class RetentionTests: XCTestCase {
    func clip() -> Clip {
        let id = UUID().uuidString
        return Clip(id: id, started: Date(timeIntervalSince1970: 100), duration: 30, marks: [], file: id + ".m4a", digest: String(repeating: "a", count: 64), transcript: [WordSpan(id: "0", offset: 1, duration: 2, text: "原文应持续存在")], status: "ready")
    }
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testExpiryStartsAtEndAndProtectsMarkedPinnedFailedAndPlaying() {
        var c = clip(); let end = RetentionRules.expires(c)
        XCTAssertFalse(RetentionRules.eligible(c, now: end.addingTimeInterval(-1)))
        XCTAssertTrue(RetentionRules.eligible(c, now: end))
        XCTAssertFalse(RetentionRules.eligible(c, now: end, playingID: c.id))
        c.marks = [2]; XCTAssertFalse(RetentionRules.eligible(c, now: end))
        c.marks = []; c.audioPinned = true; XCTAssertFalse(RetentionRules.eligible(c, now: end))
        c.audioPinned = false; c.status = "failed"; XCTAssertFalse(RetentionRules.eligible(c, now: end))
        c.status = "ready"; c.audioExpiredAt = end; XCTAssertFalse(RetentionRules.eligible(c, now: end))
    }
    func testExpiryRetainsTranscriptAndSourceOffsetsAcrossReload() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let c = clip(); let sources = ArchiveRules.excerpts([c])
        try Data("synthetic audio".utf8).write(to: root.appendingPathComponent(c.file))
        try ArchiveDisk.save([c], to: root)
        let updated = try RetentionDisk.expire(c, from: root, archive: [c], now: RetentionRules.expires(c))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(c.file).path))
        XCTAssertEqual(ArchiveRules.excerpts(updated), sources)
        XCTAssertEqual(try ArchiveDisk.load(from: root), updated)
        XCTAssertNotNil(updated[0].audioExpiredAt)
        XCTAssertEqual(try ArchiveRules.inserting(c, into: updated), updated)
    }
    func testLegacyArchiveDecodesWithoutNewFields() throws {
        let c = clip()
        let data = try JSONEncoder().encode([c])
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        objects[0].removeValue(forKey: "audioPinned"); objects[0].removeValue(forKey: "audioExpiredAt")
        let decoded = try JSONDecoder().decode([Clip].self, from: JSONSerialization.data(withJSONObject: objects))
        XCTAssertEqual(decoded, [c])
    }
    func testDeletionTombstoneSurvivesStaleArchiveRestoration() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let c = clip(); try ArchiveDisk.save([c], to: root)
        try Data("synthetic audio".utf8).write(to: root.appendingPathComponent(c.file))
        XCTAssertTrue(try RetentionDisk.delete(c, from: root, archive: [c]).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(c.file).path))
        try ArchiveDisk.save([c], to: root) // Simulate a crash leaving an old archive snapshot.
        XCTAssertTrue(try ArchiveDisk.load(from: root).isEmpty)
        XCTAssertTrue(try RetentionDisk.deletedIDs(from: root).contains(c.id))
    }
    func testCorruptDeletionLedgerBlocksLoadAndPreservesFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let c = clip(); try ArchiveDisk.save([c], to: root)
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: root.appendingPathComponent("deleted-recordings.json"))
        XCTAssertThrowsError(try ArchiveDisk.load(from: root))
        XCTAssertThrowsError(try RetentionDisk.delete(c, from: root, archive: [c]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("deleted-recordings.json")), corrupt)
    }
    func testDailyReviewAndHistoryRoundTripRemainSeparate() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let c = clip(); let sources = ArchiveRules.excerpts([c]); let answer = GroundedAnswer(answer: "有来源的复盘", sourceIDs: [sources[0].id])
        let review = SavedDailyReview(day: c.started, answer: answer, sources: sources, totalRecordings: 1)
        try Journal.saveReviews([review], to: root)
        XCTAssertEqual(try Journal.loadReviews(from: root), [review])
        XCTAssertTrue(try Journal.load(from: root).isEmpty)
    }
    func testFailedMetadataWriteCannotDeleteAudio() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let c = clip(); let audio = root.appendingPathComponent(c.file)
        let bytes = Data("must survive".utf8); try bytes.write(to: audio)
        // An obstructed archive path makes the atomic publication fail.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("archive.json"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try RetentionDisk.expire(c, from: root, archive: [c], now: RetentionRules.expires(c)))
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
    }
    func testInterruptedExpiryCanFinishWithoutDeletingText() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var c = clip(); c.audioExpiredAt = RetentionRules.expires(c)
        try ArchiveDisk.save([c], to: root)
        try Data("residual bytes".utf8).write(to: root.appendingPathComponent(c.file))
        let updated = try RetentionDisk.expire(c, from: root, archive: [c], now: Date())
        XCTAssertEqual(updated, [c])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(c.file).path))
        XCTAssertEqual(try ArchiveDisk.load(from: root)[0].transcript, c.transcript)
    }

    func sessionClips() -> [Clip] {
        let session = UUID().uuidString
        return (0..<5).map { index in
            var c = clip(); c.started = Date(timeIntervalSince1970: Double(index * 30))
            c.sessionID = session
            if index == 1 { c.marks = [15] }
            return c
        }
    }
    func testMarkWindowClampsAcrossSessionChunks() {
        let clips = sessionClips()
        XCTAssertEqual(RetentionRules.markRanges(clips[0], archive: clips), [15..<30])
        XCTAssertEqual(RetentionRules.markRanges(clips[1], archive: clips), [0..<30])
        XCTAssertEqual(RetentionRules.markRanges(clips[2], archive: clips), [0..<30])
        XCTAssertEqual(RetentionRules.markRanges(clips[3], archive: clips), [0..<15])
        XCTAssertTrue(RetentionRules.markRanges(clips[4], archive: clips).isEmpty)
        XCTAssertFalse(RetentionRules.eligible(clips[0], now: .distantFuture, archive: clips))
        XCTAssertTrue(RetentionRules.eligible(clips[4], now: .distantFuture, archive: clips))
    }
    func testOtherKnownSessionIsNotProtectedButLegacyIsConservative() {
        var clips = sessionClips()
        clips[0].sessionID = UUID().uuidString
        XCTAssertFalse(RetentionRules.protected(clips[0], archive: clips))
        clips[0].sessionID = nil
        XCTAssertTrue(RetentionRules.protected(clips[0], archive: clips))
        clips[0].sessionID = UUID().uuidString; clips[1].sessionID = nil
        XCTAssertTrue(RetentionRules.protected(clips[0], archive: clips))
    }
    func testOverlappingMarksMergeAndBoundaryContactDoesNotProtect() {
        var clips = sessionClips(); clips[1].marks = [0, 15, 30]
        XCTAssertEqual(RetentionRules.markRanges(clips[0], archive: clips), [0..<30])
        XCTAssertTrue(RetentionRules.markRanges(clips[4], archive: clips).isEmpty)
    }
    func testCrossChunkExpiryPreservesBytesIncludingResiduals() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var clips = sessionClips()
        let audio = root.appendingPathComponent(clips[0].file)
        let bytes = Data("protected neighboring segment".utf8); try bytes.write(to: audio)
        var result = try RetentionDisk.expire(clips[0], from: root, archive: clips, now: .distantFuture)
        XCTAssertEqual(result, clips); XCTAssertEqual(try Data(contentsOf: audio), bytes)
        clips[0].audioExpiredAt = Date()
        result = try RetentionDisk.expire(clips[0], from: root, archive: clips, now: .distantFuture)
        XCTAssertEqual(result, clips); XCTAssertEqual(try Data(contentsOf: audio), bytes)
    }
    func testStaleCandidateCannotOverrideNewPinOrDeleteMissingRecordBytes() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let stale = clip(); var current = stale; current.audioPinned = true
        let audio = root.appendingPathComponent(stale.file)
        let bytes = Data("keep".utf8); try bytes.write(to: audio)
        XCTAssertEqual(try RetentionDisk.expire(stale, from: root, archive: [current], now: .distantFuture), [current])
        XCTAssertTrue(try RetentionDisk.expire(stale, from: root, archive: [], now: .distantFuture).isEmpty)
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
    }
    func testSessionRoundTripValidationAndDuplicateConflict() throws {
        let c = sessionClips()[0]
        XCTAssertEqual(try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c)), c)
        var wrong = c; wrong.sessionID = UUID().uuidString
        XCTAssertThrowsError(try ArchiveRules.inserting(wrong, into: [c]))
        wrong.sessionID = "invalid"; XCTAssertThrowsError(try ArchiveRules.validate(wrong))
        var legacy = c; legacy.sessionID = nil
        XCTAssertNil(try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(legacy)).sessionID)
    }

}
