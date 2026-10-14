import SwiftUI
import AVFoundation
import WatchConnectivity
import CryptoKit

@MainActor final class WatchRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate, WCSessionDelegate {
    @Published var recording = false
    @Published var paused = false
    private var capturedDuration: Double = 0
    @Published var pending: [Clip] = []
    @Published var error: String?
    @Published var elapsed: Double = 0
    @Published var transferStatus = "连接尚未就绪；已落盘音频保留在手表"
    private let root: URL
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var lastChunkEnd: Date?
    private var started = Date()
    private var id = ""
    private var sessionID = UUID().uuidString
    private var sessionCount = 0
    private var marks: [Double] = []
    private var interruptions: NSObjectProtocol?
    private var archiveHealthy = true

    override init() {
        do { root = try ArchiveDisk.directory() } catch { fatalError("Cannot create recording directory: \(error)") }
        super.init()
        do { pending = try ArchiveDisk.load(from: root) } catch { archiveHealthy = false; self.error = "Cannot read transfer queue; recording is blocked: \(error.localizedDescription)" }
        if archiveHealthy { recoverInterruptedFiles() }
        WCSession.default.delegate = self; WCSession.default.activate()
        interruptions = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.logEvent(.interruption, "系统中断"); self?.stop(); self?.error = "录音被系统中断，请重新开始。" }
        }
    }
    func start() async {
        guard !recording else { return }
        guard archiveHealthy else { return }
        let allowed = await withCheckedContinuation { c in AVAudioApplication.requestRecordPermission { c.resume(returning: $0) } }
        guard allowed else { error = "请在设置中允许麦克风访问。"; return }
        do {
            error = nil
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            if !paused { sessionID = UUID().uuidString; sessionCount = 0; capturedDuration = 0; logEvent(.start, "手动开始") }
            else { logEvent(.resume, "继续录音") }
            try beginChunk()
            recording = true; paused = false; sync()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        } catch { self.error = error.localizedDescription }
    }
    private func beginChunk() throws {
        try StorageGuard.requireSpace(root)
        id = UUID().uuidString; started = Date(); marks = []; elapsed = capturedDuration
        let provisional = Clip(id: id, started: started, duration: 30, marks: [], file: id + ".m4a", digest: String(repeating: "0", count: 64), sessionID: sessionID, sessionIndex: sessionCount)
        try JSONEncoder().encode(provisional).write(to: root.appendingPathComponent(id + ".pending.json"), options: .atomic)
        recorder = try AVAudioRecorder(url: root.appendingPathComponent(id + ".m4a"), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
        recorder?.delegate = self
        guard recorder?.record(forDuration: 30) == true else { throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法开始麦克风录音。"]) }
    }
    func mark() {
        guard recording else { return }
        let offset = recorder?.currentTime ?? 0; marks.append(offset)
        do {
            let provisional = Clip(id: id, started: started, duration: 30, marks: marks, file: id + ".m4a", digest: String(repeating: "0", count: 64), sessionID: sessionID, sessionIndex: sessionCount)
            try JSONEncoder().encode(provisional).write(to: root.appendingPathComponent(id + ".pending.json"), options: .atomic)
            logEvent(.mark, "手动标记；等待对应音频收妥后可回听")
            sync()
            WKInterfaceDevice.current().play(.click)
        } catch { self.error = error.localizedDescription }
    }
    private func tick() {
        elapsed = capturedDuration + (recorder?.currentTime ?? 0)
    }
    private func finishChunk() throws {
        guard let recorder else { return }
        recorder.stop(); self.recorder = nil
        let duration = try AVAudioPlayer(contentsOf: root.appendingPathComponent(id + ".m4a")).duration
        guard duration >= 0.1 else { throw ArchiveFailure.invalidClip }
        let file = id + ".m4a"
        let bytes = try Data(contentsOf: root.appendingPathComponent(file))
        let clip = Clip(id: id, started: started, duration: duration, marks: marks.filter { $0 <= duration }, file: file, digest: SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined(), sessionID: sessionID, sessionIndex: sessionCount)
        let updated = try ArchiveRules.inserting(clip, into: pending)
        try ArchiveDisk.save(updated, to: root); pending = updated
        try FileManager.default.removeItem(at: root.appendingPathComponent(id + ".pending.json"))
        lastChunkEnd = started.addingTimeInterval(duration)
        capturedDuration += duration; elapsed = capturedDuration
        sessionCount += 1
        sync()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        do {
            try finishChunk()
            // A successful explicit stop seals the numbered session. Interrupted/crashed
            // sessions without a seal remain protected on the phone.
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(id + ".pending.json").path) else { throw ArchiveFailure.invalidClip }
            if sessionCount > 0 {
                var state = try AudioVault.load(root)
                try AudioVault.seal(SessionSeal(id: sessionID, count: sessionCount), state: &state)
                try AudioVault.save(state, root)
                sync()
            }
        } catch { self.error = error.localizedDescription }
        recording = false; paused = false; logEvent(.end, "会话结束"); sync()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    private func logEvent(_ kind: SessionEvent.Kind, _ detail: String) {
        do { _ = try SessionEvents.insert(SessionEvent(sessionID: sessionID, kind: kind, detail: detail), root: root) }
        catch { self.error = "录音事件保存失败：\(error.localizedDescription)" }
    }
    func pause() {
        guard recording else { return }
        timer?.invalidate(); timer = nil
        do { try finishChunk(); recording = false; paused = true; logEvent(.pause, "手动暂停"); sync() }
        catch { stop(); self.error = error.localizedDescription }
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    private func recoverInterruptedFiles() {
        do {
            for manifest in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter({ $0.lastPathComponent.hasSuffix(".pending.json") }) {
                var clip = try JSONDecoder().decode(Clip.self, from: Data(contentsOf: manifest))
                if pending.contains(where: { $0.id == clip.id }) { try FileManager.default.removeItem(at: manifest); continue }
                let url = root.appendingPathComponent(clip.file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let bytes = try Data(contentsOf: url)
                let audio = try AVAudioPlayer(data: bytes)
                guard audio.duration > 0 && audio.duration <= 90 else { continue }
                clip.duration = audio.duration; clip.marks = clip.marks.filter { $0 <= audio.duration }
                clip.digest = SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined()
                let updated = try ArchiveRules.inserting(clip, into: pending)
                try ArchiveDisk.save(updated, to: root); pending = updated
                try FileManager.default.removeItem(at: manifest)
            }
        } catch { self.error = "Interrupted audio needs recovery: \(error.localizedDescription)" }
    }
    func sync() {
        let session = WCSession.default
        guard archiveHealthy else { return }
        guard session.activationState == .activated else { return }
        transferStatus = (session.isReachable ? "手机当前可达" : "等待后台传输") + " · 已排队 \(session.outstandingFileTransfers.count) 段；本地音频等待手机收妥确认"
        do {
            let receipts = try metadataReceipts()
            let events = try SessionEvents.load(root)
            let queuedEvents = Set(session.outstandingUserInfoTransfers.compactMap { $0.userInfo["eventID"] as? String })
            for event in events where !queuedEvents.contains(event.id) && !receipts.contains("event:" + event.id) { session.transferUserInfo(["eventID": event.id, "sessionEvent": try JSONEncoder().encode(event)]) }
            let seals = try AudioVault.load(root).seals
            let queuedSeals = Set(session.outstandingUserInfoTransfers.compactMap { $0.userInfo["sealID"] as? String })
            for seal in seals where !queuedSeals.contains(seal.id) && !receipts.contains("seal:" + seal.id) {
                session.transferUserInfo(["sealID": seal.id, "sessionSeal": try JSONEncoder().encode(seal)])
            }
        } catch { self.error = error.localizedDescription }
        let queued = Set(session.outstandingFileTransfers.compactMap { $0.file.metadata?["id"] as? String })
        for clip in pending where !queued.contains(clip.id) {
            do { session.transferFile(root.appendingPathComponent(clip.file), metadata: ["id": clip.id, "clip": try JSONEncoder().encode(clip)]) }
            catch { self.error = error.localizedDescription }
        }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in if let error { self.error = error.localizedDescription }; sync() }
    }
    private func metadataReceipts() throws -> Set<String> {
        let file = root.appendingPathComponent("metadata-receipts.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file))
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let receipt = userInfo["metadataReceipt"] as? String {
            Task { @MainActor in
                do {
                    var receipts = try metadataReceipts(); receipts.insert(receipt)
                    try JSONEncoder().encode(receipts).write(to: root.appendingPathComponent("metadata-receipts.json"), options: .atomic)
                } catch { self.error = "同步确认保存失败，稍后将重试。" }
            }
            return
        }
        guard let receipt = userInfo["receipt"] as? String else { return }
        Task { @MainActor in
            guard let clip = pending.first(where: { $0.id == receipt }) else { return }
            do {
                let updated = pending.filter { $0.id != receipt }
                try ArchiveDisk.save(updated, to: root); pending = updated
                try FileManager.default.removeItem(at: root.appendingPathComponent(clip.file))
            } catch { self.error = error.localizedDescription }
        }
    }
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if let error { Task { @MainActor in self.error = "Transfer pending: \(error.localizedDescription)" } }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in stop(); self.error = error?.localizedDescription ?? "音频编码失败。" }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === recorder, recording else { return }
            guard flag else { stop(); error = "录音意外结束，请点击开始恢复。"; return }
            do { try finishChunk(); let end = lastChunkEnd ?? Date(); try beginChunk(); let gap = started.timeIntervalSince(end); if gap > 0.2 { logEvent(.gap, String(format: "分段间隔 %.2f 秒，待核查", gap)) } } catch { stop(); self.error = error.localizedDescription }
        }
    }
}

