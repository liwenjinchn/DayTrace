import Foundation

struct SavedConversation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var created: Date = Date()
    var question: String
    var answer: GroundedAnswer
    var sources: [SourceExcerpt]
    var invalidatedSourceIDs: [String]? = nil
    var contexts: [ContextSample]? = nil
    var memories: [MemoryContext]? = nil
    var invalidatedMemoryIDs: [UUID]? = nil
}

struct SavedDailyReview: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var day: Date
    var created: Date = Date()
    var answer: GroundedAnswer
    var sources: [SourceExcerpt]
    var invalidatedSourceIDs: [String]? = nil
    var totalRecordings: Int
    var automaticJobID: UUID? = nil
    var inputVersion: String? = nil
    var totalSources: Int? = nil
    var pendingRecordings: Int? = nil
    var sourceTimeZone: String? = nil
    // Staged response for crash recovery; cleared after idempotent memory ingestion.
    var memoryCandidates: [MemoryCandidate]? = nil
    var userText: String? = nil
    var userEditedAt: Date? = nil
    var contexts: [ContextSample]? = nil
    var highlightCandidates: [HighlightCandidate]? = nil
    var dayVersion: String? = nil
    var batchIndex: Int? = nil
    var batchCount: Int? = nil
}

enum Journal {
    static func dailySources(_ clips: [Clip], day: Date, calendar: Calendar = .current) -> [SourceExcerpt] {
        ArchiveRules.excerpts(clips.filter { TimelineRules.seconds($0, day: day, calendar: calendar) > 0 }.sorted { $0.started < $1.started }).filter { calendar.isDate($0.started.addingTimeInterval($0.offset), inSameDayAs: day) }
    }
    static func markdown(_ clips: [Clip], day: Date, calendar: Calendar = .current) -> String {
        let daily = clips.filter { TimelineRules.seconds($0, day: day, calendar: calendar) > 0 }.sorted { $0.started < $1.started }
        var lines = ["# DayTrace · \(day.formatted(date: .complete, time: .omitted))", "", "Recordings: \(daily.count) · Duration: \(Int(daily.reduce(0) { $0 + TimelineRules.seconds($1, day: day, calendar: calendar) }))s", ""]
        for clip in daily {
            lines += ["## \(clip.started.formatted(date: .omitted, time: .standard))", "", "Recording ID: \(clip.id)", ""]
            if clip.transcript.isEmpty { lines += ["Transcript unavailable (\(clip.status)).", ""] }
            for word in clip.transcript where calendar.isDate(clip.started.addingTimeInterval(word.offset), inSameDayAs: day) {
                lines.append(String(format: "[%02d:%02d] %@", Int(word.offset) / 60, Int(word.offset) % 60, word.text))
            }
            if !clip.marks.isEmpty { lines += ["", "Marks: " + clip.marks.map { String(format: "%.1fs", $0) }.joined(separator: ", ")] }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
    static func load(from root: URL) throws -> [SavedConversation] {
        let url = root.appendingPathComponent("conversations.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SavedConversation].self, from: Data(contentsOf: url))
    }
    static func save(_ items: [SavedConversation], to root: URL) throws {
        let url = root.appendingPathComponent("conversations.json")
        try JSONEncoder().encode(items).write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    static func loadReviews(from root: URL) throws -> [SavedDailyReview] {
        let url = root.appendingPathComponent("daily-reviews.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([SavedDailyReview].self, from: Data(contentsOf: url))
    }
    static func saveReviews(_ items: [SavedDailyReview], to root: URL) throws {
        let url = root.appendingPathComponent("daily-reviews.json")
        try JSONEncoder().encode(items).write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

}
