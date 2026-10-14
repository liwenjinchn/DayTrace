import Foundation
import CryptoKit
import CommonCrypto

struct BackupFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
enum EncryptedBackup {
    struct Header: Codable { var version = 1; var salt: Data; var count: Int }
    struct Record: Codable { var name: String; var data: Data }
    struct Transaction: Codable { var previous: String; var stage: String }
    static let metadata: Set<String> = ["archive.json", "deleted-recordings.json", "conversations.json", "daily-reviews.json", "memories.json", "automatic-reviews.json", "audio-vault.json", "transcription-jobs.json", "context.json", "session-events.json", "outbound-requests.json"]
    static func allowed(_ name: String) -> Bool {
        if metadata.contains(name) { return true }
        if name.hasSuffix(".m4a"), UUID(uuidString: String(name.dropLast(4))) != nil { return true }
        if name.hasPrefix("retained-"), name.hasSuffix(".caf"), UUID(uuidString: String(name.dropFirst(9).dropLast(4))) != nil { return true }
        return false
    }
    static func key(_ password: String, salt: Data) throws -> SymmetricKey {
        guard password.count >= 12, salt.count == 16 else { throw BackupFailure(message: "备份密码至少 12 个字符；无法恢复遗失的密码。") }
        var derived = [UInt8](repeating: 0, count: 32)
        let bytes = Array(password.utf8)
        let status = bytes.withUnsafeBytes { p in salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress!.assumingMemoryBound(to: Int8.self), bytes.count,
                s.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, &derived, derived.count)
        } }
        guard status == kCCSuccess else { throw BackupFailure(message: "备份密钥生成失败") }
        return SymmetricKey(data: derived)
    }
    static func writeFrame(_ data: Data, _ handle: FileHandle) throws {
        guard !data.isEmpty, data.count <= 256 * 1024 * 1024 else { throw BackupFailure(message: "单个备份文件超出安全大小，请缩短录音分段") }
        var count = UInt64(data.count).bigEndian
        try withUnsafeBytes(of: &count) { try handle.write(contentsOf: Data($0)) }
        try handle.write(contentsOf: data)
    }
    static func readExactly(_ count: Int, _ handle: FileHandle) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let chunk = try handle.read(upToCount: min(count - result.count, 1024 * 1024)), !chunk.isEmpty else { throw BackupFailure(message: "备份不完整") }
            result.append(chunk)
        }
        return result
    }
    static func readFrame(_ handle: FileHandle) throws -> Data {
        let size = try readExactly(8, handle)
        let count = size.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard count > 0, count <= 256 * 1024 * 1024 else { throw BackupFailure(message: "备份帧损坏或超出安全大小") }
        return try readExactly(Int(count), handle)
    }
    static func validate(_ root: URL) throws {
        let clips = try ArchiveDisk.load(from: root)
        for clip in clips where clip.audioExpiredAt == nil {
            guard AudioVault.hash(try Data(contentsOf: root.appendingPathComponent(clip.file))) == clip.digest else { throw BackupFailure(message: "音频摘要校验失败") }
        }
        _ = try Journal.load(from: root); _ = try Journal.loadReviews(from: root)
        _ = try OutboundLog.load(root); _ = try SessionEvents.load(root); _ = try ProcessingQueue.load(from: root); _ = try ContextRules.load(root); _ = try MemoryDisk.load(from: root); _ = try AutomaticReviewDisk.load(from: root)
        let vault = try AudioVault.load(root)
        guard vault.slices.allSatisfy({ slice in AudioVault.verified(slice, root: root) && clips.contains(where: { $0.id == slice.clipID }) }) else { throw BackupFailure(message: "保留音频校验失败") }
    }
    static func export(root: URL, destination: URL, password: String) throws {
        try validate(root)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).filter { allowed($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var generator = SystemRandomNumberGenerator()
        let header = Header(salt: Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }), count: files.count)
        let secret = try key(password, salt: header.salt)
        let temporary = destination.appendingPathExtension("partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw BackupFailure(message: "无法创建备份文件") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary); defer { try? output.close() }
        try writeFrame(JSONEncoder().encode(header), output)
        var names: [String] = []
        for (index, file) in files.enumerated() {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw BackupFailure(message: "备份不接受符号链接") }
            let record = Record(name: file.lastPathComponent, data: try Data(contentsOf: file))
            let sealed = try AES.GCM.seal(JSONEncoder().encode(record), using: secret, authenticating: Data("DayTrace-1|\(index)".utf8))
            try writeFrame(sealed.combined!, output); names.append(record.name)
        }
        let footer = try AES.GCM.seal(JSONEncoder().encode(names), using: secret, authenticating: Data("DayTrace-1|end".utf8))
        try writeFrame(footer.combined!, output); try output.synchronize(); try output.close()
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw BackupFailure(message: "导出文件已存在，请选择新文件名") }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    @discardableResult static func restore(file: URL, root: URL, password: String) throws -> Bool {
        let manager = FileManager.default, parent = root.deletingLastPathComponent()
        try StorageGuard.requireSpace(parent, bytes: UInt64((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) * 2)
        let stage = parent.appendingPathComponent("daytrace-stage-\(UUID())")
        try manager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: stage) }
        var stageURL = stage; var values = URLResourceValues(); values.isExcludedFromBackup = true; try stageURL.setResourceValues(values)
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        let header = try JSONDecoder().decode(Header.self, from: readFrame(input))
        guard header.version == 1, header.count > 0, header.count <= 200_000 else { throw BackupFailure(message: "不支持的备份版本或数量") }
        let secret = try key(password, salt: header.salt)
        var names: [String] = []
        for index in 0..<header.count {
            let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: readFrame(input)), using: secret, authenticating: Data("DayTrace-1|\(index)".utf8))
            let record = try JSONDecoder().decode(Record.self, from: plaintext)
            guard allowed(record.name), !names.contains(record.name) else { throw BackupFailure(message: "非法路径或重复文件") }
            let target = stage.appendingPathComponent(record.name)
            try record.data.write(to: target, options: .atomic)
            #if os(iOS) || os(watchOS)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            #endif
            names.append(record.name)
        }
        let footer = try AES.GCM.open(AES.GCM.SealedBox(combined: readFrame(input)), using: secret, authenticating: Data("DayTrace-1|end".utf8))
        guard try JSONDecoder().decode([String].self, from: footer) == names, names.contains("archive.json"), (try input.read(upToCount: 1))?.isEmpty != false else { throw BackupFailure(message: "备份结尾验证失败") }
        try validate(stage)
        let oldDeleted = try RetentionDisk.deletedIDs(from: root)
        guard try ArchiveDisk.load(from: stage).allSatisfy({ !oldDeleted.contains($0.id) }) else { throw BackupFailure(message: "备份包含本机已主动删除的记录；为避免复活数据，未替换当前库。") }
        try JSONEncoder().encode(oldDeleted.union(try RetentionDisk.deletedIDs(from: stage))).write(to: stage.appendingPathComponent("deleted-recordings.json"), options: .atomic)
        var context = try ContextRules.load(stage); context.consent = nil; try ContextRules.save(context, root: stage)
        // Restoring content must not restore permission to send data automatically.
        var automatic = try AutomaticReviewDisk.load(from: stage); automatic.policy?.enabled = false
        try AutomaticReviewDisk.save(automatic, to: stage)
        let rollback = parent.appendingPathComponent("daytrace-rollback-\(UUID())")
        let marker = parent.appendingPathComponent(root.lastPathComponent + "-restore.json")
        try JSONEncoder().encode(Transaction(previous: rollback.lastPathComponent, stage: stage.lastPathComponent)).write(to: marker, options: .atomic)
        do {
            try manager.moveItem(at: root, to: rollback)
            try manager.moveItem(at: stage, to: root)
            try manager.removeItem(at: marker)
        } catch { try recover(root); throw error }
        do { try manager.removeItem(at: rollback); return true }
        catch { return false }
    }
    static func recover(_ root: URL) throws {
        let manager = FileManager.default, parent = root.deletingLastPathComponent()
        let marker = parent.appendingPathComponent(root.lastPathComponent + "-restore.json")
        guard manager.fileExists(atPath: marker.path) else { return }
        let tx = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: marker))
        guard tx.previous.hasPrefix("daytrace-rollback-"), !tx.previous.contains("/"), tx.stage.hasPrefix("daytrace-stage-"), !tx.stage.contains("/") else { throw BackupFailure(message: "恢复事务损坏") }
        let previous = parent.appendingPathComponent(tx.previous)
        if manager.fileExists(atPath: previous.path) {
            if manager.fileExists(atPath: root.path) { try manager.removeItem(at: root) }
            try manager.moveItem(at: previous, to: root)
        }
        let stage = parent.appendingPathComponent(tx.stage)
        if manager.fileExists(atPath: stage.path) { try manager.removeItem(at: stage) }
        try manager.removeItem(at: marker)
    }
}
