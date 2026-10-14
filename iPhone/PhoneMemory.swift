import Foundation

extension PhoneStore {
    func persistMemories(_ updated: MemoryState) throws {
        guard memoriesHealthy else { throw AutomaticReviewError.unavailable }
        do { try MemoryDisk.save(updated, to: root); memoryState = updated }
        catch { memoriesHealthy = false; throw error }
    }
    func reconcileMemories() throws {
        guard memoryStorageHealthy else { throw AutomaticReviewError.unavailable }
        let reconciled = MemoryRules.reconcile(memoryState, current: ArchiveRules.excerpts(clips),
                                               deleted: try RetentionDisk.deletedIDs(from: root))
        if reconciled != memoryState { try persistMemories(reconciled) }
        try redactMemoryHistory()
    }
    func replayMemoryBatches() throws {
        guard automaticStorageHealthy else { throw AutomaticReviewError.unavailable }
        try reconcileMemories()
        do {
            let result = try MemoryBatchDisk.replay(reviews: reviews, state: memoryState, current: ArchiveRules.excerpts(clips),
                deleted: RetentionDisk.deletedIDs(from: root), root: root, now: Date())
            memoryState = result.memories; reviews = result.reviews
            try redactMemoryHistory()
        } catch { memoriesHealthy = false; throw error }
    }
    func editMemory(_ id: UUID, content: String) {
        do {
            try reconcileMemories()
            try persistMemories(MemoryRules.edit(id, content: content, in: memoryState, now: Date()))
            try redactMemoryHistory()
        } catch { self.error = "记忆修改未完成：\(error.localizedDescription)" }
    }
    func setMemoryActive(_ id: UUID, active: Bool) {
        do {
            try reconcileMemories()
            try persistMemories(MemoryRules.setStatus(id, active: active, in: memoryState, now: Date()))
            try redactMemoryHistory()
        } catch { self.error = "记忆状态未保存：\(error.localizedDescription)" }
    }
    func deleteMemory(_ id: UUID) {
        do {
            try persistMemories(MemoryRules.delete(id, from: memoryState))
            try redactMemoryHistory()
        } catch { self.error = "记忆删除未完成：\(error.localizedDescription)" }
    }
    func memoryContexts(for sources: [SourceExcerpt]) -> [MemoryContext] {
        guard memoryStorageHealthy, let deleted = try? RetentionDisk.deletedIDs(from: root) else { return [] }
        let safe = MemoryRules.reconcile(memoryState, current: ArchiveRules.excerpts(clips), deleted: deleted)
        return MemoryRules.contexts(safe, sources: sources)
    }
    func memoryContextsAreCurrent(_ snapshots: [MemoryContext], sources: [SourceExcerpt]) -> Bool {
        let current = memoryContexts(for: sources)
        return snapshots.allSatisfy { current.contains($0) }
    }
    func redactMemoryHistory() throws {
        guard memoriesHealthy else { throw AutomaticReviewError.unavailable }
        var updated = conversations
        for i in updated.indices {
            let snapshots = updated[i].memories ?? []
            let current = MemoryRules.contexts(memoryState, sources: updated[i].sources)
            let invalid = snapshots.filter { !current.contains($0) }
            if !invalid.isEmpty {
                updated[i].invalidatedMemoryIDs = Array(Set((updated[i].invalidatedMemoryIDs ?? []) + invalid.map(\.id)))
                updated[i].memories = snapshots.filter { current.contains($0) }
            }
        }
        if updated != conversations {
            try saveMemoryHistory(updated)
        }
    }
}
