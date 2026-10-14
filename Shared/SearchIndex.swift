import Foundation

struct IndexedExcerpt: Codable, Equatable {
    var source: SourceExcerpt
    var terms: Set<String>
    var vector: [Double]?
}
struct SearchIndex: Codable {
    var schema = 3
    var model: String
    var entries: [String: IndexedExcerpt] = [:]
    var postings: [String: Set<String>] = [:]
    static func terms(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        var result = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let chars = Array(lower.filter { !$0.isWhitespace && !$0.isPunctuation })
        if chars.count > 1 { for i in 0..<(chars.count - 1) { result.insert(String(chars[i...i+1])) } }
        // Chinese compound words share meaningful individual Han characters.
        // Keep these as a weaker signal; common grammatical characters are excluded.
        let stop = Set("的一是在了和与及或有无不没把被将对于以为要也都就很更最这那哪何怎么什谁我你他她它们个些得地着过吗呢吧啊到从上下前后中时天会可需来去再先后做让能用")
        for char in chars where !stop.contains(char) && char.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { result.insert("han:" + String(char)) }
        return result
    }
    mutating func reconcile(sources: [SourceExcerpt], vector: (String) -> [Double]?) {
        let current = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        for id in Array(entries.keys) where current[id] != entries[id]?.source {
            if let old = entries.removeValue(forKey: id) { for term in old.terms { postings[term]?.remove(id); if postings[term]?.isEmpty == true { postings.removeValue(forKey: term) } } }
        }
        for source in sources where entries[source.id] == nil {
            let terms = Self.terms(source.text)
            entries[source.id] = IndexedExcerpt(source: source, terms: terms, vector: vector(source.text).flatMap(Self.normalized))
            for term in terms { postings[term, default: []].insert(source.id) }
        }
    }
    func search(_ query: String, vector: [Double]? = nil, since: Date = .distantPast, until: Date = .distantFuture, limit: Int = 8) -> [SourceExcerpt] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let terms = Self.terms(query)
        var scores: [String: Double] = [:]
        for term in terms {
            let ids = postings[term] ?? []
            let weight = log(1 + Double(entries.count) / Double(max(1, ids.count))) * (term.hasPrefix("han:") ? 0.35 : 1)
            for id in ids { scores[id, default: 0] += weight }
        }
        if let vector = vector.flatMap(Self.normalized) {
            for (id, entry) in entries {
                guard let other = entry.vector, other.count == vector.count else { continue }
                var similarity = 0.0
                for dimension in vector.indices { similarity += vector[dimension] * other[dimension] }
                if similarity >= 0.4 { scores[id, default: 0] += similarity * 8 }
            }
        }
        return scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.compactMap { entries[$0.key]?.source }
            .filter { let date = $0.started.addingTimeInterval($0.offset); return date >= since && date < until }.prefix(limit).map { $0 }
    }
    static func normalized(_ vector: [Double]) -> [Double]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else { return nil }
        return vector.map { $0 / norm }
    }
    static func cosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard !a.isEmpty, a.count == b.count, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(zip(a,a).reduce(0) { $0 + $1.0 * $1.1 } * zip(b,b).reduce(0) { $0 + $1.0 * $1.1 })
        guard norm > 0 else { return nil }
        return zip(a,b).reduce(0) { $0 + $1.0 * $1.1 } / norm
    }
    static func load(_ root: URL, model: String) throws -> SearchIndex {
        let path = root.appendingPathComponent("search-index.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return SearchIndex(model: model) }
        let value = try JSONDecoder().decode(SearchIndex.self, from: Data(contentsOf: path))
        guard value.schema == 3 else { return SearchIndex(model: model) }
        return value.model == model ? value : SearchIndex(model: model)
    }
    func save(_ root: URL) throws {
        try JSONEncoder().encode(self).write(to: root.appendingPathComponent("search-index.json"), options: .atomic)
    }
}
