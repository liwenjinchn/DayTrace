import Foundation
import AVFoundation

extension PhoneStore {
    func persistVault(_ next: AudioVaultState) throws {
        guard archiveHealthy, vaultHealthy else { throw ArchiveFailure.invalidClip }
        try AudioVault.save(next, root); audioVault = next
    }
    func replayHighlights() throws {
        guard archiveHealthy, vaultHealthy else { throw ArchiveFailure.invalidClip }
        let result = try AudioVault.replay(reviews: reviews, clips: clips, root: root)
        audioVault = result.0; reviews = result.1
    }

    func setFavorite(_ id: String, before: Double? = nil, after: Double? = nil) {
        do {
            var next = audioVault
            guard let i = next.highlights.firstIndex(where: { $0.id == id }) else { return }
            if let before, let after { next.highlights[i].before = before; next.highlights[i].after = after }
            else { next.highlights[i].favorite.toggle() }
            try persistVault(next)
            // Claims survive extraction failures; never promise permanent media prematurely.
            if next.highlights[i].favorite { Task { await prepareRetainedAudio() } }
            else { try pruneRetainedAudio(); Task { await prepareRetainedAudio() } }
        } catch { self.error = "收藏状态或片段处理失败，原文件继续保留：\(error.localizedDescription)" }
    }
    func dismissHighlight(_ id: String) {
        do {
            var next = audioVault; next.dismissed.insert(id); next.highlights.removeAll { $0.id == id }
            try persistVault(next); try pruneRetainedAudio(); Task { await prepareRetainedAudio() }
        } catch { self.error = error.localizedDescription }
    }
    func toggleMarkRetention(clipID: String, index: Int) {
        do {
            guard let clip = clips.first(where: { $0.id == clipID }), clip.marks.indices.contains(index) else { return }
            let key = "\(clipID):mark:\(index)"
            var next = audioVault; var disabled = next.disabledMarks ?? []
            if disabled.contains(key) { disabled.remove(key) } else { disabled.insert(key) }
            next.disabledMarks = disabled
            try persistVault(next); try pruneRetainedAudio(); Task { await prepareRetainedAudio() }
        } catch { self.error = error.localizedDescription }
    }
    func setMarkWindow(before: Double, after: Double) {
        do {
            var next = audioVault; next.markBefore = before; next.markAfter = after
            try persistVault(next); Task { await prepareRetainedAudio() }
        } catch { self.error = error.localizedDescription }
    }
    func prepareRetainedAudio() async {
        guard archiveHealthy, vaultHealthy, !recording, !processing, !preparingAudio else { return }
        preparingAudio = true; defer { preparingAudio = false }
        var failures = 0
        for clip in clips {
            for range in AudioVault.ranges(clip, archive: clips, state: audioVault) {
                let existing = audioVault.slices.filter { $0.clipID == clip.id && $0.sourceDigest == clip.digest && AudioVault.verified($0, root: root) }
                if existing.contains(where: { $0.start == range.lowerBound && $0.end == range.upperBound }) { continue }
                do {
                    let directory = root
                    let slice = try await Task.detached(priority: .utility) { try AudioSlicer.extract(clip, range: range, root: directory) }.value
                    guard clips.contains(where: { $0.id == clip.id && $0.digest == clip.digest }),
                          !(try RetentionDisk.deletedIDs(from: root)).contains(clip.id),
                          AudioVault.ranges(clip, archive: clips, state: audioVault).contains(range) else {
                        try? FileManager.default.removeItem(at: root.appendingPathComponent(slice.file)); failures += 1; continue
                    }
                    var next = audioVault; next.slices.append(slice)
                    do { try persistVault(next) }
                    catch { try? FileManager.default.removeItem(at: root.appendingPathComponent(slice.file)); throw error }
                } catch { failures += 1 }
            }
        }
        do { try compactRetainedAudio() } catch { failures += 1 }
        preservationStatus = failures == 0 ? "当前可用的保留范围已提取并校验；未收齐会话继续保护原文件。" : "\(failures) 个范围未提取成功：原文件继续保护；已到期或缺失的音频无法恢复。"
    }
    func compactRetainedAudio() throws {
        guard archiveHealthy, vaultHealthy else { throw ArchiveFailure.invalidClip }
        audioVault = try AudioVault.compact(root: root, clips: clips, playingID: playingID)
    }
    func pruneRetainedAudio(now: Date = Date()) throws {
        guard archiveHealthy, vaultHealthy else { throw ArchiveFailure.invalidClip }
        audioVault = try AudioVault.prune(root: root, clips: clips, now: now, playingID: playingID)
    }
    func playSlice(_ slice: AudioSlice, offset: Double? = nil) {
        guard !recording, vaultHealthy, clips.contains(where: { $0.id == slice.clipID }), AudioVault.verified(slice, root: root) else { error = "保留音频不可用或正在录音。"; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: root.appendingPathComponent(slice.file))
            playbackOrigin = slice.start; playbackPosition = offset ?? slice.start; player?.enableRate = true; player?.rate = playbackRate
            player?.currentTime = max(0, (offset ?? slice.start) - slice.start)
            player?.play(); playingID = slice.clipID
        } catch { self.error = error.localizedDescription }
    }
}
