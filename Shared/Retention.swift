import Foundation

enum RetentionRules {
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    static func expires(_ clip: Clip) -> Date { clip.started.addingTimeInterval(clip.duration + lifetime) }
    static let markBefore: TimeInterval = 30
    static let markAfter: TimeInterval = 60

    // Unknown legacy sessions are intentionally overprotected rather than guessed.
    // Ranges are clip-relative, clamped and merged for later safe extraction.
    static func markRanges(_ clip: Clip, archive: [Clip]) -> [Range<Double>] {
        var ranges: [Range<Double>] = []
        for source in archive {
            if let a = clip.sessionID, let b = source.sessionID, a != b { continue }
            for mark in source.marks {
                let center = source.started.timeIntervalSince(clip.started) + mark
                let lower = max(0, center - markBefore)
                let upper = min(clip.duration, center + markAfter)
                if lower < upper { ranges.append(lower..<upper) }
            }
        }
        var merged: [Range<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        return merged
    }
    static func protected(_ clip: Clip, archive: [Clip] = []) -> Bool {
        !clip.marks.isEmpty || clip.audioPinned == true || !markRanges(clip, archive: archive).isEmpty
    }
    static func eligible(_ clip: Clip, now: Date, playingID: String? = nil, archive: [Clip] = []) -> Bool {
        clip.audioExpiredAt == nil && !protected(clip, archive: archive) && clip.status == "ready"
            && playingID != clip.id && expires(clip) <= now
    }
}

enum RetentionDisk {
    static func deletedIDs(from root: URL) throws -> Set<String> {
        let url = root.appendingPathComponent("deleted-recordings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: url))
    }
    static func delete(_ clip: Clip, from root: URL, archive: [Clip]) throws -> [Clip] {
        try ArchiveRules.validate(clip)
        var deleted = try deletedIDs(from: root)
        deleted.insert(clip.id)
        // Persist the tombstone first. A crash cannot revive this record on reload.
        let url = root.appendingPathComponent("deleted-recordings.json")
        try JSONEncoder().encode(deleted).write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        let updated = archive.filter { !deleted.contains($0.id) }
        try ArchiveDisk.save(updated, to: root)
        let audio = root.appendingPathComponent(clip.file)
        if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
        try AudioVault.deleteSlices(for: clip.id, root: root)
        return updated
    }
    static func expire(_ clip: Clip, from root: URL, archive: [Clip], now: Date, playingID: String? = nil) throws -> [Clip] {
        // Evaluate the authoritative current record, not a stale UI candidate.
        guard let clip = archive.first(where: { $0.id == clip.id }) else { return archive }
        try ArchiveRules.validate(clip)
        let vault = try AudioVault.load(root)
        guard AudioVault.canExpire(clip, archive: archive, state: vault, root: root, now: now, playingID: playingID) else { return archive }
        var expired = clip; expired.audioExpiredAt = clip.audioExpiredAt ?? now
        let updated = archive.map { $0.id == clip.id ? expired : $0 }
        // Publish expiry before removing bytes; interruption leaves excess audio, never lost text.
        try ArchiveDisk.save(updated, to: root)
        let audio = root.appendingPathComponent(clip.file)
        if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
        return updated
    }
}
