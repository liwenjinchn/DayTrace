import Foundation

struct TranscriptionJob: Codable, Identifiable, Equatable {
    enum State: String, Codable { case pending, running, succeeded, failed, cancelled }
    var id: String { clipID + ":" + digest }
    var clipID: String
    var digest: String
    var state: State = .pending
    var attempts = 0
    var locale: String? = nil
    var failure: String? = nil
}

// The archive is authoritative. A crash after saving a transcript but before completing
// its job must never transcribe again or overwrite the saved text.
enum ProcessingQueue {
    static func reconcile(_ jobs: [TranscriptionJob], clips: [Clip], deleted: Set<String>, recovering: Bool = false) -> [TranscriptionJob] {
        var result = jobs
        for i in result.indices {
            guard let clip = clips.first(where: { $0.id == result[i].clipID }),
                  !deleted.contains(result[i].clipID), clip.digest == result[i].digest else {
                result[i].state = .cancelled; result[i].failure = nil; continue
            }
            if clip.status == "ready" { result[i].state = .succeeded; result[i].failure = nil }
            else if clip.audioExpiredAt != nil { result[i].state = .cancelled }
            else if recovering && result[i].state == .running { result[i].state = .pending }
        }
        for clip in clips where clip.status != "ready" && clip.audioExpiredAt == nil && !deleted.contains(clip.id) {
            if !result.contains(where: { $0.clipID == clip.id && $0.digest == clip.digest }) {
                result.append(TranscriptionJob(clipID: clip.id, digest: clip.digest))
            }
        }
        return result
    }
    static func load(from root: URL) throws -> [TranscriptionJob] {
        let url = root.appendingPathComponent("transcription-jobs.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let jobs = try JSONDecoder().decode([TranscriptionJob].self, from: Data(contentsOf: url))
        guard Set(jobs.map(\.id)).count == jobs.count, jobs.allSatisfy({ $0.attempts >= 0 }) else { throw ArchiveFailure.invalidClip }
        return jobs
    }
    static func save(_ jobs: [TranscriptionJob], to root: URL) throws {
        let url = root.appendingPathComponent("transcription-jobs.json")
        try JSONEncoder().encode(jobs).write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}

/// Speech may reset its result at an utterance boundary even for one audio file.
/// Keep non-overlapping earlier words, while replacing hypotheses in the revised range.
struct SpeechTranscriptAccumulator {
    private(set) var spans: [WordSpan] = []
    mutating func accept(_ incoming: [WordSpan]) {
        guard let first = incoming.first else { return }
        let prefix = spans.filter { $0.offset + $0.duration <= first.offset + 0.01 && $0.offset < first.offset }
        spans = (prefix + incoming).enumerated().map { index, span in
            var word = span; word.id = String(index); return word
        }
    }
}
