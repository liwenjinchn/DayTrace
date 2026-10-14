import Foundation

struct WordSpan: Codable, Identifiable, Equatable {
    var id: String
    var offset: Double
    var duration: Double
    var text: String
    // New time-indexed results preserve their own spacing; old archives retain word separators.
    var joinsPrevious: Bool? = nil
    var originalText: String? = nil
    var userEditedAt: Date? = nil
    static func rendered(_ spans: [WordSpan]) -> String {
        spans.enumerated().map { index, word in
            (index > 0 && word.joinsPrevious != true ? " " : "") + word.text
        }.joined()
    }
}

struct Clip: Codable, Identifiable, Equatable {
    var id: String
    var started: Date
    var duration: Double
    var marks: [Double]
    var file: String
    var digest: String
    var transcript: [WordSpan] = []
    var status: String = "waiting"
    var failure: String? = nil
    // Optional fields decode older archives without a destructive migration.
    var audioExpiredAt: Date? = nil
    var audioPinned: Bool? = nil
    var sessionID: String? = nil
    var sessionIndex: Int? = nil
    var statusLabel: String { ["waiting": "等待转写", "ready": "已转写", "failed": "转写失败"][status] ?? status }
    var text: String { WordSpan.rendered(transcript) }
}

struct SourceExcerpt: Codable, Identifiable, Equatable {
    var id: String
    var clipID: String
    var offset: Double
    var text: String
    var started: Date
}

struct GroundedAnswer: Codable, Equatable {
    var answer: String
    var sourceIDs: [String]
    func checked(against sources: [SourceExcerpt]) throws -> GroundedAnswer {
        let allowed = Set(sources.map(\.id))
        guard Set(sourceIDs).isSubset(of: allowed), !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceIDs.isEmpty else { throw ArchiveFailure.invalidSources }
        return self
    }
}

enum ArchiveFailure: LocalizedError {
    case invalidSources, duplicateConflict, invalidClip, deletedRecording
    var errorDescription: String? {
        switch self {
        case .deletedRecording: return "这条记录已删除，旧任务不能重新写入。"
        case .invalidSources: return "The AI response has missing or unknown sources."
        case .duplicateConflict: return "Conflicting audio arrived with the same recording ID."
        case .invalidClip: return "Invalid recording metadata."
        }
    }
}

enum ArchiveRules {
    static func validate(_ clip: Clip) throws {
        guard UUID(uuidString: clip.id) != nil, clip.file == clip.id + ".m4a",
              clip.sessionID.map({ UUID(uuidString: $0) != nil }) ?? true,
              (clip.sessionIndex == nil || (clip.sessionID != nil && clip.sessionIndex! >= 0)),
              clip.started.timeIntervalSince1970.isFinite, clip.duration.isFinite, clip.duration > 0, clip.duration <= 90,
              clip.marks.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= clip.duration }),
              clip.digest.count == 64, clip.digest.allSatisfy({ $0.isHexDigit }) else { throw ArchiveFailure.invalidClip }
    }
    static func inserting(_ clip: Clip, into archive: [Clip]) throws -> [Clip] {
        try validate(clip)
        if let old = archive.first(where: { $0.id == clip.id }) {
            guard old.digest == clip.digest, old.started == clip.started, old.duration == clip.duration,
                  old.marks == clip.marks, old.file == clip.file, old.sessionID == clip.sessionID, old.sessionIndex == clip.sessionIndex else { throw ArchiveFailure.duplicateConflict }
            return archive
        }
        if let index = clip.sessionIndex, archive.contains(where: { $0.sessionID == clip.sessionID && $0.sessionIndex == index }) { throw ArchiveFailure.duplicateConflict }
        return (archive + [clip]).sorted { $0.started > $1.started }
    }
    static func excerpts(_ clips: [Clip]) -> [SourceExcerpt] {
        clips.flatMap { clip in
            // Keep retrieval and playback tied to the same stable word offsets.
            var result: [SourceExcerpt] = []
            var start = 0
            while start < clip.transcript.count {
                let day = Calendar.current.startOfDay(for: clip.started.addingTimeInterval(clip.transcript[start].offset))
                var end = start + 1
                while end < min(start + 40, clip.transcript.count), Calendar.current.isDate(clip.started.addingTimeInterval(clip.transcript[end].offset), inSameDayAs: day) { end += 1 }
                let words = Array(clip.transcript[start..<end])
                result.append(SourceExcerpt(id: "\(clip.id):\(start)", clipID: clip.id, offset: words.first?.offset ?? 0,
                    text: WordSpan.rendered(words), started: clip.started))
                start = end
            }
            return result
        }
    }
    static func keyword(_ query: String, in sources: [SourceExcerpt]) -> [SourceExcerpt] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        return sources.filter { source in
            let text = source.text.lowercased()
            let compact = text.filter { !$0.isWhitespace }
            return terms.allSatisfy { text.contains($0) || compact.contains($0) }
        }
    }
}

enum ArchiveDisk {
    static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var root = base.appendingPathComponent("DayTrace", isDirectory: true)
        try EncryptedBackup.recover(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        return root
    }
    static func load(from root: URL) throws -> [Clip] {
        let file = root.appendingPathComponent("archive.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let deleted = try RetentionDisk.deletedIDs(from: root)
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: file))
        guard Set(clips.map(\.id)).count == clips.count else { throw ArchiveFailure.invalidClip }
        for clip in clips { try ArchiveRules.validate(clip) }
        return clips.filter { !deleted.contains($0.id) }
    }
    static func save(_ clips: [Clip], to root: URL) throws {
        try JSONEncoder().encode(clips).write(to: root.appendingPathComponent("archive.json"), options: .atomic)
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.appendingPathComponent("archive.json").path)
        #endif
    }
}
