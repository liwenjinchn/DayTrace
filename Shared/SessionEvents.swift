import Foundation
struct SessionEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case start, pause, resume, interruption, end, gap, mark }
    var id = UUID().uuidString
    var sessionID: String
    var time = Date()
    var kind: Kind
    var detail: String
}
enum SessionEvents {
    static func load(_ root: URL) throws -> [SessionEvent] {
        let path = root.appendingPathComponent("session-events.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let events = try JSONDecoder().decode([SessionEvent].self, from: Data(contentsOf: path))
        guard events.allSatisfy({ UUID(uuidString: $0.id) != nil && UUID(uuidString: $0.sessionID) != nil }), Set(events.map(\.id)).count == events.count else { throw ArchiveFailure.invalidClip }
        return events
    }
    static func insert(_ event: SessionEvent, root: URL) throws -> [SessionEvent] {
        guard UUID(uuidString: event.id) != nil, UUID(uuidString: event.sessionID) != nil, event.time.timeIntervalSince1970.isFinite, event.detail.count <= 500 else { throw ArchiveFailure.invalidClip }
        var events = try load(root)
        if let old = events.first(where: { $0.id == event.id }) { guard old == event else { throw ArchiveFailure.duplicateConflict }; return events }
        events.append(event)
        try JSONEncoder().encode(events).write(to: root.appendingPathComponent("session-events.json"), options: .atomic)
        return events
    }
}
enum StorageGuard {
    static func requireSpace(_ root: URL, bytes: UInt64 = 0) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber else { throw BackupFailure(message: "无法读取可用空间，已停止新增。") }
        try requireSpace(available: free.uint64Value, bytes: bytes)
    }
    static func requireSpace(available: UInt64, bytes: UInt64) throws {
        let reserve: UInt64 = 64 * 1024 * 1024
        guard available > reserve, bytes < available - reserve else { throw BackupFailure(message: "可用空间不足，已停止新增，不会清理未保护数据。") }
    }
}
enum TimelineRules {
    static func seconds(_ clip: Clip, day: Date, hour: Int, calendar: Calendar = .current) -> Double {
        let startOfDay = calendar.startOfDay(for: day)
        guard let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: startOfDay), let end = calendar.date(byAdding: .hour, value: 1, to: start) else { return 0 }
        return max(0, min(end, clip.started.addingTimeInterval(clip.duration)).timeIntervalSince(max(start, clip.started)))
    }
    static func seconds(_ clip: Clip, day: Date, calendar: Calendar = .current) -> Double {
        let start = calendar.startOfDay(for: day), end = calendar.date(byAdding: .day, value: 1, to: start)!
        return max(0, min(end, clip.started.addingTimeInterval(clip.duration)).timeIntervalSince(max(start, clip.started)))
    }
    static func days(_ clip: Clip, calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: clip.started), end = calendar.startOfDay(for: clip.started.addingTimeInterval(max(0, clip.duration - 0.001)))
        return start == end ? [start] : [start, end]
    }
}
