import SwiftUI
import WatchConnectivity
import CryptoKit
import Speech
import NaturalLanguage
import AVFoundation

@MainActor final class PhoneStore: NSObject, ObservableObject, WCSessionDelegate {
    @Published var sessionEvents: [SessionEvent] = []
    @Published var contextState = ContextState()
    var contextHealthy = true
    var manualInFlight = 0
    var searchIndex: SearchIndex?
    var searchDirty = true
    @Published var searchStatus = "索引尚未构建"
    @Published var clips: [Clip] = [] { didSet { searchDirty = true } }
    @Published var error: String?
    @Published var processing = false
    @Published var connection = "正在连接"
    @Published var conversations: [SavedConversation] = []
    @Published var reviews: [SavedDailyReview] = []
    @Published var transcriptionJobs: [TranscriptionJob] = []
    @Published var automaticReviewState = AutomaticReviewState()
    @Published var automaticReviewStatus = "尚未授权自动外发"
    var automaticReviewRunner: AutomaticReviewRunner!
    @Published var memoryState = MemoryState()
    var memoriesHealthy = true
    var memoryStorageHealthy: Bool { archiveHealthy && memoriesHealthy }
    var automaticStorageHealthy: Bool { memoryStorageHealthy && reviewsHealthy && vaultHealthy && contextHealthy }
    @Published var audioVault = AudioVaultState()
    @Published var preparingAudio = false
    @Published var preservationStatus = ""
    var vaultHealthy = true
    private var queueHealthy = true
    private var reviewsHealthy = true
    @Published var playingID: String?
    @Published var playbackPosition = 0.0
    var playbackOrigin = 0.0
    @Published var playbackRate: Float = 1
    @Published var recording = false
    @Published var recordingMarks = 0
    private var recorder: PhoneMicrophoneCapture?
    private var recordingLimitTask: Task<Void, Never>?
    private var recordingStarted: Date?
    private var marks: [Double] = []
    private var historyHealthy = true
    let root: URL
    private var recognitionTask: SFSpeechRecognitionTask?
    var player: AVAudioPlayer?
    var archiveHealthy = true

