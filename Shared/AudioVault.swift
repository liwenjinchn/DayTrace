import Foundation
import CryptoKit

struct SessionSeal: Codable, Equatable { var id: String; var count: Int }
struct HighlightCandidate: Codable, Equatable { var title: String; var sourceID: String; var quote: String }
struct AudioHighlight: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var source: SourceExcerpt
    var start: Double
    var end: Double
    var favorite = false
    var before: Double = 15
    var after: Double = 15
}
struct AudioSlice: Codable, Equatable, Identifiable {
    var id: String
    var clipID: String
    var start: Double
    var end: Double
    var digest: String
    var sourceDigest: String
    var file: String { "retained-\(id).caf" }
}
struct AudioVaultState: Codable, Equatable {
    var seals: [SessionSeal] = []
    var highlights: [AudioHighlight] = []
    var slices: [AudioSlice] = []
    var dismissed: Set<String> = []
    var disabledMarks: Set<String>? = nil
    var markBefore: Double = 30
    var markAfter: Double = 60
}

enum AudioVault {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func load(_ root: URL) throws -> AudioVaultState {
        let url = root.appendingPathComponent("audio-vault.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return AudioVaultState() }
        let value = try JSONDecoder().decode(AudioVaultState.self, from: Data(contentsOf: url))
        try validate(value); return value
    }
    static func validate(_ value: AudioVaultState) throws {
        guard (0...120).contains(value.markBefore), (0...120).contains(value.markAfter), value.markBefore + value.markAfter > 0,
              Set(value.seals.map(\.id)).count == value.seals.count,
              value.seals.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.count > 0 }),
              Set(value.highlights.map(\.id)).count == value.highlights.count,
              value.highlights.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && (0...120).contains($0.before) && (0...120).contains($0.after) }),
              value.slices.allSatisfy({ UUID(uuidString: $0.id) != nil && UUID(uuidString: $0.clipID) != nil && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.digest.count == 64 }) else { throw ArchiveFailure.invalidClip }
    }
    static func save(_ value: AudioVaultState, _ root: URL) throws {
        try validate(value)
        let url = root.appendingPathComponent("audio-vault.json")
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    static func seal(_ seal: SessionSeal, state: inout AudioVaultState) throws {
        guard UUID(uuidString: seal.id) != nil, seal.count > 0 else { throw ArchiveFailure.invalidClip }
        if let old = state.seals.first(where: { $0.id == seal.id }) {
            guard old == seal else { throw ArchiveFailure.duplicateConflict }; return
        }
        state.seals.append(seal)
    }
    static func complete(_ clip: Clip, archive: [Clip], state: AudioVaultState, deleted: Set<String>) -> Bool {
        // Old archives and phone imports predate the numbered Watch protocol.
        guard clip.sessionIndex != nil else { return true }
        guard let seal = state.seals.first(where: { $0.id == clip.sessionID }) else { return false }
        let members = archive.filter { $0.sessionID == clip.sessionID }
        let indexes = members.compactMap(\.sessionIndex)
        // Deleted members are absent: conservatively retain the rest of this session.
        return members.count == seal.count && Set(indexes).count == seal.count && indexes.allSatisfy { (0..<seal.count).contains($0) }
    }
    static func merged(_ ranges: [Range<Double>]) -> [Range<Double>] {
        var result: [Range<Double>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, r.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else { result.append(r) }
        }
        return result
    }
    static func ranges(_ clip: Clip, archive: [Clip], state: AudioVaultState) -> [Range<Double>] {
        if clip.audioPinned == true { return [0..<clip.duration] }
        var result: [Range<Double>] = []
        func append(_ source: Clip, _ start: Double, _ end: Double) {
            if let a = clip.sessionID, let b = source.sessionID, a != b { return }
            let shift = source.started.timeIntervalSince(clip.started)
            let lower = max(0, shift + start), upper = min(clip.duration, shift + end)
            if lower < upper { result.append(lower..<upper) }
        }
        for source in archive {
            for (index, mark) in source.marks.enumerated() where !(state.disabledMarks ?? []).contains("\(source.id):mark:\(index)") { append(source, mark - state.markBefore, mark + state.markAfter) }
        }
        for h in state.highlights where h.favorite {
            if let source = archive.first(where: { $0.id == h.source.clipID }), ArchiveRules.excerpts([source]).contains(h.source) {
                append(source, h.start - h.before, h.end + h.after)
            }
        }
        return merged(result)
    }
    static func covered(_ range: Range<Double>, slices: [AudioSlice]) -> Bool {
        merged(slices.map { $0.start..<$0.end }).contains { $0.lowerBound <= range.lowerBound + 0.001 && $0.upperBound >= range.upperBound - 0.001 }
    }
    static func verified(_ slice: AudioSlice, root: URL) -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(slice.file)) else { return false }
        return hash(data) == slice.digest
    }
    static func canExpire(_ clip: Clip, archive: [Clip], state: AudioVaultState, root: URL, now: Date, playingID: String?) -> Bool {
        guard clip.status == "ready", playingID != clip.id, RetentionRules.expires(clip) <= now,
              complete(clip, archive: archive, state: state, deleted: []) else { return false }
        // Preserve legacy original files until metadata can prove a precise session boundary.
        let required = ranges(clip, archive: archive, state: state)
        if clip.sessionID == nil && !required.isEmpty { return false }
        let slices = state.slices.filter { $0.clipID == clip.id && $0.sourceDigest == clip.digest && verified($0, root: root) }
        return required.allSatisfy { covered($0, slices: slices) }
    }
    static func candidate(_ candidate: HighlightCandidate, sources: [SourceExcerpt], clips: [Clip]) -> AudioHighlight? {
        guard !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, candidate.title.count <= 160,
              candidate.quote.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4,
              let source = sources.first(where: { $0.id == candidate.sourceID }), source.text.contains(candidate.quote),
              let clip = clips.first(where: { $0.id == source.clipID }), ArchiveRules.excerpts([clip]).contains(source),
              let index = Int(source.id.split(separator: ":").last ?? ""), index >= 0, index < clip.transcript.count else { return nil }
        let words = Array(clip.transcript[index..<min(index + 40, clip.transcript.count)])
        let text = words.map(\.text).joined(separator: " ") as NSString
        let match = text.range(of: candidate.quote)
        guard match.location != NSNotFound else { return nil }
        var cursor = 0; var selected: [WordSpan] = []
        for word in words {
            let length = (word.text as NSString).length
            if NSIntersectionRange(NSRange(location: cursor, length: length), match).length > 0 { selected.append(word) }
            cursor += length + 1
        }
        guard let first = selected.first, let last = selected.last,
              first.offset.isFinite, last.offset.isFinite, last.duration.isFinite else { return nil }
        let start = max(0, first.offset), end = min(clip.duration, last.offset + last.duration)
        guard start < end else { return nil }
        let id = hash(Data((source.id + "|" + candidate.quote).utf8))
        return AudioHighlight(id: id, title: candidate.title, source: source, start: start, end: end)
    }
    static func ingest(_ candidates: [HighlightCandidate], sources: [SourceExcerpt], clips: [Clip], state: inout AudioVaultState) {
        for c in candidates {
            guard let h = candidate(c, sources: sources, clips: clips), !state.dismissed.contains(h.id), !state.highlights.contains(where: { $0.id == h.id }) else { continue }
            state.highlights.append(h)
        }
    }
    static func reconcile(_ state: inout AudioVaultState, clips: [Clip]) {
        let sources = ArchiveRules.excerpts(clips)
        for h in state.highlights where !sources.contains(h.source) { state.dismissed.insert(h.id) }
        state.highlights.removeAll { !sources.contains($0.source) }
    }
    static func compact(root: URL, clips: [Clip], playingID: String?) throws -> AudioVaultState {
        var next = try load(root)
        for clip in clips where playingID != clip.id {
            let ranges = AudioVault.ranges(clip, archive: clips, state: next)
            guard !ranges.isEmpty else { continue }
            let valid = next.slices.filter { $0.clipID == clip.id && $0.sourceDigest == clip.digest && AudioVault.verified($0, root: root) }
            let keep = ranges.compactMap { range in valid.first { $0.start == range.lowerBound && $0.end == range.upperBound }?.id }
            guard keep.count == ranges.count else { continue }
            for slice in next.slices.filter({ $0.clipID == clip.id && !keep.contains($0.id) }) {
                let url = root.appendingPathComponent(slice.file)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                next.slices.removeAll { $0.id == slice.id }
            }
        }
        try save(next, root); return next
    }
    static func prune(root: URL, clips: [Clip], now: Date, playingID: String?) throws -> AudioVaultState {
        let state = try load(root)
        var next = state
        for slice in state.slices {
            guard playingID != slice.clipID, let clip = clips.first(where: { $0.id == slice.clipID }), RetentionRules.expires(clip) <= now else { continue }
            let required = AudioVault.ranges(clip, archive: clips, state: state)
            guard !required.contains(where: { $0.lowerBound < slice.end && $0.upperBound > slice.start }) else { continue }
            let url = root.appendingPathComponent(slice.file)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            next.slices.removeAll { $0.id == slice.id }
        }
        try save(next, root); return next
    }
    static func removeOrphans(_ root: URL) throws {
        let state = try load(root)
        let known = Set(state.slices.map(\.file))
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            guard name.hasPrefix("retained-"), name.hasSuffix(".caf"), !known.contains(name),
                  UUID(uuidString: String(name.dropFirst(9).dropLast(4))) != nil else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }
    static func replay(reviews: [SavedDailyReview], clips: [Clip], root: URL) throws -> (AudioVaultState, [SavedDailyReview]) {
        var next = try load(root), cleared = reviews
        let deleted = try RetentionDisk.deletedIDs(from: root)
        let currentClips = clips.filter { !deleted.contains($0.id) }
        reconcile(&next, clips: currentClips)
        for i in cleared.indices {
            if let candidates = cleared[i].highlightCandidates {
                ingest(candidates, sources: cleared[i].sources, clips: currentClips, state: &next)
                cleared[i].highlightCandidates = nil
            }
        }
        try save(next, root)
        if cleared != reviews { try Journal.saveReviews(cleared, to: root) }
        return (next, cleared)
    }
    static func deleteSlices(for id: String, root: URL) throws {
        var state = try load(root)
        let removed = state.slices.filter { $0.clipID == id }
        for slice in removed {
            let url = root.appendingPathComponent(slice.file)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        state.slices.removeAll { $0.clipID == id }
        for h in state.highlights where h.source.clipID == id { state.dismissed.insert(h.id) }
        state.highlights.removeAll { $0.source.clipID == id }
        try save(state, root)
    }
}