@main struct DayTraceWatchApp: App {
    @StateObject private var recorder = WatchRecorder()
    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(spacing: 12) {
                    Text("DayTrace").font(.headline)
                    Image(systemName: recorder.recording ? "waveform" : "mic").font(.system(size: 36)).foregroundStyle(recorder.recording ? .red : .green)
                    Text(recorder.recording ? String(format: "%02d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60) : recorder.paused ? "已暂停" : "准备录音").monospacedDigit()
                    Button { if recorder.recording { recorder.stop() } else { Task { await recorder.start() } } } label: {
                        Label(recorder.recording ? "结束" : recorder.paused ? "继续" : "开始", systemImage: recorder.recording ? "stop.fill" : "record.circle")
                    }.tint(recorder.recording ? .red : .green)
                    if recorder.recording { Button { recorder.mark() } label: { Label("标记", systemImage: "bookmark") }; Button("暂停") { recorder.pause() } }
                    if recorder.paused { Button("结束会话") { recorder.stop() } }
                    Button { recorder.sync() } label: { Label("待同步 \(recorder.pending.count) 段", systemImage: "arrow.triangle.2.circlepath") }
                    Text(recorder.transferStatus).font(.caption)
                    if let error = recorder.error { Text(error).font(.caption).foregroundStyle(.red) }
                }.padding()
            }
        }
    }
}
