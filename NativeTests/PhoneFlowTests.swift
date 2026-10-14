import XCTest
import AVFoundation
import NaturalLanguage
import Speech
@testable import DayTrace

@MainActor final class PhoneFlowTests: XCTestCase {
    func testPhysicalInputEngineReceivesFrames() async throws {
        guard AVAudioApplication.shared.recordPermission == .granted else { throw XCTSkip("Requires microphone permission") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        final class Counter: @unchecked Sendable {
            let lock = NSLock(); var frames: UInt32 = 0
            func add(_ n: UInt32) { lock.lock(); frames += n; lock.unlock() }
            func read() -> UInt32 { lock.lock(); defer { lock.unlock() }; return frames }
        }
        let counter = Counter()
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in counter.add(buffer.frameLength) }
        defer { engine.stop(); input.removeTap(onBus: 0); try? session.setActive(false) }
        try engine.start()
        try await Task.sleep(for: .seconds(2))
        print("INPUT_ENGINE_FRAMES \(counter.read())")
        XCTAssertGreaterThan(counter.read(), 10000)
    }
    func testPhysicalMicrophoneRecordsBeyondStartup() async throws {
        guard AVAudioApplication.shared.recordPermission == .granted else { throw XCTSkip("Requires user microphone permission") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhoneStore(rootURL: root, activateConnectivity: false)
        await store.startRecording()
        XCTAssertTrue(store.recording)
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(store.recording, "Recorder ended before explicit stop")
        XCTAssertFalse(store.recordingLevels.isEmpty, "Input meter must receive microphone frames")
        XCTAssertTrue(store.recordingLevels.allSatisfy { $0.isFinite && (0...1).contains($0) })
        store.stopRecording()
        for _ in 0..<30 where store.clips.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(store.error)
        XCTAssertGreaterThan(try XCTUnwrap(store.clips.first).duration, 1.5)
    }
    func testDeviceRetentionExtractsBeforeExpiryAndKeepsSearchableText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var clip = try fixture(root)
        clip.sessionID = UUID().uuidString
        try ArchiveDisk.save([clip], to: root)
        let store = PhoneStore(rootURL: root, activateConnectivity: false)
        let future = RetentionRules.expires(clip).addingTimeInterval(1)
        XCTAssertTrue(store.cleanupCandidates(now: future).isEmpty)
        await store.prepareRetainedAudio()
        XCTAssertNil(store.error)
        let slice = try XCTUnwrap(store.audioVault.slices.first)
        XCTAssertTrue(AudioVault.verified(slice, root: root))
        store.play(clip)
        XCTAssertTrue(store.cleanupCandidates(now: future).isEmpty, "Active playback must protect original")
        store.stopPlayback()
        XCTAssertEqual(store.cleanupCandidates(now: future).map(\.id), [clip.id])
        store.cleanupAudio(now: future)
        XCTAssertNil(store.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(clip.file).path))
        let reloaded = PhoneStore(rootURL: root, activateConnectivity: false)
        XCTAssertNotNil(reloaded.clips.first?.audioExpiredAt)
        XCTAssertEqual(reloaded.search("电源噪声", semantic: false, locale: "zh-CN").first?.clipID, clip.id)
        reloaded.playSlice(slice, offset: 1)
        defer { reloaded.stopPlayback() }
        XCTAssertTrue(try XCTUnwrap(reloaded.player).isPlaying)
        XCTAssertEqual(reloaded.playbackPosition, 1, accuracy: 0.05)
    }

    func testDeviceMemoryEditDisableDeletePersistWithoutRevival() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = try fixture(root)
        try ArchiveDisk.save([clip], to: root)
        let sources = ArchiveRules.excerpts([clip])
        let source = try XCTUnwrap(sources.first)
        let candidate = MemoryCandidate(content: "录音提到检查电源噪声", topic: "测试计划", category: .plan, subject: .record, uncertain: false,
            evidence: [MemoryEvidence(sourceID: source.id, quote: source.text)])
        let store = PhoneStore(rootURL: root, activateConnectivity: false)
        try store.persistMemories(MemoryRules.ingest([candidate], jobID: UUID(), sources: sources, into: MemoryState(), now: Date()))
        let id = try XCTUnwrap(store.memoryState.items.first).id
        store.editMemory(id, content: "人工更正的测试计划")
        XCTAssertNil(store.error)
        let edited = PhoneStore(rootURL: root, activateConnectivity: false)
        XCTAssertEqual(edited.memoryState.items.first?.content, "人工更正的测试计划")
        edited.setMemoryActive(id, active: false)
        XCTAssertTrue(PhoneStore(rootURL: root, activateConnectivity: false).memoryContexts(for: sources).isEmpty)
        edited.deleteMemory(id)
        let deleted = PhoneStore(rootURL: root, activateConnectivity: false)
        XCTAssertTrue(deleted.memoryState.items.isEmpty)
        let replayed = MemoryRules.ingest([candidate], jobID: UUID(), sources: sources, into: deleted.memoryState, now: Date())
        XCTAssertTrue(replayed.items.isEmpty)
    }

    func testDeviceDense90DayKeywordIndexPerformanceAndNoAnswer() throws {
        // 90 days * 8 hours/day * 120 thirty-second clips/hour.
        // Text-only synthetic load; no claim about real-world relevance or ASR.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = 90 * 8 * 120
        var index = SearchIndex(model: "physical-phone-dense-keyword-fixture")
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let sources = (0..<count).map { i in
            SourceExcerpt(id: "fixture-\(i):0", clipID: "fixture-\(i)", offset: 0,
                text: "电源噪声 测试条目 serial\(i)", started: start.addingTimeInterval(Double(i / 960) * 86400 + Double(i % 960) * 30))
        }
        let buildStart = Date()
        index.reconcile(sources: sources, vector: { _ in nil })
        try index.save(root)
        let buildSeconds = Date().timeIntervalSince(buildStart)
        index = try SearchIndex.load(root, model: index.model)
        XCTAssertEqual(index.entries.count, count)
        var times: [Double] = []
        for i in 0..<30 {
            let target = i * 2879
            let before = Date()
            let results = index.search("serial\(target)")
            times.append(Date().timeIntervalSince(before))
            XCTAssertTrue(results.prefix(5).contains { $0.clipID == "fixture-\(target)" })
        }
        XCTAssertTrue(index.search("龘麤灪").isEmpty)
        XCTAssertTrue(index.search("serial0", since: start.addingTimeInterval(100 * 86400)).isEmpty)
        let p95 = times.sorted()[28]
        print("PHONE_DENSE_KEYWORD documents=\(count) queries=30 p95_seconds=\(p95) build_and_save_seconds=\(buildSeconds) synthetic=true vectors=false")
        XCTAssertLessThan(p95, 2)
    }

    func testDeviceChineseSemanticRetrievalWithCrossDayFilter() throws {
        guard let model = NLEmbedding.sentenceEmbedding(for: .simplifiedChinese) else { throw XCTSkip("Physical device has no Chinese sentence model") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pairs: [(String,String)] = [
            ("明天上午十点与陈工检查电源板纹波，示波器用二十兆带宽。", "电源噪声的检查约在什么时候？"),
            ("周五把修改过的简历发给招聘负责人，申请硬件产品经理。", "求职材料准备何时提交？"),
            ("牙科复诊安排在下周二下午三点，要带之前的片子。", "牙齿复查需要带什么？"),
            ("给妈妈的生日礼物选了蓝色围巾，周日拿去。", "母亲过生日准备送哪件东西？"),
            ("家里的路由器总掉线，今晚先更新固件再测无线覆盖。", "无线网络不稳定准备怎么处理？"),
            ("牛奶喝完了，下班后去超市买鸡蛋、牛奶和西红柿。", "今天要补充哪些食材？"),
            ("周六骑车到河边，大概二十公里，不追求速度。", "周末的自行车路线有多远？"),
            ("Python 脚本导出表格报编码错误，改用 UTF-8 后正常。", "表格导出乱码是怎样解决的？"),
            ("小李推荐那家川菜馆，酸菜鱼不错，人均八十元。", "朋友推荐了哪道鱼菜，预算多少？"),
            ("明早航班七点起飞，决定五点从家出发去机场。", "为了赶飞机计划几点出门？"),
            ("客户把接口电压从三点三伏改成一点八伏，需要重新核查电平。", "客户修改了什么电气接口要求？"),
            ("这周读完了关于注意力机制的章节，想做一个小型检索实验。", "学习完模型原理后想做哪种实验？"),
            ("房东说热水器周三维修，上午需要有人在家。", "家电维修约在哪天，要留人在家吗？"),
            ("咖啡下午喝容易睡不着，以后午饭后改成无咖啡因茶。", "下午饮料准备如何调整？"),
            ("相机存储卡空间不够，先把照片拷到移动硬盘再格式化。", "拍照存储不足时怎样保护旧照片？"),
            ("周报里要说明测试失败的根因，不要只写问题已经解决。", "工作汇报应该补充哪类分析？"),
            ("带狗去宠物医院打疫苗前，需要确认最近没有发烧。", "宠物接种前需要核对什么？"),
            ("演出票已经买好，下个月六号晚上七点半在剧院门口见。", "看演出的集合时间是什么？"),
            ("旧键盘空格键偶尔连击，打算先换轴体再决定是否换整块板。", "键盘重复输入打算先修哪个零件？"),
            ("上次做番茄面盐放多了，下次先减半再尝味道。", "做面条的调味准备怎样改进？"),
            ("给项目建立每周备份，密码保存在自己的密码管理器中。", "项目资料怎样防止丢失？"),
            ("跑步鞋磨损严重，下次试鞋时重点看前掌宽度。", "挑运动鞋最需要关注哪里？"),
            ("预算里房租固定三千五，旅行费用单独留两千。", "旅行安排留了多少钱？"),
            ("会议决定先做离线原型，暂时不接入公司的线上客户数据。", "第一版原型使用线上数据吗？"),
            ("冰箱门封条松了导致结霜，周末换新封条。", "冰箱结冰的原因和处理计划是什么？"),
            ("晚上练习英语面试，重点讲清楚一次硬件故障定位经历。", "外语面试准备讲哪个案例？"),
            ("给阳台植物浇水前先摸土，表层湿润就再等一天。", "什么时候给盆栽补水？"),
            ("同事建议把设计评审提前，避免采购后才发现接口不匹配。", "为什么要提前评审设计？"),
            ("这次旅行不排满行程，每天按体力选一个主要地点。", "出游的行程密度打算怎么安排？"),
            ("桌面灯的暖光晚上舒服，白天看图纸改用中性光。", "工作和晚上休息时灯光有什么区别？")
        ]
        var clips: [Clip] = []
        for (i, pair) in pairs.enumerated() {
            var clip = try fixture(root, text: pair.0)
            clip.started = Date(timeIntervalSince1970: 1_780_000_000 + Double(i) * 86400)
            clips.append(clip)
        }
        try ArchiveDisk.save(clips, to: root)
        let store = PhoneStore(rootURL: root, activateConnectivity: false)
        var hits = 0
        var times: [Double] = []
        for (i, pair) in pairs.enumerated() {
            let start = Date()
            let found = store.search(pair.1, semantic: true, locale: "zh-CN")
            times.append(Date().timeIntervalSince(start))
            if found.prefix(5).contains(where: { $0.clipID == clips[i].id }) { hits += 1 }
        }
        XCTAssertGreaterThanOrEqual(hits, 27)
        let filtered = store.search(pairs[0].1, semantic: true, locale: "zh-CN", since: clips[1].started)
        XCTAssertFalse(filtered.contains(where: { $0.clipID == clips[0].id }))
        let reloaded = PhoneStore(rootURL: root, activateConnectivity: false)
        XCTAssertFalse(reloaded.search(pairs[0].1, semantic: true, locale: "zh-CN").isEmpty)
        print("PHONE_SEMANTIC dimensions=\(model.dimension) development_pairs=30 top5_hits=\(hits) query_p95_seconds=\(times.sorted()[28]) date_filter=true reload=true")
    }

    // Opt-in only: one synthetic live request through the user's already configured service.
    func testTranscriptCorrectionPreservesAudioTimingAndInvalidatesOldSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = try fixture(root, text: "周五下午检查电原噪声")
        try ArchiveDisk.save([clip], to: root)
        let store = PhoneStore(rootURL: root, activateConnectivity: false)
        let before = ArchiveRules.excerpts(store.clips)
        try store.saveAnswer(question: "做什么", answer: GroundedAnswer(answer: "检查电原噪声", sourceIDs: [before[0].id]), sources: before)
        let word = try XCTUnwrap(clip.transcript.first)
        try store.correctTranscript(clipID: clip.id, expected: word, text: "周五下午检查电源噪声")
        XCTAssertFalse(store.sourcesAreCurrent(before))
        XCTAssertThrowsError(try store.correctTranscript(clipID: clip.id, expected: word, text: "过期编辑不得覆盖"))
        let reload = PhoneStore(rootURL: root, activateConnectivity: false)
        let corrected = try XCTUnwrap(reload.clips.first)
        XCTAssertEqual(corrected.digest, clip.digest)
        XCTAssertEqual(corrected.transcript.first?.offset, word.offset)
        XCTAssertEqual(corrected.transcript.first?.duration, word.duration)
        XCTAssertEqual(corrected.transcript.first?.originalText, word.text)
        XCTAssertEqual(corrected.text, "周五下午检查电源噪声")
        XCTAssertFalse(reload.sourcesAreCurrent(try XCTUnwrap(reload.conversations.first).sources))
        XCTAssertFalse(reload.search("电源", semantic: false, locale: "zh-CN").isEmpty)
        XCTAssertEqual(AudioVault.hash(try Data(contentsOf: root.appendingPathComponent(clip.file))), clip.digest)
    }

    func testOptInLiveStructuredResponseContract() async throws {
        guard ProcessInfo.processInfo.environment["DAYTRACE_LIVE_ACCEPTANCE"] == "1" else { throw XCTSkip("Opt-in only") }
        let endpoint = UserDefaults.standard.string(forKey: "endpoint") ?? ""
        let model = UserDefaults.standard.string(forKey: "model") ?? ""
        guard endpoint == "https://ai-proxy.chatwise.app/generativelanguage/v1beta/models/gemini-3.1-flash-lite:generateContent", model == "gemini-3.1-flash-lite" else { XCTFail("Unexpected service"); return }
        let source = SourceExcerpt(id: "synthetic:0", clipID: "synthetic", offset: 0, text: "合成验收记录：项目计划是周五下午三点检查电源噪声，完成后记录测试结果。", started: Date())
        let request = try AIWire.request(service: AIService(endpoint: endpoint, model: model), key: KeyVault.load(endpoint: endpoint), question: AIWire.reviewQuestion, sources: [source], generateMemories: true, generateHighlights: true)
        let data = try await AITransport.send(request)
        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("live-contract-response.json"), options: .atomic)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let candidate = (json?["candidates"] as? [[String: Any]])?.first
        print("LIVE_CONTRACT finish=" + (candidate?["finishReason"] as? String ?? "missing"))
        do {
            let reply = try AIWire.decode(data, sources: [source], generateMemories: true, generateHighlights: true)
            print("LIVE_CONTRACT memories=\(reply.memoryCandidates.count) highlights=\(reply.highlightCandidates.count)")
        } catch let DecodingError.keyNotFound(key, _) {
            XCTFail("Response missing schema key: " + key.stringValue)
        } catch let DecodingError.typeMismatch(type, context) {
            XCTFail("Response type mismatch: " + String(describing: type) + " at " + context.codingPath.map(\.stringValue).joined(separator: "."))
        } catch let DecodingError.dataCorrupted(context) {
            XCTFail("Response data corrupted at " + context.codingPath.map(\.stringValue).joined(separator: ".") + " " + context.debugDescription)
        } catch { XCTFail("Response rejected: " + String(describing: type(of: error))) }
    }

    // Normal test runs cannot consume provider quota or read a credential for another endpoint.
    func testOptInLiveAutomaticReviewMemoryHighlightClosure() async throws {
        guard ProcessInfo.processInfo.environment["DAYTRACE_LIVE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires explicit live acceptance run")
        }
        let endpoint = UserDefaults.standard.string(forKey: "endpoint") ?? ""
        let model = UserDefaults.standard.string(forKey: "model") ?? ""
        guard endpoint == "https://ai-proxy.chatwise.app/generativelanguage/v1beta/models/gemini-3.1-flash-lite:generateContent",
              model == "gemini-3.1-flash-lite", !KeyVault.load(endpoint: endpoint).isEmpty else {
            XCTFail("Expected user-configured Chatwise Gemini credential"); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var clip = try fixture(root, text: "合成验收记录：项目计划是周五下午三点检查电源噪声，完成后记录测试结果。")
        clip.marks = []; clip.sessionID = UUID().uuidString
        clip.started = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86400 + 36000)
        try ArchiveDisk.save([clip], to: root)
        let store = PhoneStore(rootURL: root, activateConnectivity: false)
        let service = AIService(endpoint: endpoint, model: model)
        try store.automaticReviewRunner.approve(service: service, limit: 1, now: Date(),
            generateMemories: true, generateHighlights: true, tokensPer24Hours: 20000)
        await store.resumeAutomaticReviews()
        let liveAudits = try OutboundLog.load(root)
        print("LIVE_AUDIT " + liveAudits.map(\.outcome).joined(separator: ","))
        XCTAssertNil(store.error)
        XCTAssertEqual(store.automaticReviewState.requests.count, 1)
        print("LIVE_STATE " + store.automaticReviewState.jobs.map { $0.state.rawValue }.joined(separator: ",") + " status=" + store.automaticReviewStatus)
        let attemptedID = store.automaticReviewState.requests.first?.jobID
        XCTAssertEqual(store.automaticReviewState.jobs.first(where: { $0.id == attemptedID })?.state, .succeeded)
        let review = try XCTUnwrap(store.reviews.first, "Live response must be published")
        XCTAssertFalse(review.answer.sourceIDs.isEmpty)
        XCTAssertTrue(store.sourcesAreCurrent(review.sources))
        XCTAssertFalse(store.memoryState.items.isEmpty, "Explicit synthetic plan must survive evidence validation")
        let highlight = try XCTUnwrap(store.audioVault.highlights.first, "Explicit plan must produce a valid highlight")
        XCTAssertFalse(highlight.favorite)
        XCTAssertTrue(AudioVault.ranges(clip, archive: store.clips, state: store.audioVault).isEmpty,
            "Unfavorited AI highlight must not protect audio")
        store.setFavorite(highlight.id)
        await store.prepareRetainedAudio()
        XCTAssertNil(store.error)
        let slice = try XCTUnwrap(store.audioVault.slices.first)
        XCTAssertTrue(AudioVault.verified(slice, root: root))
        store.playSlice(slice)
        XCTAssertTrue(try XCTUnwrap(store.player).isPlaying)
        store.stopPlayback()
        let reloaded = PhoneStore(rootURL: root, activateConnectivity: false)
        await reloaded.resumeAutomaticReviews()
        XCTAssertEqual(reloaded.reviews.count, 1)
        XCTAssertEqual(reloaded.automaticReviewState.requests.count, 1, "Restart must not resend")
        XCTAssertEqual(reloaded.memoryState.items.count, store.memoryState.items.count)
        XCTAssertEqual(reloaded.audioVault.highlights.count, 1)
        let memory = try XCTUnwrap(reloaded.memoryState.items.first)
        reloaded.editMemory(memory.id, content: "人工更正：周六下午检查电源噪声")
        reloaded.setMemoryActive(memory.id, active: false)
        try reloaded.replayMemoryBatches()
        XCTAssertTrue(reloaded.memoryContexts(for: review.sources).isEmpty)
        XCTAssertEqual(reloaded.memoryState.items.first?.content, "人工更正：周六下午检查电源噪声")
        let audit = try OutboundLog.load(root)
        XCTAssertEqual(audit.count, 1)
        XCTAssertEqual(audit.first?.sources.count, 1)
        XCTAssertTrue(audit.first?.contexts.isEmpty == true)
        print("LIVE_PHONE_CLOSURE requests=1 reviews=1 memories=\(store.memoryState.items.count) highlights=1 favorite_media_verified=true restart_no_resend=true disabled_memory_excluded=true")
    }

    // Opt-in public, licensed corpus. Uses the production on-device queue in an isolated archive.
    func testOptInPublicCorpusOnDeviceTranscription() async throws {
        guard ProcessInfo.processInfo.environment["DAYTRACE_PUBLIC_CORPUS"] == "1" else { throw XCTSkip("Public corpus acceptance is opt-in") }
        struct Sample: Codable { let file: String; let category: String; let reference: String; let duration: Double; let sha256: String }
        struct Result: Codable { let file: String; let category: String; let reference: String; let hypothesis: String; let duration: Double; let elapsed: Double; let status: String; let failure: String?; let spans: [WordSpan] }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let corpus = docs.appendingPathComponent("PublicASRAcceptance")
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: corpus.appendingPathComponent("manifest.json")))
        XCTAssertGreaterThanOrEqual(samples.reduce(0) { $0 + $1.duration }, 1800)
        var results: [Result] = []
        let resultURL = docs.appendingPathComponent("public-asr-results.json")
        let limit = Int(ProcessInfo.processInfo.environment["DAYTRACE_CORPUS_LIMIT"] ?? "") ?? samples.count
        for (index, sample) in samples.prefix(limit).enumerated() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-asr-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bytes = try Data(contentsOf: corpus.appendingPathComponent(sample.file))
            XCTAssertEqual(AudioVault.hash(bytes), sample.sha256)
            let store = PhoneStore(rootURL: root, activateConnectivity: false)
            let started = Date()
            await store.importAudio(corpus.appendingPathComponent(sample.file))
            await store.transcribePending(locale: "zh-CN")
            let actual = try XCTUnwrap(store.clips.first)
            results.append(Result(file: sample.file, category: sample.category, reference: sample.reference, hypothesis: actual.text, duration: sample.duration, elapsed: Date().timeIntervalSince(started), status: actual.status, failure: actual.failure ?? store.error, spans: actual.transcript))
            try JSONEncoder().encode(results).write(to: resultURL, options: .atomic)
            print("PUBLIC_ASR progress=\(index + 1)/\(samples.count) category=\(sample.category) status=\(actual.status) seconds=\(sample.duration)")
            XCTAssertEqual(actual.status, "ready", sample.file + ": " + (actual.failure ?? store.error ?? "unknown"))
            XCTAssertFalse(actual.transcript.isEmpty)
            XCTAssertTrue(actual.transcript.allSatisfy { $0.offset.isFinite && $0.duration.isFinite && $0.offset >= 0 && $0.duration >= 0 && $0.offset + $0.duration <= actual.duration + 0.2 }, sample.file)
            XCTAssertTrue(zip(actual.transcript, actual.transcript.dropFirst()).allSatisfy { $0.offset <= $1.offset }, sample.file)
            if let last = actual.transcript.last {
                store.play(actual, offset: last.offset)
                XCTAssertEqual(store.playingID, actual.id)
                XCTAssertEqual(store.playbackPosition, last.offset, accuracy: 0.2)
                store.stopPlayback()
            }
        }
    }

    func testOptInPublicCorpusRetrievalAfterTranscription() throws {
        guard ProcessInfo.processInfo.environment["DAYTRACE_PUBLIC_CORPUS"] == "1" else { throw XCTSkip("Public corpus acceptance is opt-in") }
        struct Result: Decodable { let file: String; let reference: String; let hypothesis: String; let duration: Double; let status: String; let spans: [WordSpan] }
        struct Query: Decodable { let query: String; let expected: [String] }
        struct Outcome: Codable { let query: String; let expected: [String]; let found: [String]; let hit: Bool }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let rows = try JSONDecoder().decode([Result].self, from: Data(contentsOf: docs.appendingPathComponent("public-asr-results.json")))
        let queries = try JSONDecoder().decode([Query].self, from: Data(contentsOf: docs.appendingPathComponent("PublicASRAcceptance/queries.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-search-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var clips: [Clip] = []; var names: [String: String] = [:]
        for (i, row) in rows.enumerated() where row.status == "ready" {
            let id = UUID().uuidString
            names[id] = URL(fileURLWithPath: row.file).deletingPathExtension().lastPathComponent
            // Distinct dates exercise the filter; public clips are not a real longitudinal diary.
            clips.append(Clip(id: id, started: Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 86400), duration: row.duration, marks: [], file: id + ".m4a", digest: String(repeating: "a", count: 64), transcript: row.spans, status: "ready"))
        }
        try ArchiveDisk.save(clips, to: root)
        let store = PhoneStore(rootURL: root, activateConnectivity: false)
        var outcomes: [Outcome] = []
        for query in queries {
            let sources = store.search(query.query, semantic: true, locale: "zh-CN")
            let found = Array(sources.prefix(5)).compactMap { names[$0.clipID] }
            outcomes.append(Outcome(query: query.query, expected: query.expected, found: found, hit: !Set(found).isDisjoint(with: query.expected)))
        }
        let chosen = try XCTUnwrap(clips.first)
        let filtered = store.search(queries[0].query, semantic: true, locale: "zh-CN", since: chosen.started.addingTimeInterval(86400))
        XCTAssertFalse(filtered.contains { $0.clipID == chosen.id })
        try JSONEncoder().encode(outcomes).write(to: docs.appendingPathComponent("public-retrieval-results.json"), options: .atomic)
        print("PUBLIC_RETRIEVAL queries=\(outcomes.count) top5_hits=\(outcomes.filter(\.hit).count) date_filter=true")
        XCTAssertEqual(outcomes.count, 30)
        // This is an acceptance measurement, not a tuned development threshold.
    }

    func testOptInPublicAudioLiveQuestionClosure() async throws {
        guard ProcessInfo.processInfo.environment["DAYTRACE_LIVE_ACCEPTANCE"] == "1",
              ProcessInfo.processInfo.environment["DAYTRACE_PUBLIC_CORPUS"] == "1" else { throw XCTSkip("Explicit public audio and live service acceptance required") }
        let endpoint = UserDefaults.standard.string(forKey: "endpoint") ?? ""
        let model = UserDefaults.standard.string(forKey: "model") ?? ""
        guard endpoint == "https://ai-proxy.chatwise.app/generativelanguage/v1beta/models/gemini-3.1-flash-lite:generateContent", model == "gemini-3.1-flash-lite" else { XCTFail("Unexpected service"); return }
        struct Row: Decodable { let file: String; let spans: [WordSpan] }
        struct Outcome: Codable { let question: String; let answer: GroundedAnswer; let sources: [SourceExcerpt] }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: docs.appendingPathComponent("public-asr-results.json")))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("public-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = PhoneStore(rootURL: root, activateConnectivity: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for row in rows where ["mandarin_english-000.wav", "mandarin_english-005.wav", "mandarin_english-023.wav", "mandarin_clean-012.wav"].contains(row.file) {
            await store.importAudio(docs.appendingPathComponent("PublicASRAcceptance").appendingPathComponent(row.file))
            var clip = try XCTUnwrap(store.clips.first(where: { $0.status != "ready" }))
            clip.transcript = row.spans; clip.status = "ready"; clip.failure = nil
            try store.update(clip)
        }
        var outcomes: [Outcome] = []
        for question in ["这些公开录音分别提到：上学期学了什么编程语言，学长如何帮助新生，以及北京张家口申办有什么优势？逐项回答，只根据原文，不把说话人当成用户。", "这些公开录音能否证明用户明天下午三点要去医院？如果没有明确证据，请直接说无法确定，不要编造计划。"] {
            let sources = store.clips.flatMap { Array(ArchiveRules.excerpts([$0]).prefix(2)) }
            let answer = try await AIClient(endpoint: endpoint, model: model, auditRoot: root).ask(question, sources: sources)
            try store.saveAnswer(question: question, answer: answer, sources: sources)
            for id in answer.sourceIDs {
                let source = try XCTUnwrap(sources.first(where: { $0.id == id }))
                let clip = try XCTUnwrap(store.clips.first(where: { $0.id == source.clipID }))
                store.play(clip, offset: source.offset)
                XCTAssertTrue(try XCTUnwrap(store.player).isPlaying)
                store.stopPlayback()
            }
            outcomes.append(Outcome(question: question, answer: answer, sources: sources))
            try JSONEncoder().encode(outcomes).write(to: docs.appendingPathComponent("public-live-results.json"), options: .atomic)
        }
        let reloaded = PhoneStore(rootURL: root, activateConnectivity: false)
        XCTAssertEqual(reloaded.conversations.count, 2)
        let audits = try OutboundLog.load(root)
        XCTAssertEqual(audits.count, 2)
        XCTAssertTrue(audits.allSatisfy { $0.contexts.isEmpty })
        print("PUBLIC_LIVE requests=2 saved=2 citations_playable=true health_location_excluded=true")
    }

    func testOptInModernOnDeviceSpeechControl() async throws {
        guard ProcessInfo.processInfo.environment["DAYTRACE_PUBLIC_CORPUS"] == "1" else { throw XCTSkip("Opt-in public corpus only") }
        guard #available(iOS 26, *), SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else { throw XCTSkip("Modern Chinese transcription unavailable") }
        struct Row: Decodable { let file: String; let category: String; let reference: String; let duration: Double }
        struct Output: Codable { let file: String; let category: String; let reference: String; let hypothesis: String; let duration: Double; let elapsed: Double; let status: String }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let corpus = docs.appendingPathComponent("PublicASRAcceptance")
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: corpus.appendingPathComponent("manifest.json")))
        let setupModule = SpeechTranscriber(locale: locale, preset: .transcription)
        print("MODERN_SPEECH asset_status=\(await AssetInventory.status(forModules: [setupModule]))")
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [setupModule]) { try await request.downloadAndInstall() }
        var output: [Output] = []
        for row in rows.filter({ $0.file.hasPrefix("mandarin_clean-00") || $0.file.hasPrefix("mandarin_english-00") }).prefix(20) {
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            let analyzer = SpeechAnalyzer(modules: [module])
            let collector = Task { () throws -> String in
                var text = ""
                for try await result in module.results { text += String(result.text.characters) }
                return text
            }
            let started = Date()
            do {
                _ = try await analyzer.analyzeSequence(from: AVAudioFile(forReading: corpus.appendingPathComponent(row.file)))
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let text = try await collector.value
                output.append(Output(file: row.file, category: row.category, reference: row.reference, hypothesis: text, duration: row.duration, elapsed: Date().timeIntervalSince(started), status: "ready"))
                try JSONEncoder().encode(output).write(to: docs.appendingPathComponent("public-modern-results.json"), options: .atomic)
                print("MODERN_SPEECH file=\(row.file) completed=\(output.count)")
            } catch { collector.cancel(); await analyzer.cancelAndFinishNow(); throw error }
        }
    }

    private func fixture(_ root: URL, text: String = "周五下午三点检查电源噪声") throws -> Clip {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let url = root.appendingPathComponent(id + ".m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for i in 0..<48000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 16000)) * 0.05 }
        do { let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000]); try file.write(from: buffer) }
        return Clip(id: id, started: Date(timeIntervalSince1970: 1_790_000_000), duration: 3, marks: [1], file: url.lastPathComponent, digest: AudioVault.hash(try Data(contentsOf: url)), transcript: [WordSpan(id: "0", offset: 0.5, duration: 2, text: text)], status: "ready")
    }

    func testDeviceSearchDateFilterReloadAndPlaybackPosition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clip = try fixture(root)
        try ArchiveDisk.save([clip], to: root)
        let store = PhoneStore(rootURL: root, activateConnectivity: false)
        let results = store.search("电源噪声", semantic: false, locale: "zh-CN")
        XCTAssertEqual(results.first?.clipID, clip.id)
        XCTAssertEqual(results.first?.offset, 0.5)
        XCTAssertTrue(store.search("电源噪声", semantic: false, locale: "zh-CN", since: clip.started.addingTimeInterval(10)).isEmpty)
        XCTAssertTrue(store.search("   ", semantic: true, locale: "zh-CN").isEmpty)
        let reloaded = PhoneStore(rootURL: root, activateConnectivity: false)
        XCTAssertEqual(reloaded.search("电源噪声", semantic: false, locale: "zh-CN").first?.id, results.first?.id)
        store.playbackRate = 1.5
        store.play(clip, offset: 0.5)
        defer { store.stopPlayback() }
        XCTAssertNil(store.error)
        XCTAssertEqual(store.playingID, clip.id)
        XCTAssertTrue(try XCTUnwrap(store.player).isPlaying)
        XCTAssertEqual(try XCTUnwrap(store.player).rate, 1.5, accuracy: 0.01)
        store.seekPlayback(1.5)
        // Live AAC playback time is not sample-exact; allow 100 ms, still below the PRD 2 s gate.
        XCTAssertEqual(store.playbackPosition, 1.5, accuracy: 0.1)
        store.seekPlayback(-10)
        XCTAssertEqual(store.playbackPosition, 0, accuracy: 0.05)
    }

    func testDeviceBackupWrongPasswordPreservesLibraryAndRestoreReloadsSearch() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("source")
        let target = parent.appendingPathComponent("target")
        let clip = try fixture(source)
        let existing = try fixture(target, text: "现有记录保持完整")
        try ArchiveDisk.save([clip], to: source)
        try ArchiveDisk.save([existing], to: target)
        let backup = parent.appendingPathComponent("fixture.daytrace")
        try EncryptedBackup.export(root: source, destination: backup, password: "test-only-password-2026")
        let before = try Data(contentsOf: target.appendingPathComponent("archive.json"))
        XCTAssertThrowsError(try EncryptedBackup.restore(file: backup, root: target, password: "wrong-password-2026"))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("archive.json")), before)
        let store = PhoneStore(rootURL: target, activateConnectivity: false)
        let oldSetting = UserDefaults.standard.object(forKey: "automaticTranscription")
        defer { if let oldSetting { UserDefaults.standard.set(oldSetting, forKey: "automaticTranscription") } else { UserDefaults.standard.removeObject(forKey: "automaticTranscription") } }
        try store.restoreBackup(backup, password: "test-only-password-2026")
        XCTAssertNil(store.error)
        XCTAssertEqual(store.clips.map(\.id), [clip.id])
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(clip.file)), try Data(contentsOf: target.appendingPathComponent(clip.file)))
        XCTAssertEqual(store.retrieve("电源噪声", locale: "zh-CN").first?.clipID, clip.id)
        XCTAssertEqual(PhoneStore(rootURL: target, activateConnectivity: false).clips.map(\.id), [clip.id])
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "automaticTranscription"))
    }
    func testAudioImportPersistsAndReloads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("input.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        for i in 0..<16000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 16000)) * 0.1 }
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
        let store = PhoneStore(rootURL: root, activateConnectivity: false)
        await store.importAudio(audio)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.clips.count, 1)
        let clip = try XCTUnwrap(store.clips.first)
        XCTAssertEqual(clip.duration, 1, accuracy: 0.05)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(clip.file).path))
        XCTAssertEqual(PhoneStore(rootURL: root, activateConnectivity: false).clips, store.clips)
        store.play(clip, offset: 0.2); store.stopPlayback()
        XCTAssertNil(store.error)
    }
    func testCorruptArchiveIsNeverOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let damaged = Data("corrupt archive".utf8)
        let path = root.appendingPathComponent("archive.json")
        try damaged.write(to: path)
        let store = PhoneStore(rootURL: root, activateConnectivity: false)
        await store.importAudio(root.appendingPathComponent("unused.m4a"))
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: path), damaged)
    }
    func testDeletedRecordingRejectsLateTranscriptionAndAI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let c = Clip(id: id, started: Date(), duration: 1, marks: [], file: id + ".m4a", digest: String(repeating: "a", count: 64), transcript: [WordSpan(id: "0", offset: 0, duration: 1, text: "测试计划")], status: "ready")
        try ArchiveDisk.save([c], to: root)
        let store = PhoneStore(rootURL: root, activateConnectivity: false)
        let sources = ArchiveRules.excerpts([c])
        let answer = GroundedAnswer(answer: "测试计划", sourceIDs: [sources[0].id])
        try store.saveAnswer(question: "计划？", answer: answer, sources: sources)
        store.deleteRecording(c)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.clips.isEmpty)
        XCTAssertThrowsError(try store.update(c))
        XCTAssertThrowsError(try store.saveAnswer(question: "迟到请求", answer: answer, sources: sources))
        XCTAssertThrowsError(try store.saveReview(day: c.started, answer: answer, sources: sources, totalRecordings: 1))
        XCTAssertEqual(store.conversations[0].invalidatedSourceIDs, [sources[0].id])
        XCTAssertTrue(store.conversations[0].sources.isEmpty)
        XCTAssertTrue(try Journal.load(from: root)[0].sources.isEmpty)
        XCTAssertTrue(PhoneStore(rootURL: root, activateConnectivity: false).clips.isEmpty)
    }

}
