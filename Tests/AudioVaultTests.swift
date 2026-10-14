import XCTest
import AVFoundation
@testable import DayTraceCore

final class AudioVaultTests: XCTestCase {
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    // Generate actual PCM test audio, read it with the same AVAudioFile path used in production.
    func audio(_ root: URL, start: Double = 0, session: String? = nil, index: Int? = nil) throws -> Clip {
        let id = UUID().uuidString
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for n in 0..<48000 { buffer.floatChannelData![0][n] = Float(sin(Double(n) * 0.1)) * 0.2 }
        let target = root.appendingPathComponent(id + ".m4a")
        do {
            let file = try AVAudioFile(forWriting: target, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
            try file.write(from: buffer)
        }
        return Clip(id: id, started: Date(timeIntervalSince1970: start), duration: 3, marks: [], file: id + ".m4a",
                    digest: AudioVault.hash(try Data(contentsOf: target)),
                    transcript: [WordSpan(id: "1", offset: 0.5, duration: 1, text: "明天讨论设计方案")], status: "ready", sessionID: session ?? UUID().uuidString, sessionIndex: index)
    }
    func testRealAudioExtractValidateExpireAndReplay() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var clip = try audio(root); clip.marks = [1]
        var state = AudioVaultState(); state.markBefore = 0.25; state.markAfter = 0.5
        let range = AudioVault.ranges(clip, archive: [clip], state: state)[0]
        XCTAssertEqual(range, 0.75..<1.5)
        XCTAssertFalse(AudioVault.canExpire(clip, archive: [clip], state: state, root: root, now: .distantFuture, playingID: nil))
        let slice = try AudioSlicer.extract(clip, range: range, root: root)
        state.slices = [slice]; try AudioVault.save(state, root); try ArchiveDisk.save([clip], to: root)
        let file = try AVAudioFile(forReading: root.appendingPathComponent(slice.file))
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 0.75, accuracy: 0.001)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let original = try AVAudioFile(forReading: root.appendingPathComponent(clip.file))
        original.framePosition = 12000
        let expected = AVAudioPCMBuffer(pcmFormat: original.processingFormat, frameCapacity: 1)!
        try original.read(into: expected, frameCount: 1)
        XCTAssertEqual(buffer.floatChannelData![0][0], expected.floatChannelData![0][0], accuracy: 0.0001)
        let expired = try RetentionDisk.expire(clip, from: root, archive: [clip], now: .distantFuture)
        XCTAssertNotNil(expired[0].audioExpiredAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(clip.file).path))
        XCTAssertTrue(AudioVault.verified(slice, root: root))
        XCTAssertEqual(expired[0].transcript, clip.transcript)
        XCTAssertEqual(try AudioVault.load(root), state)
        // Source deletion also removes retained audio and metadata.
        _ = try RetentionDisk.delete(expired[0], from: root, archive: expired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(slice.file).path))
        XCTAssertTrue(try AudioVault.load(root).slices.isEmpty)
    }
    func testIncompleteSessionAndReorderedSealNeverEnableEarlyExpiry() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID().uuidString
        let first = try audio(root, session: session, index: 0)
        let second = try audio(root, start: 3, session: session, index: 1)
        var state = AudioVaultState()
        XCTAssertFalse(AudioVault.complete(first, archive: [first, second], state: state, deleted: []))
        try AudioVault.seal(SessionSeal(id: session, count: 2), state: &state)
        XCTAssertFalse(AudioVault.complete(first, archive: [first], state: state, deleted: []))
        XCTAssertTrue(AudioVault.complete(first, archive: [second, first], state: state, deleted: []))
        XCTAssertThrowsError(try AudioVault.seal(SessionSeal(id: session, count: 3), state: &state))
        var duplicate = second; duplicate.sessionIndex = 0
        XCTAssertThrowsError(try ArchiveRules.inserting(duplicate, into: [first]))
        try AudioVault.save(state, root)
        XCTAssertEqual(try RetentionDisk.expire(first, from: root, archive: [first], now: .distantFuture), [first])
    }
    func testCrossFileMarkExtractionAndOverlappingFavoriteShareRanges() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID().uuidString
        var first = try audio(root, session: session); first.marks = [2.5]
        let second = try audio(root, start: 3, session: session)
        let archive = [first, second]
        var state = AudioVaultState(); state.markBefore = 0.5; state.markAfter = 1.5
        XCTAssertEqual(AudioVault.ranges(first, archive: archive, state: state), [2..<3])
        XCTAssertEqual(AudioVault.ranges(second, archive: archive, state: state), [0..<1])
        for clip in archive {
            state.slices.append(try AudioSlicer.extract(clip, range: AudioVault.ranges(clip, archive: archive, state: state)[0], root: root))
        }
        XCTAssertEqual(state.slices.count, 2)
        let source = ArchiveRules.excerpts([first])[0]
        let c = HighlightCandidate(title: "设计讨论", sourceID: source.id, quote: source.text)
        AudioVault.ingest([c, c], sources: [source], clips: archive, state: &state)
        XCTAssertEqual(state.highlights.count, 1)
        XCTAssertFalse(state.highlights[0].favorite)
        state.highlights[0].favorite = true; state.highlights[0].before = 0; state.highlights[0].after = 1
        XCTAssertEqual(AudioVault.ranges(first, archive: archive, state: state), [0.5..<3])
        state.highlights[0].favorite = false
        XCTAssertEqual(AudioVault.ranges(first, archive: archive, state: state), [2..<3])
    }
    func testBadSliceOrSourceDigestNeverReleasesOriginal() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var clip = try audio(root); clip.audioPinned = true
        var state = AudioVaultState()
        let slice = try AudioSlicer.extract(clip, range: 0..<3, root: root); state.slices = [slice]
        try Data("corrupt".utf8).write(to: root.appendingPathComponent(slice.file))
        try AudioVault.save(state, root)
        XCTAssertEqual(try RetentionDisk.expire(clip, from: root, archive: [clip], now: .distantFuture), [clip])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(clip.file).path))
        clip.digest = String(repeating: "f", count: 64)
        XCTAssertThrowsError(try AudioSlicer.extract(clip, range: 0..<1, root: root))
    }
    func testQuoteTimingDismissalAndSourceInvalidation() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clip = try audio(root), sources = ArchiveRules.excerpts([clip])
        let candidate = HighlightCandidate(title: "设计讨论", sourceID: sources[0].id, quote: sources[0].text)
        var state = AudioVaultState()
        AudioVault.ingest([candidate], sources: sources, clips: [clip], state: &state)
        XCTAssertEqual(state.highlights[0].start, 0.5); XCTAssertEqual(state.highlights[0].end, 1.5)
        XCTAssertTrue(AudioVault.ranges(clip, archive: [clip], state: state).isEmpty)
        var invalid = candidate; invalid.quote = "没有说过的话"
        XCTAssertNil(AudioVault.candidate(invalid, sources: sources, clips: [clip]))
        AudioVault.reconcile(&state, clips: [])
        XCTAssertTrue(state.highlights.isEmpty)
        AudioVault.ingest([candidate], sources: sources, clips: [clip], state: &state)
        XCTAssertTrue(state.highlights.isEmpty)
    }
    func testPurposeConsentAndWireAreIndependentFromMemory() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clip = try audio(root), sources = ArchiveRules.excerpts([clip])
        let service = AIService(endpoint: "https://example.invalid/chat", model: "test")
        let request = try AIWire.request(service: service, key: "synthetic", question: "复盘", sources: sources, generateHighlights: true)
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("highlights")); XCTAssertFalse(body.contains("Also return memories"))
        let payload: [String: Any] = ["answer": "讨论设计", "sourceIDs": [sources[0].id], "highlights": [["title": "设计", "sourceID": sources[0].id, "quote": sources[0].text]]]
        let content = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        XCTAssertTrue(try AIWire.decode(data, sources: sources).highlightCandidates.isEmpty)
        XCTAssertEqual(try AIWire.decode(data, sources: sources, generateHighlights: true).highlightCandidates.count, 1)
        let old = try ReviewInput.candidates(clips: [clip], now: .distantFuture)
        let new = try ReviewInput.candidates(clips: [clip], now: .distantFuture, generateHighlights: true)
        XCTAssertNotEqual(old[0].version, new[0].version)
        XCTAssertNil(old[0].generateHighlights)
    }
    func testCorruptVaultAndDeletedSourceBlockDestructiveOperations() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clip = try audio(root)
        let bytes = Data("bad ledger".utf8)
        try bytes.write(to: root.appendingPathComponent("audio-vault.json"))
        XCTAssertThrowsError(try RetentionDisk.expire(clip, from: root, archive: [clip], now: .distantFuture))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("audio-vault.json")), bytes)
        try JSONEncoder().encode(Set([clip.id])).write(to: root.appendingPathComponent("deleted-recordings.json"))
        XCTAssertThrowsError(try AudioSlicer.extract(clip, range: 0..<1, root: root))
    }
    func testNarrowerRangeCanBeCutAfterOriginalExpires() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var clip = try audio(root); clip.audioPinned = true
        var state = AudioVaultState()
        state.slices = [try AudioSlicer.extract(clip, range: 0..<3, root: root)]
        try AudioVault.save(state, root)
        _ = try RetentionDisk.expire(clip, from: root, archive: [clip], now: .distantFuture)
        let narrower = try AudioSlicer.extract(clip, range: 1..<2, root: root)
        let audio = try AVAudioFile(forReading: root.appendingPathComponent(narrower.file))
        XCTAssertEqual(Double(audio.length) / audio.processingFormat.sampleRate, 1, accuracy: 0.001)
        XCTAssertTrue(AudioVault.verified(narrower, root: root))
        XCTAssertThrowsError(try AudioSlicer.extract(clip, range: 0..<4, root: root))
    }
    func testStagedHighlightReplayPreservesUserChoiceAndHonorsTombstones() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clip = try audio(root), sources = ArchiveRules.excerpts([clip])
        let candidate = HighlightCandidate(title: "设计", sourceID: sources[0].id, quote: sources[0].text)
        let review = SavedDailyReview(day: clip.started, answer: GroundedAnswer(answer: "设计", sourceIDs: [sources[0].id]), sources: sources, totalRecordings: 1, highlightCandidates: [candidate])
        // Force second publication to fail after the highlight ledger is committed.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("daily-reviews.json"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try AudioVault.replay(reviews: [review], clips: [clip], root: root))
        var state = try AudioVault.load(root); XCTAssertEqual(state.highlights.count, 1)
        state.highlights[0].favorite = true; state.highlights[0].before = 5
        try AudioVault.save(state, root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("daily-reviews.json"))
        let replay = try AudioVault.replay(reviews: [review], clips: [clip], root: root)
        XCTAssertEqual(replay.0.highlights.count, 1); XCTAssertTrue(replay.0.highlights[0].favorite)
        XCTAssertEqual(replay.0.highlights[0].before, 5); XCTAssertNil(replay.1[0].highlightCandidates)
        try JSONEncoder().encode(Set([clip.id])).write(to: root.appendingPathComponent("deleted-recordings.json"))
        XCTAssertTrue(try AudioVault.replay(reviews: [review], clips: [clip], root: root).0.highlights.isEmpty)
    }
    func testOrphanRecoveryRemovesOnlyUnpublishedSliceFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clip = try audio(root)
        let orphan = try AudioSlicer.extract(clip, range: 0..<1, root: root)
        let kept = try AudioSlicer.extract(clip, range: 1..<2, root: root)
        var state = AudioVaultState(); state.slices = [kept]; try AudioVault.save(state, root)
        try AudioVault.removeOrphans(root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(orphan.file).path))
        XCTAssertTrue(AudioVault.verified(kept, root: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(clip.file).path))
    }
    @MainActor func testAuthorizedRunnerPublishesHighlightsWithOneReservation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clip = try audio(root), source = ArchiveRules.excerpts([clip])[0]
        let service = AIService(endpoint: "https://example.invalid/chat", model: "test")
        let input = try ReviewInput.candidates(clips: [clip], now: .distantFuture, generateHighlights: true)[0]
        let runner = AutomaticReviewRunner(root: root)
        try runner.approve(service: service, limit: 1, now: Date(), generateHighlights: true)
        var saved: [SavedDailyReview] = []
        try await runner.run(service: { service }, inputs: { [input] }, completed: { Set(saved.compactMap(\.automaticJobID)) }, deleted: { [] }, ready: { true }, send: { _, sources, memories, highlights, _ in
            XCTAssertFalse(memories); XCTAssertTrue(highlights)
            XCTAssertEqual(try AutomaticReviewDisk.load(from: root).requests.count, 1)
            let payload: [String: Any] = ["answer": "设计", "sourceIDs": [source.id], "highlights": [["title": "设计讨论", "sourceID": source.id, "quote": source.text]]]
            let content = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            return try AIWire.decode(JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]), sources: sources, generateHighlights: highlights)
        }, publish: { job, reply in
            let review = SavedDailyReview(day: clip.started, answer: reply.answer, sources: job.input.sources, totalRecordings: 1, automaticJobID: job.id, highlightCandidates: reply.highlightCandidates)
            try Journal.saveReviews([review], to: root)
            saved = try AudioVault.replay(reviews: [review], clips: [clip], root: root).1
        })
        XCTAssertEqual(runner.state.requests.count, 1)
        XCTAssertEqual(runner.state.requests[0].generateHighlights, true)
        XCTAssertEqual(try AudioVault.load(root).highlights.count, 1)
        XCTAssertFalse(try AudioVault.load(root).highlights[0].favorite)
    }

    func testUnfavoriteRestoresExpiryWithoutRemovingOtherMark() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var clip = try audio(root); clip.marks = [2.5]
        let source = ArchiveRules.excerpts([clip])[0]
        var state = AudioVaultState(); state.markBefore = 0.5; state.markAfter = 0.5
        AudioVault.ingest([HighlightCandidate(title: "设计", sourceID: source.id, quote: source.text)], sources: [source], clips: [clip], state: &state)
        state.highlights[0].favorite = true; state.highlights[0].before = 0; state.highlights[0].after = 0
        let favorite = try AudioSlicer.extract(clip, range: 0.5..<1.5, root: root)
        let mark = try AudioSlicer.extract(clip, range: 2..<3, root: root)
        state.slices = [favorite, mark]; try AudioVault.save(state, root)
        state.highlights[0].favorite = false; try AudioVault.save(state, root)
        XCTAssertEqual(try AudioVault.prune(root: root, clips: [clip], now: clip.started, playingID: nil).slices.count, 2)
        XCTAssertEqual(try AudioVault.prune(root: root, clips: [clip], now: .distantFuture, playingID: clip.id).slices.count, 2)
        XCTAssertEqual(try AudioVault.prune(root: root, clips: [clip], now: .distantFuture, playingID: nil).slices, [mark])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(favorite.file).path))
        XCTAssertTrue(AudioVault.verified(mark, root: root))
    }
    func testCompactionRequiresVerifiedExactReplacementAndRespectsPlayback() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var clip = try audio(root); clip.marks = [2.5]
        var state = AudioVaultState(); state.markBefore = 0.5; state.markAfter = 0.5
        let broad = try AudioSlicer.extract(clip, range: 0..<3, root: root)
        state.slices = [broad]; try AudioVault.save(state, root)
        XCTAssertEqual(try AudioVault.compact(root: root, clips: [clip], playingID: nil).slices, [broad])
        let narrow = try AudioSlicer.extract(clip, range: 2..<3, root: root)
        state.slices.append(narrow); try AudioVault.save(state, root)
        XCTAssertEqual(try AudioVault.compact(root: root, clips: [clip], playingID: clip.id).slices.count, 2)
        XCTAssertEqual(try AudioVault.compact(root: root, clips: [clip], playingID: nil).slices, [narrow])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(broad.file).path))
        XCTAssertTrue(AudioVault.verified(narrow, root: root))
    }

    func testExplicitMarkCancellationReleasesOnlyItsOwnClaim() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        var clip = try audio(root); clip.marks = [1]
        var state = AudioVaultState()
        XCTAssertFalse(AudioVault.ranges(clip, archive: [clip], state: state).isEmpty)
        state.disabledMarks = [clip.id + ":mark:0"]
        XCTAssertTrue(AudioVault.ranges(clip, archive: [clip], state: state).isEmpty)
        clip.audioPinned = true
        XCTAssertFalse(AudioVault.ranges(clip, archive: [clip], state: state).isEmpty)
        try AudioVault.save(state, root)
        XCTAssertEqual(try AudioVault.load(root).disabledMarks, state.disabledMarks)
    }

}
