import Foundation

extension PhoneStore {
    var currentAIService: AIService {
        AIService(endpoint: UserDefaults.standard.string(forKey: "endpoint") ?? "https://api.deepseek.com/chat/completions",
                  model: UserDefaults.standard.string(forKey: "model") ?? "deepseek-chat")
    }
    func automaticInputs() throws -> [ReviewInput] {
        guard automaticStorageHealthy else { throw AutomaticReviewError.unavailable }
        let deleted = try RetentionDisk.deletedIDs(from: root)
        return try ReviewInput.candidates(clips: clips.filter { !deleted.contains($0.id) }, now: Date(), generateMemories: automaticReviewRunner?.state.policy?.generateMemories == true, generateHighlights: automaticReviewRunner?.state.policy?.generateHighlights == true, contexts: authorizedContextSamples)
    }
    func reconcileAutomaticReviews() throws {
        guard automaticStorageHealthy, let runner = automaticReviewRunner, runner.healthy else { throw AutomaticReviewError.unavailable }
        try runner.reconcile(inputs: automaticInputs(), completed: Set(reviews.compactMap(\.automaticJobID)),
                             deleted: RetentionDisk.deletedIDs(from: root))
    }
    func approveAutomaticReviews(service: AIService, limit: Int, generateMemories: Bool = false, generateHighlights: Bool = false, tokenLimit: Int = 20000) {
        do {
            guard currentAIService == service, !KeyVault.load(endpoint: service.endpoint).isEmpty else {
                error = "请先为当前接口保存密钥；服务变更后需要重新确认。"; return
            }
            try automaticReviewRunner.approve(service: service, limit: limit, now: Date(), generateMemories: generateMemories, generateHighlights: generateHighlights, tokensPer24Hours: tokenLimit)
            automaticReviewStatus = "已授权，等待可处理的历史日期"
            Task { await resumeAutomaticReviews() }
        } catch { self.error = error.localizedDescription }
    }
    func pauseAutomaticReviews() {
        do {
            try automaticReviewRunner.pause()
            automaticReviewStatus = "自动外发已暂停；已发出的请求无法撤回"
        } catch { self.error = error.localizedDescription }
    }
    func retryAutomaticReview(_ id: UUID) {
        do { try automaticReviewRunner.retry(id); Task { await resumeAutomaticReviews() } }
        catch { self.error = error.localizedDescription }
    }
    func resumeAutomaticReviews() async {
        guard automaticStorageHealthy, let runner = automaticReviewRunner, runner.healthy else { return }
        do {
            try replayMemoryBatches()
            try replayHighlights()
            try await runner.run(service: { self.currentAIService }, inputs: { try self.automaticInputs() },
                completed: { Set(self.reviews.compactMap(\.automaticJobID)) },
                deleted: { try RetentionDisk.deletedIDs(from: self.root) },
                ready: { self.automaticStorageHealthy && !self.recording && !self.processing && !KeyVault.load(endpoint: self.currentAIService.endpoint).isEmpty },
                send: { service, sources, generateMemories, generateHighlights, contexts in
                    try await AIClient(endpoint: service.endpoint, model: service.model, auditRoot: self.root).askWithUsage(AIWire.reviewQuestion, sources: sources, generateMemories: generateMemories, generateHighlights: generateHighlights, contexts: contexts)
                }, publish: { job, reply in
                    guard self.sourcesAreCurrent(job.input.sources),
                          try self.automaticInputs().contains(where: { $0.version == job.input.version }) else { throw AutomaticReviewError.stale }
                    if self.reviews.contains(where: { $0.automaticJobID == job.id }) { return }
                    let review = SavedDailyReview(day: job.input.day, answer: reply.answer, sources: job.input.sources,
                        totalRecordings: job.input.totalRecordings, automaticJobID: job.id, inputVersion: job.input.version,
                        totalSources: job.input.totalSources, pendingRecordings: job.input.pendingRecordings, sourceTimeZone: job.input.timeZone, memoryCandidates: job.input.generateMemories == true ? reply.memoryCandidates : nil, contexts: job.input.contexts, highlightCandidates: job.input.generateHighlights == true ? reply.highlightCandidates : nil, dayVersion: job.input.dayVersion, batchIndex: job.input.batchIndex, batchCount: job.input.batchCount)
                    let updated = [review] + self.reviews
                    try Journal.saveReviews(updated, to: self.root); self.reviews = updated
                    try self.replayMemoryBatches()
                    try self.replayHighlights()
                })
            if runner.state.policy?.enabled != true { automaticReviewStatus = "尚未授权或已暂停自动外发" }
            else if runner.state.policy?.service != currentAIService { automaticReviewStatus = "服务或模型已改变，请重新确认授权" }
            else if KeyVault.load(endpoint: currentAIService.endpoint).isEmpty { automaticReviewStatus = "请为当前接口保存密钥" }
            else if runner.state.callsUsed(now: Date()) >= (runner.state.policy?.callsPer24Hours ?? 0) { automaticReviewStatus = "达到滚动 24 小时调用上限，等待额度恢复" }
            else if runner.state.jobs.contains(where: { $0.state == .uncertain }) { automaticReviewStatus = "有未确认的请求，请核对后决定是否重试" }
            else { automaticReviewStatus = "等待可处理任务；Token 预约预算不足时保持等待。返回 App 时继续检查。" }
        } catch { automaticReviewStatus = error.localizedDescription }
    }
}