    init(rootURL: URL? = nil, activateConnectivity: Bool = true) {
        do { root = try rootURL ?? ArchiveDisk.directory() } catch { fatalError("Cannot create local archive: \(error)") }
        super.init()
        do { clips = try ArchiveDisk.load(from: root) } catch { archiveHealthy = false; self.error = "Archive cannot be read; writes are blocked: \(error.localizedDescription)" }
        do { conversations = try Journal.load(from: root) }
        catch { historyHealthy = false; self.error = "Conversation history cannot be read; history writes are blocked." }
        do { reviews = try Journal.loadReviews(from: root) }
        catch { reviewsHealthy = false; self.error = "复盘文件损坏，已阻止写入并保留原文件。" }
        do { sessionEvents = try SessionEvents.load(root) } catch { self.error = "录音事件文件不可读。" }
        do { contextState = try ContextRules.load(root) } catch { contextHealthy = false; self.error = "上下文存储损坏，已停止外发。" }
        do { memoryState = try MemoryDisk.load(from: root) }
        catch { memoriesHealthy = false; self.error = "记忆文件不可读，已停止写入与记忆外发。" }
        do { try redactDeletedHistory() } catch { self.error = "删除的来源快照未完全清除，请检查本地存储。" }
        do { try OutboundLog.redact(root: root, deleted: RetentionDisk.deletedIDs(from: root)) } catch { self.error = "外发记录清理失败，原文件保留。" }
        do {
            transcriptionJobs = try ProcessingQueue.load(from: root)
            if archiveHealthy { try reconcileQueue(recovering: true) }
        } catch { queueHealthy = false; self.error = "转写任务文件不可读，已停止处理并保留原文件。" }
        do { try replayMemoryBatches() } catch { self.error = "记忆恢复未完成：\(error.localizedDescription)" }
        do {
            audioVault = try AudioVault.load(root)
            if archiveHealthy {
                for id in try RetentionDisk.deletedIDs(from: root) { try AudioVault.deleteSlices(for: id, root: root) }
                audioVault = try AudioVault.load(root)
                try AudioVault.removeOrphans(root)
                try replayHighlights()
            }
        } catch { vaultHealthy = false; self.error = "音频保留记录不可读，已停止清理与重点处理。" }
        automaticReviewRunner = AutomaticReviewRunner(root: root)
        automaticReviewState = automaticReviewRunner.state
        automaticReviewRunner.onChange = { [weak self] state in self?.automaticReviewState = state }
        do { try reconcileAutomaticReviews() }
        catch { self.error = error.localizedDescription }
        if !automaticReviewRunner.healthy { automaticReviewStatus = "任务文件不可读，自动外发已停止" }
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        if activateConnectivity && WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in refreshConnection(); if let error { connection = error.localizedDescription } }
    }
    func refreshConnection() {
        guard WCSession.isSupported() else { connection = "此设备不支持 Watch 连接"; return }
        let session = WCSession.default
        guard session.activationState == .activated else { connection = "Watch 连接尚未激活"; return }
        if !session.isPaired { connection = "此 iPhone 尚未配对 Apple Watch" }
        else if !session.isWatchAppInstalled { connection = "Watch 已配对；手表端尚未安装 DayTrace" }
        else { connection = session.isReachable ? "手表端已安装，可连接" : "手表端已安装，等待后台传输" }
        struct Diagnostic: Codable {
            let checkedAt: Date
            let paired: Bool
            let watchAppInstalled: Bool
            let reachable: Bool
        }
        let diagnostic = Diagnostic(checkedAt: Date(), paired: session.isPaired, watchAppInstalled: session.isWatchAppInstalled, reachable: session.isReachable)
        // Connectivity flags only; no audio, transcript, device identifier or credential.
        try? JSONEncoder().encode(diagnostic).write(to: root.appendingPathComponent("connectivity.json"), options: .atomic)
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in refreshConnection() }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in refreshConnection() }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let eventData = userInfo["sessionEvent"] as? Data {
            Task { @MainActor in
                do {
                    let event = try JSONDecoder().decode(SessionEvent.self, from: eventData)
                    sessionEvents = try SessionEvents.insert(event, root: root)
                    session.transferUserInfo(["metadataReceipt": "event:" + event.id])
                }
                catch { self.error = "录音事件保存失败。" }
            }
        }
        guard let data = userInfo["sessionSeal"] as? Data else { return }
        Task { @MainActor in
            do {
                guard vaultHealthy else { throw ArchiveFailure.invalidClip }
                let seal = try JSONDecoder().decode(SessionSeal.self, from: data)
                var next = audioVault; try AudioVault.seal(seal, state: &next)
                try persistVault(next)
                session.transferUserInfo(["metadataReceipt": "seal:" + seal.id])
            } catch { self.error = "录音会话清单保存失败，相关原音继续保留。" }
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // WCSession's temporary URL is valid only during this callback.
        do {
            guard let data = file.metadata?["clip"] as? Data else { throw ArchiveFailure.invalidClip }
            let clip = try JSONDecoder().decode(Clip.self, from: data)
            try ArchiveRules.validate(clip)
            let bytes = try Data(contentsOf: file.fileURL)
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == clip.digest else { throw ArchiveFailure.invalidClip }
            let incoming = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            try bytes.write(to: incoming, options: .atomic)
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: incoming) }
                do {
                    guard archiveHealthy else { throw ArchiveFailure.invalidClip }
                    guard !(try RetentionDisk.deletedIDs(from: root)).contains(clip.id) else { throw ArchiveFailure.deletedRecording }
                    let updated = try ArchiveRules.inserting(clip, into: clips)
                    if clips.contains(where: { $0.id == clip.id }) {
                        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(clip.file).path) else { throw ArchiveFailure.invalidClip }
                    } else {
                        try StorageGuard.requireSpace(root, bytes: UInt64(bytes.count))
                        try Data(contentsOf: incoming).write(to: root.appendingPathComponent(clip.file), options: .atomic)
                        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.appendingPathComponent(clip.file).path)
                    }
                    try ArchiveDisk.save(updated, to: root)
                    clips = updated
                    session.transferUserInfo(["receipt": clip.id])
                    await resumeAutomaticTranscription()
                } catch { self.error = error.localizedDescription }
            }
        } catch { Task { @MainActor in self.error = error.localizedDescription } }
    }
    func update(_ clip: Clip) throws {
        guard archiveHealthy else { throw ArchiveFailure.invalidClip }
        guard clips.contains(where: { $0.id == clip.id }), !(try RetentionDisk.deletedIDs(from: root)).contains(clip.id) else { throw ArchiveFailure.deletedRecording }
        let updated = clips.map { $0.id == clip.id ? clip : $0 }
        try ArchiveDisk.save(updated, to: root); clips = updated
    }
    func correctTranscript(clipID: String, expected: WordSpan, text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2000,
              var clip = clips.first(where: { $0.id == clipID }), clip.status == "ready",
              let index = clip.transcript.firstIndex(where: { $0.id == expected.id }),
              clip.transcript[index] == expected else { throw ArchiveFailure.invalidSources }
        guard text != expected.text else { return }
        clip.transcript[index].originalText = expected.originalText ?? expected.text
        clip.transcript[index].text = text
        clip.transcript[index].userEditedAt = Date()
        try update(clip) // Atomic archive write; time ranges and source IDs stay stable.
        try reconcileMemories() // Changed snapshots cannot remain active memory evidence.
        try reconcileAutomaticReviews()
        try refreshSearchIndex(locale: UserDefaults.standard.string(forKey: "locale") ?? "zh-CN")
    }
    private func persistQueue(_ jobs: [TranscriptionJob]) throws {
        guard queueHealthy else { throw ArchiveFailure.invalidClip }
        try ProcessingQueue.save(jobs, to: root); transcriptionJobs = jobs
    }
    private func reconcileQueue(recovering: Bool = false) throws {
        guard archiveHealthy, queueHealthy else { throw ArchiveFailure.invalidClip }
        try persistQueue(ProcessingQueue.reconcile(transcriptionJobs, clips: clips,
            deleted: try RetentionDisk.deletedIDs(from: root), recovering: recovering))
    }
    func resumeAutomaticTranscription() async {
        do { try reconcileQueue() } catch { self.error = "任务入队失败，音频仍保存在本地。"; return }
        if UserDefaults.standard.bool(forKey: "automaticTranscription"), SFSpeechRecognizer.authorizationStatus() == .authorized {
            await transcribePending(locale: UserDefaults.standard.string(forKey: "locale") ?? "zh-CN", retryFailures: false)
        }
        do { try refreshSearchIndex(locale: UserDefaults.standard.string(forKey: "locale") ?? "zh-CN") } catch { self.error = "索引更新失败，原文仍保留。" }
        await resumeAutomaticReviews()
        await prepareRetainedAudio()
        if UserDefaults.standard.bool(forKey: "automaticRetention") { cleanupAudio() }
    }
    func transcribePending(locale: String, retryFailures: Bool = true) async {
        guard !processing, !recording, archiveHealthy, queueHealthy else { return }
        processing = true; defer { processing = false; Task { await resumeAutomaticReviews(); await prepareRetainedAudio() } }
        do {
            try reconcileQueue()
            if retryFailures {
                var jobs = transcriptionJobs
                for i in jobs.indices where jobs[i].state == .failed { jobs[i].state = .pending; jobs[i].failure = nil }
                try persistQueue(jobs)
            }
            guard transcriptionJobs.contains(where: { $0.state == .pending }) else { return }
            let granted = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
            guard granted else { error = "需要语音识别权限，任务已保留。"; return }
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
            while true {
                try reconcileQueue()
                guard let index = transcriptionJobs.firstIndex(where: { $0.state == .pending }) else { break }
                if !retryFailures && !UserDefaults.standard.bool(forKey: "automaticTranscription") { break }
                let job = transcriptionJobs[index]
                guard let original = clips.first(where: { $0.id == job.clipID && $0.digest == job.digest }) else { continue }
                var jobs = transcriptionJobs
                jobs[index].state = .running; jobs[index].attempts += 1; jobs[index].locale = locale
                try persistQueue(jobs) // Record the attempt before invoking Speech.
                do {
                    let spans = try await recognizeLocally(root.appendingPathComponent(original.file), locale: locale, legacy: recognizer)
                    guard var current = clips.first(where: { $0.id == job.clipID && $0.digest == job.digest }) else {
                        try reconcileQueue(); continue
                    }
                    // Preserve edits made while recognition was running.
                    if current.status != "ready" {
                        current.transcript = spans; current.status = "ready"; current.failure = nil
                        try update(current)
                    }
                    try reconcileQueue()
                } catch {
                    try reconcileQueue()
                    if let i = transcriptionJobs.firstIndex(where: { $0.id == job.id }), transcriptionJobs[i].state == .running {
                        var failed = transcriptionJobs
                        failed[i].state = .failed; failed[i].failure = error.localizedDescription
                        try persistQueue(failed)
                        if var current = clips.first(where: { $0.id == job.clipID }), current.status != "ready" {
                            current.status = "failed"; current.failure = error.localizedDescription
                            try update(current)
                        }
                    }
                }
            }
        } catch { self.error = "转写队列未完成：\(error.localizedDescription)" }
    }
    private func recognizeLocally(_ url: URL, locale: String, legacy: SFSpeechRecognizer?) async throws -> [WordSpan] {
        if #available(iOS 26, *), SpeechTranscriber.isAvailable,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) {
            let module = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            // Only use installed assets. Never upload audio or download a model implicitly.
            if await AssetInventory.status(forModules: [module]) == .installed {
                return try await recognizeModern(url, module: module)
            }
        }
        guard let legacy, legacy.isAvailable, legacy.supportsOnDeviceRecognition else {
            throw NSError(domain: "Speech", code: 2, userInfo: [NSLocalizedDescriptionKey: "此语言的端侧识别不可用，音频未上传。"])
        }
        return try await recognize(url, with: legacy)
    }
    @available(iOS 26, *)
    private func recognizeModern(_ url: URL, module: SpeechTranscriber) async throws -> [WordSpan] {
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { () throws -> [WordSpan] in
            var spans: [WordSpan] = []
            for try await result in module.results {
                let text = String(result.text.characters)
                let tokenizer = NLTokenizer(unit: .word)
                tokenizer.string = text
                let timedRuns = result.text.runs.compactMap { run -> (Range<Int>, CMTimeRange)? in
                    guard let time = run.audioTimeRange else { return nil }
                    let lower = result.text.characters.distance(from: result.text.startIndex, to: run.range.lowerBound)
                    let upper = result.text.characters.distance(from: result.text.startIndex, to: run.range.upperBound)
                    return (lower..<upper, time)
                }
                var previousEnd = text.startIndex
                for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
                    let lower = text.distance(from: text.startIndex, to: range.lowerBound)
                    let upper = text.distance(from: text.startIndex, to: range.upperBound)
                    let times = timedRuns.filter { $0.0.overlaps(lower..<upper) }.map { $0.1 }
                    guard let start = times.map({ $0.start.seconds }).min(),
                          let end = times.map({ $0.end.seconds }).max(),
                          start.isFinite, end.isFinite, start >= 0, end >= start else {
                        throw NSError(domain: "Speech", code: 3, userInfo: [NSLocalizedDescriptionKey: "识别结果缺少有效时间，原音已保留。"])
                    }
                    spans.append(WordSpan(id: String(spans.count), offset: start, duration: end - start, text: String(text[previousEnd..<range.upperBound]), joinsPrevious: true))
                    previousEnd = range.upperBound
                }
                if previousEnd < text.endIndex, !spans.isEmpty {
                    spans[spans.count - 1].text += String(text[previousEnd...])
                }
            }
            return spans
        }
        var timedOut = false
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(75)) } catch { return }
            timedOut = true
            collector.cancel()
            await analyzer.cancelAndFinishNow()
        }
        defer { timeout.cancel() }
        do {
            _ = try await analyzer.analyzeSequence(from: AVAudioFile(forReading: url))
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let spans = try await collector.value
            guard !timedOut else { throw NSError(domain: "Speech", code: 1, userInfo: [NSLocalizedDescriptionKey: "识别超时，原音已保留，请重试。"]) }
            return spans
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
    private func recognize(_ url: URL, with recognizer: SFSpeechRecognizer) async throws -> [WordSpan] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            var transcript = SpeechTranscriptAccumulator()
            recognitionTask = recognizer.recognitionTask(with: request) { result, failure in
                guard !finished else { return }
                if let result, result.isFinal || result.speechRecognitionMetadata != nil {
                    transcript.accept(result.bestTranscription.segments.enumerated().map { i, word in
                        WordSpan(id: String(i), offset: word.timestamp, duration: word.duration, text: word.substring)
                    })
                    if result.isFinal {
                        finished = true
                        continuation.resume(returning: transcript.spans)
                    }
                }
                if let failure, !finished { finished = true; continuation.resume(throwing: failure) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 75) { [weak self] in
                guard !finished else { return }; finished = true
                self?.recognitionTask?.cancel()
                continuation.resume(throwing: NSError(domain: "Speech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recognition timed out; retry this clip."]))
            }
        }
    }
    func play(_ clip: Clip, offset: Double = 0) {
        guard clips.contains(where: { $0.id == clip.id }) else { error = "记录已删除。"; return }
        if clip.audioExpiredAt != nil {
            if let slice = audioVault.slices.first(where: { $0.clipID == clip.id && $0.start <= offset && $0.end > offset }) { playSlice(slice, offset: offset) }
            else { error = "此处原音已到期且未保留，可继续阅读原文。" }
            return
        }
        guard !recording else { error = "请先结束录音，再回听。"; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: root.appendingPathComponent(clip.file))
            playbackOrigin = 0; playbackPosition = max(0, offset); player?.enableRate = true; player?.rate = playbackRate
            player?.currentTime = max(0, offset); player?.play(); playingID = clip.id
        } catch { self.error = error.localizedDescription }
    }
    func stopPlayback() { player?.stop(); playingID = nil }
    func pinAudio(_ clip: Clip) {
        guard var current = clips.first(where: { $0.id == clip.id }) else { return }
        guard current.audioExpiredAt == nil || current.audioPinned == true else { error = "整段原音已到期，不能恢复未保留的部分。"; return }
        current.audioPinned = !(current.audioPinned ?? false)
        do {
            try update(current)
            if current.audioPinned != true { try pruneRetainedAudio() }
            Task { await prepareRetainedAudio() }
        } catch { self.error = error.localizedDescription }
    }
    func cleanupCandidates(now: Date = Date()) -> [Clip] {
        guard archiveHealthy, vaultHealthy else { return [] }
        return clips.filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0.file).path) &&
            AudioVault.canExpire($0, archive: clips, state: audioVault, root: root, now: now, playingID: playingID)
        }
    }

    func cleanupAudio(now: Date = Date()) {
        guard archiveHealthy, vaultHealthy, !processing, !recording, !preparingAudio else { return }
        do {
            try pruneRetainedAudio(now: now)
            for clip in cleanupCandidates(now: now) {
                clips = try RetentionDisk.expire(clip, from: root, archive: clips, now: now, playingID: playingID)
            }
        } catch {
            do { clips = try ArchiveDisk.load(from: root) } catch { archiveHealthy = false }
            self.error = "清理未完成，请检查本地存储。"
        }
    }
    func deleteRecording(_ clip: Clip) {
        guard archiveHealthy else { return }
        stopPlayback()
        do { clips = try RetentionDisk.delete(clip, from: root, archive: clips) }
        catch {
            do { clips = try ArchiveDisk.load(from: root) } catch { archiveHealthy = false }
            self.error = "删除未完全完成，已阻止旧任务恢复记录，请检查存储。"
        }
        do { audioVault = try AudioVault.load(root); try replayHighlights() }
        catch { vaultHealthy = false; self.error = "保留片段删除未完成，已停止清理，请检查存储。" }
        do { try OutboundLog.redact(root: root, deleted: RetentionDisk.deletedIDs(from: root)) } catch { self.error = "外发记录清理失败，请检查存储。" }
        // Each cleanup gets a chance even if a different ledger is damaged.
        do { try redactDeletedHistory() } catch { self.error = "历史来源清理失败，请检查存储。" }
        do { try reconcileMemories() } catch { self.error = "记忆来源清理失败，记忆外发已停止。" }
        do { try reconcileQueue(); try refreshSearchIndex(locale: UserDefaults.standard.string(forKey: "locale") ?? "zh-CN") } catch { self.error = "转写队列或索引清理失败，请检查存储。" }
        do { try reconcileAutomaticReviews() } catch { self.error = "自动复盘队列清理失败，外发已停止。" }
    }
    private func redactDeletedHistory() throws {
        let deleted = try RetentionDisk.deletedIDs(from: root)
        let oldHistory = conversations; let oldReviews = reviews
        for i in conversations.indices {
            let removed = conversations[i].sources.filter { deleted.contains($0.clipID) }.map(\.id)
            conversations[i].invalidatedSourceIDs = Array(Set((conversations[i].invalidatedSourceIDs ?? []) + removed)).sorted()
            conversations[i].sources.removeAll { deleted.contains($0.clipID) }
            if !removed.isEmpty { conversations[i].contexts = nil }
        }
        for i in reviews.indices {
            let removed = reviews[i].sources.filter { deleted.contains($0.clipID) }.map(\.id)
            reviews[i].invalidatedSourceIDs = Array(Set((reviews[i].invalidatedSourceIDs ?? []) + removed)).sorted()
            reviews[i].sources.removeAll { deleted.contains($0.clipID) }
            if !removed.isEmpty { reviews[i].memoryCandidates = nil; reviews[i].highlightCandidates = nil; reviews[i].contexts = nil }
        }
        if historyHealthy, oldHistory != conversations { try Journal.save(conversations, to: root) }
        if reviewsHealthy, oldReviews != reviews { try Journal.saveReviews(reviews, to: root) }
    }
    func sourcesAreCurrent(_ sources: [SourceExcerpt]) -> Bool {
        let current = ArchiveRules.excerpts(clips)
        return sources.allSatisfy { current.contains($0) }
    }
    func editReview(_ id: UUID, text: String) throws {
        guard reviewsHealthy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let i = reviews.firstIndex(where: { $0.id == id }) else { throw ArchiveFailure.invalidSources }
        var next = reviews
        var revised = next[i]; revised.id = UUID(); revised.created = Date(); revised.userText = text; revised.userEditedAt = Date()
        if let version = revised.dayVersion, revised.userText == text {
            let batches = reviews.filter { $0.dayVersion == version && $0.automaticJobID != nil }.sorted { ($0.batchIndex ?? 0) < ($1.batchIndex ?? 0) }
            if !batches.isEmpty {
                revised.sources = batches.flatMap(\.sources)
                revised.answer = GroundedAnswer(answer: batches.map { $0.answer.answer }.joined(separator: "\n\n"), sourceIDs: Array(Set(batches.flatMap { $0.answer.sourceIDs })).sorted())
                revised.contexts = Array(Dictionary(batches.flatMap { $0.contexts ?? [] }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.id < $1.id }
            }
        }
        revised.automaticJobID = nil; revised.memoryCandidates = nil; revised.highlightCandidates = nil
        next.insert(revised, at: 0); try Journal.saveReviews(next, to: root); reviews = next
    }
    func saveReview(day: Date, answer: GroundedAnswer, sources: [SourceExcerpt], totalRecordings: Int, contexts: [ContextSample] = []) throws {
        guard reviewsHealthy, sourcesAreCurrent(sources) else { throw ArchiveFailure.invalidSources }
        let checked = try answer.checked(against: sources)
        let entry = SavedDailyReview(day: Calendar.current.startOfDay(for: day), answer: checked, sources: sources, totalRecordings: totalRecordings, contexts: contexts.isEmpty ? nil : contexts)
        let updated = [entry] + reviews
        try Journal.saveReviews(updated, to: root); reviews = updated
    }

    func saveAnswer(question: String, answer: GroundedAnswer, sources: [SourceExcerpt], memories: [MemoryContext] = [], contexts: [ContextSample] = []) throws {
        guard historyHealthy else { throw NSError(domain: "History", code: 1, userInfo: [NSLocalizedDescriptionKey: "History is unreadable; existing data has been preserved."]) }
        guard sourcesAreCurrent(sources), memoryContextsAreCurrent(memories, sources: sources) else { throw ArchiveFailure.invalidSources }
        let checked = try answer.checked(against: sources)
        let entry = SavedConversation(question: question, answer: checked, sources: sources, contexts: contexts.isEmpty ? nil : contexts, memories: memories.isEmpty ? nil : memories)
        let updated = [entry] + conversations
        try Journal.save(updated, to: root)
        conversations = updated
    }
    func saveMemoryHistory(_ updated: [SavedConversation]) throws {
        guard historyHealthy else { throw ArchiveFailure.invalidSources }
        try Journal.save(updated, to: root); conversations = updated
    }
    func startRecording() async {
        guard !recording, !processing, archiveHealthy else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { error = "需要麦克风权限，请在 iPhone 设置中开启。"; return }
        guard !recording, !processing else { return }
        do {
            error = nil
            try StorageGuard.requireSpace(root)
            stopPlayback()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let url = root.appendingPathComponent("phone-pending-" + UUID().uuidString + ".m4a")
            let audio = try PhoneMicrophoneCapture(url: url)
            try audio.start()
            recordingStarted = Date(); marks = []; recordingMarks = 0; recorder = audio; recording = true
            recordingLimitTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.stopRecording()
            }
        } catch { self.error = error.localizedDescription }
    }
    func markRecording() {
        guard recording, let recorder else { return }
        marks.append(recorder.currentTime); recordingMarks = marks.count
    }
    func stopRecording() {
        guard recording, let capture = recorder else { return }
        recordingLimitTask?.cancel(); recordingLimitTask = nil
        let started = recordingStarted ?? Date(), savedMarks = marks
        let captureError = capture.stop()
        let capturedDuration = capture.currentTime
        recorder = nil; recordingStarted = nil; recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard captureError == nil, capturedDuration >= 0.25 else {
            error = captureError ?? "没有收到足够的麦克风音频，请保持录音至少一秒后重试。待处理文件已保留。"
            return
        }
        processing = true
        Task {
            await importAudio(capture.url, started: started, marks: savedMarks)
            if error == nil { try? FileManager.default.removeItem(at: capture.url) }
            processing = false
            await resumeAutomaticTranscription()
        }
    }
    var recordingDuration: Double { recorder?.currentTime ?? 0 }
    var recordingLevels: [Double] { recorder?.levels ?? [] }
    @objc private func audioInterrupted(_ notification: Notification) {
        guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              type == AVAudioSession.InterruptionType.began.rawValue, recording else { return }
        stopRecording()
    }
    func importAudio(_ url: URL, started: Date = Date(), marks: [Double] = []) async {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard archiveHealthy else { throw ArchiveFailure.invalidClip }
            let original = try Data(contentsOf: url)
            let audio = try AVAudioPlayer(data: original)
            guard audio.duration > 0 && audio.duration <= 60 else { throw NSError(domain: "Import", code: 1, userInfo: [NSLocalizedDescriptionKey: "当前补充导入仅支持 60 秒以内音频。"]) }
            // The archive uses .m4a names. Renaming WAV bytes is playable by AVAudioPlayer
            // but rejected by on-device Speech, so normalize the actual container first.
            try StorageGuard.requireSpace(root, bytes: UInt64(original.count) * 2)
            let normalized = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            defer { try? FileManager.default.removeItem(at: normalized) }
            guard let exporter = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetAppleM4A) else { throw ArchiveFailure.invalidClip }
            try await exporter.export(to: normalized, as: .m4a)
            guard archiveHealthy else { throw ArchiveFailure.invalidClip }
            let bytes = try Data(contentsOf: normalized)
            let id = UUID().uuidString
            let clip = Clip(id: id, started: started, duration: audio.duration, marks: marks.filter { $0 <= audio.duration }, file: id + ".m4a", digest: SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined(), sessionID: UUID().uuidString)
            try StorageGuard.requireSpace(root, bytes: UInt64(bytes.count))
            try bytes.write(to: root.appendingPathComponent(clip.file), options: .atomic)
            let updated = try ArchiveRules.inserting(clip, into: clips)
            try ArchiveDisk.save(updated, to: root); clips = updated
            await resumeAutomaticTranscription()
        } catch { self.error = error.localizedDescription }
    }
    func restoreBackup(_ file: URL, password: String) throws {
        guard !recording, !processing, !preparingAudio, !automaticReviewRunner.busy, manualInFlight == 0 else { throw BackupFailure(message: "请等待录音、处理和 AI 请求结束后再恢复") }
        stopPlayback()
        let cleaned = try EncryptedBackup.restore(file: file, root: root, password: password)
        clips = try ArchiveDisk.load(from: root); conversations = try Journal.load(from: root); reviews = try Journal.loadReviews(from: root)
        sessionEvents = try SessionEvents.load(root)
        memoryState = try MemoryDisk.load(from: root); audioVault = try AudioVault.load(root); contextState = try ContextRules.load(root)
        transcriptionJobs = try ProcessingQueue.load(from: root); searchIndex = nil
        archiveHealthy = true; historyHealthy = true; reviewsHealthy = true; memoriesHealthy = true; vaultHealthy = true; contextHealthy = true; queueHealthy = true
        automaticReviewRunner = AutomaticReviewRunner(root: root); automaticReviewState = automaticReviewRunner.state
        automaticReviewRunner.onChange = { [weak self] state in self?.automaticReviewState = state }
        UserDefaults.standard.set(false, forKey: "automaticTranscription")
        try redactDeletedHistory(); try reconcileQueue(recovering: true); try replayMemoryBatches(); try replayHighlights()
        automaticReviewStatus = "已恢复；自动外发已暂停，需要重新确认授权"
        if !cleaned { error = "新库已恢复，但旧库残留清理失败，请检查存储。" }
    }
    func search(_ query: String, semantic: Bool, locale: String, since: Date = .distantPast, until: Date = .distantFuture) -> [SourceExcerpt] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        do {
            try refreshSearchIndex(locale: locale)
            let language: NLLanguage = locale.hasPrefix("zh") ? .simplifiedChinese : .english
            let vector = semantic ? NLEmbedding.sentenceEmbedding(for: language)?.vector(for: query) : nil
            return searchIndex?.search(query, vector: vector, since: since, until: until) ?? []
        } catch { self.error = "本地索引不可用：\(error.localizedDescription)"; return [] }
    }
}

