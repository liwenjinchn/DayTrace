import Foundation
import NaturalLanguage

extension PhoneStore {
    func refreshSearchIndex(locale: String) throws {
        guard archiveHealthy else { throw ArchiveFailure.invalidClip }
        let language: NLLanguage = locale.hasPrefix("zh") ? .simplifiedChinese : .english
        let embedding = NLEmbedding.sentenceEmbedding(for: language)
        let model = "\(locale)|\(Calendar.current.timeZone.identifier)|\(ProcessInfo.processInfo.operatingSystemVersionString)|\(embedding?.dimension ?? 0)"
        if searchIndex?.model == model && !searchDirty { return }
        if searchIndex?.model != model {
            do { searchIndex = try SearchIndex.load(root, model: model) }
            catch {
                // A derived index is rebuildable; preserve the broken file for diagnosis.
                let path = root.appendingPathComponent("search-index.json")
                if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.moveItem(at: path, to: root.appendingPathComponent("search-index-corrupt-\(UUID()).json")) }
                searchIndex = SearchIndex(model: model)
            }
        }
        guard archiveHealthy else { throw ArchiveFailure.invalidClip }
        let deleted = try RetentionDisk.deletedIDs(from: root)
        let sources = ArchiveRules.excerpts(clips.filter { !deleted.contains($0.id) })
        let changed = searchIndex?.entries.count != sources.count || sources.contains { searchIndex?.entries[$0.id]?.source != $0 }
        if changed {
            searchIndex?.reconcile(sources: sources, vector: { embedding?.vector(for: $0) })
            try searchIndex?.save(root)
        }
        searchDirty = false
        searchStatus = embedding == nil ? "语义模型不可用，已保留本地关键词检索" : "本地索引已就绪 · \(sources.count) 条原文"
    }
    func retrieve(_ query: String, locale: String, since: Date = .distantPast, until: Date = .distantFuture) -> [SourceExcerpt] {
        var found = search(query, semantic: true, locale: locale, since: since, until: until)
        let terms = SearchIndex.terms(query)
        let current = ArchiveRules.excerpts(clips)
        let ranked = memoryState.items.filter { $0.status == .active }.map { ($0, SearchIndex.terms($0.content).intersection(terms).count) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        for (memory, _) in ranked.prefix(3) {
            for source in memory.sources where current.contains(source) && source.started.addingTimeInterval(source.offset) >= since && source.started.addingTimeInterval(source.offset) < until && !found.contains(source) {
                if found.count >= 8 { found.removeLast() }; found.insert(source, at: 0)
            }
        }
        return found
    }
}
