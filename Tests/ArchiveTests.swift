import XCTest
@testable import DayTraceCore

final class ArchiveTests: XCTestCase {
    func clip(_ id: String = UUID().uuidString, digest: String = String(repeating: "a", count: 64)) -> Clip {
        Clip(id: id, started: Date(timeIntervalSince1970: 100), duration: 30, marks: [4], file: id + ".m4a", digest: digest, transcript: [WordSpan(id: "0", offset: 2.5, duration: 1, text: "Delivery date confirmed")])
    }
    func testDuplicateDeliveryDoesNotEraseTranscript() throws {
        let old = clip(); var retry = old; retry.transcript = []
        XCTAssertEqual(try ArchiveRules.inserting(retry, into: [old]), [old])
        retry.digest = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try ArchiveRules.inserting(retry, into: [old]))
    }
    func testRejectsTraversalAndInvalidTimes() {
        var unsafe = clip(); unsafe.file = "../outside.m4a"
        XCTAssertThrowsError(try ArchiveRules.validate(unsafe))
        unsafe = clip(); unsafe.marks = [31]
        XCTAssertThrowsError(try ArchiveRules.validate(unsafe))
    }
    func testSearchKeepsAudioOffset() {
        let c = clip(); let results = ArchiveRules.keyword("delivery confirmed", in: ArchiveRules.excerpts([c]))
        XCTAssertEqual(results.count, 1); XCTAssertEqual(results.first?.offset, 2.5); XCTAssertEqual(results.first?.clipID, c.id)
        XCTAssertTrue(ArchiveRules.keyword("unmentioned", in: results).isEmpty)
    }
    func testChineseWordSpacingAndConflictingMetadata() throws {
        var c = clip(); c.transcript[0].text = "交付 日期 已 确认"
        XCTAssertEqual(ArchiveRules.keyword("交付日期", in: ArchiveRules.excerpts([c])).count, 1)
        var changed = c; changed.marks = [5]
        XCTAssertThrowsError(try ArchiveRules.inserting(changed, into: [c]))
    }
    func testRejectsInventedSources() throws {
        let sources = ArchiveRules.excerpts([clip()])
        XCTAssertThrowsError(try GroundedAnswer(answer: "Invented", sourceIDs: ["fake"]).checked(against: sources))
        XCTAssertThrowsError(try GroundedAnswer(answer: "Unsourced", sourceIDs: []).checked(against: sources))
        XCTAssertNoThrow(try GroundedAnswer(answer: "Confirmed", sourceIDs: [sources[0].id]).checked(against: sources))
    }
    func testAtomicArchiveRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = [clip()]; try ArchiveDisk.save(data, to: root)
        XCTAssertEqual(try ArchiveDisk.load(from: root), data)
    }
}