// Owns the input tap and serializes file finalization against in-flight audio callbacks.
private final class PhoneMicrophoneCapture: @unchecked Sendable {
    let url: URL
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var failure: String?
    private let sampleRate: Double
    private var accepting = true
    private var recentLevels: [Double] = []
    var levels: [Double] { lock.lock(); defer { lock.unlock() }; return recentLevels }

    init(url: URL) throws {
        self.url = url
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Recording", code: 3, userInfo: [NSLocalizedDescriptionKey: "麦克风输入不可用。"])
        }
        sampleRate = format.sampleRate
        file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 64000], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.accepting, self.failure == nil else { return }
            let remaining = max(0, AVAudioFramePosition(self.sampleRate * 60) - self.frames)
            guard remaining > 0 else { return }
            buffer.frameLength = min(buffer.frameLength, AVAudioFrameCount(remaining))
            if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
                var energy = 0.0
                let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
                for i in 0..<Int(buffer.frameLength) { let value = Double(channels[0][i * stride]); energy += value * value }
                let decibels = 20 * log10(max(sqrt(energy / Double(buffer.frameLength)), 0.000001))
                self.recentLevels.append(min(1, max(0, (decibels + 60) / 60)))
                if self.recentLevels.count > 48 { self.recentLevels.removeFirst(self.recentLevels.count - 48) }
            }
            do { try self.file?.write(from: buffer); self.frames += AVAudioFramePosition(buffer.frameLength) }
            catch { self.failure = "录音写入失败：\(error.localizedDescription)" }
        }
    }
    var currentTime: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(frames) / sampleRate
    }
    func start() throws { try engine.start() }
    @discardableResult func stop() -> String? {
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        lock.lock(); defer { lock.unlock() }
        accepting = false; file = nil
        return failure
    }
}
