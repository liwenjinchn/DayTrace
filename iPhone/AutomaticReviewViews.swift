import SwiftUI

struct AutomaticReviewSettingsView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var limit = 3
    @State private var tokenLimit = 20000
    @State private var generateMemories = false
    @State private var generateHighlights = false
    private struct ConsentPreview: Identifiable {
        let id = UUID()
        let service: AIService
        let limit: Int
        let tokenLimit: Int
        let generateMemories: Bool
        let generateHighlights: Bool
    }
    @State private var consentPreview: ConsentPreview?
    @State private var loaded = false
    var body: some View {
        List {
            Section {
                Label(store.automaticReviewState.policy?.enabled == true ? "自动外发已开启" : "自动外发已暂停", systemImage: store.automaticReviewState.policy?.enabled == true ? "checkmark.circle" : "pause.circle")
                Text(store.automaticReviewStatus).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle("同时提取长期记忆", isOn: $generateMemories)
                Toggle("同时提取自动重点", isOn: $generateHighlights)
            } header: { Text("复盘用途") } footer: { Text("以上用途需要独立确认；更改后请重新授权。") }
            Section {
                Stepper("24 小时最多 \(limit) 次", value: $limit, in: 1...100)
                DisclosureGroup("Token 预算 · \(tokenLimit)") {
                    Stepper("预约上限：\(tokenLimit)", value: $tokenLimit, in: 1024...1000000, step: 1000)
                    Text("已预约 \(store.automaticReviewState.tokensUsed(now: Date())) Token。按请求字节数、协议余量及输出上限保守预约；未知结果不退额，实际费用需核对服务账单。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("自动调用预算") } footer: { Text("手动请求另计；失败、超时和重试也占次数。调整后重新授权才会生效。") }
            Section {
                Button {
                    consentPreview = ConsentPreview(service: store.currentAIService, limit: limit, tokenLimit: tokenLimit, generateMemories: generateMemories, generateHighlights: generateHighlights)
                } label: { PrimaryActionLabel(title: "查看授权范围", symbol: "checkmark.shield") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                if store.automaticReviewState.policy?.enabled == true {
                    Button("暂停自动外发", role: .destructive) { store.pauseAutomaticReviews() }
                }
            }
            Section {
                NavigationLink { AutomaticReviewActivityView() } label: {
                    FeatureLabel(title: "任务与请求记录", subtitle: "任务 \(store.automaticReviewState.jobs.count) · 自动请求 \(store.automaticReviewState.requests.count)", symbol: "clock.arrow.circlepath", color: .indigo)
                }
                LabeledContent("最近 24 小时已占用", value: "\(store.automaticReviewState.callsUsed(now: Date())) 次")
            }
            Section {
                DisclosureGroup("处理方式与费用说明") {
                    Text("授权后处理已有和新同步的历史记录。按本地日期，次日上午 08:00 后 App 可运行时生成；不保证后台准点执行。每个日期按最多 8 条原文分批处理全部记录，每批独立占预算。")
                    Text("记忆、重点与复盘共用一次请求。开启新用途会重新处理历史日期；暂停保留进度。未知结果需手动决定是否重试，服务可能已收费。单价未知时不估算费用。")
                    if let policy = store.automaticReviewState.policy { Text("已确认上限：\(policy.callsPer24Hours) 次 / 24 小时。") }
                }.font(.subheadline)
            }
        }.navigationTitle("自动复盘").navigationBarTitleDisplayMode(.inline)
        .onAppear { guard !loaded else { return }; loaded = true; limit = store.automaticReviewState.policy?.callsPer24Hours ?? 3; tokenLimit = store.automaticReviewState.policy?.tokensPer24Hours ?? 20000; generateMemories = store.automaticReviewState.policy?.generateMemories == true; generateHighlights = store.automaticReviewState.policy?.generateHighlights == true }
        .sheet(item: $consentPreview) { preview in
            NavigationStack {
                List {
                    let service = preview.service
                    Group {
                        Section { ServiceSummary(service: service) } header: { Text("目的服务") } footer: { Text(service.endpoint).textSelection(.enabled) }
                        Section {
                            Text("允许发送历史和后续录音的相关原文、时间与来源 ID；每次最多 8 条，不含音频。")
                        } header: { Text("发送范围") } footer: { Text("健康和位置只有在各自独立授权开启时才发送相关数据。") }
                        Section {
                            LabeledContent("每日复盘", value: "允许")
                            LabeledContent("长期记忆", value: preview.generateMemories ? "允许" : "不允许")
                            LabeledContent("自动重点", value: preview.generateHighlights ? "允许" : "不允许")
                        } header: { Text("本次用途") } footer: { Text("关于本人或他人的记忆需核实主体；只有收藏才额外保留重点音频。") }
                        Section {
                            LabeledContent("24 小时调用上限", value: "\(preview.limit) 次")
                            LabeledContent("Token 预约上限", value: "\(preview.tokenLimit)")
                        } header: { Text("预算") } footer: { Text("未知结果可能已收费，需手动决定是否重试。可随时暂停；服务或模型改变需重新授权，已发送数据无法撤回。") }
                        Section {
                            DisclosureGroup("完整用途说明") {
                                Text(preview.generateHighlights ? "同时提取带引用的自动重点；重点本身不保留音频，收藏后才保留，共用本次请求与预算。" : "此次不提取自动重点。")
                                Text(preview.generateMemories ? "同时自动保存带来源的长期记忆，会处理已有日期；关于本人/他人的候选需核实主体。旧授权不会自动开启此用途。" : "此次不生成长期记忆。")
                            }.font(.subheadline)
                        }
                        Button {
                            consentPreview = nil
                            store.approveAutomaticReviews(service: service, limit: preview.limit, generateMemories: preview.generateMemories, generateHighlights: preview.generateHighlights, tokenLimit: preview.tokenLimit)
                        } label: { PrimaryActionLabel(title: "同意上述范围并启用", symbol: "checkmark.shield") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }.navigationTitle("自动外发授权").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { consentPreview = nil } } }
            }
        }

    }
}

struct AutomaticReviewActivityView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var tab = "任务"
    @State private var retryID: UUID?
    @State private var showingRetry = false
    var body: some View {
        List {
            Section {
                Picker("记录类型", selection: $tab) { Text("任务").tag("任务"); Text("自动请求").tag("请求") }.pickerStyle(.segmented)
            }
            if tab == "任务" {
                if store.automaticReviewState.jobs.isEmpty { QuietPlaceholder(title: "暂无任务", message: "可处理的历史日期会出现在这里。", symbol: "clock") }
                ForEach(store.automaticReviewState.jobs.reversed()) { job in
                    NavigationLink { AutomaticReviewJobView(jobID: job.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(job.input.day.dayLabel).font(.headline)
                            Text("\(job.state.label) · 批次 \((job.input.batchIndex ?? 0) + 1)/\(job.input.batchCount ?? 1)").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    if job.state == .uncertain { Button("核对后重试此任务") { retryID = job.id; showingRetry = true } }
                }
                Button("检查待处理任务") { Task { await store.resumeAutomaticReviews() } }
            } else {
                if store.automaticReviewState.requests.isEmpty { QuietPlaceholder(title: "尚无自动请求", message: "每次自动外发的实际范围会保存在这里。", symbol: "arrow.up.doc") }
                ForEach(store.automaticReviewState.requests.reversed()) { request in
                    NavigationLink { AutomaticRequestDetailView(request: request) } label: {
                        VStack(alignment: .leading, spacing: 6) { Text(request.sentAt.journalLabel); Text(request.outcome).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
            }
        }.navigationTitle("任务与请求记录").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("之前的请求可能已计费。重试将再次发送相同文字，占用一次额度，并可能再次收费。", isPresented: $showingRetry, titleVisibility: .visible) {
            Button("确认重试") { if let retryID { store.retryAutomaticReview(retryID) } }
        }
    }
}

struct AutomaticReviewJobView: View {
    @EnvironmentObject var store: PhoneStore
    let jobID: UUID
    var job: AutomaticReviewJob? { store.automaticReviewState.jobs.first { $0.id == jobID } }
    var body: some View {
        List {
            if let job {
            Section { Text(job.input.day.dayLabel).font(.headline); Text(job.state.label).foregroundStyle(.secondary) }
            Section("处理范围") {
                LabeledContent("批次", value: "\((job.input.batchIndex ?? 0) + 1) / \(job.input.batchCount ?? 1)")
                LabeledContent("原文", value: "\(job.input.sources.count) / \(job.input.totalSources) 条")
                LabeledContent("待转写", value: "\(job.input.pendingRecordings) 段")
            }
            Section("本批原文") { ForEach(job.input.sources) { source in if store.sourcesAreCurrent([source]) { SourceRow(source: source) } else { Text("该来源已失效").foregroundStyle(.secondary) } } }
            } else { QuietPlaceholder(title: "任务已不可用", message: "请返回任务列表检查当前状态。", symbol: "clock") }
        }.navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
    }
}

struct AutomaticRequestDetailView: View {
    @EnvironmentObject var store: PhoneStore
    let request: AIRequestAudit
    var body: some View {
        List {
            Section { Text(request.outcome).font(.headline); Text(request.sentAt.journalLabel).font(.subheadline).foregroundStyle(.secondary) }
            Section { ServiceSummary(service: request.service) } header: { Text("目的服务") } footer: { Text(request.service.endpoint).textSelection(.enabled) }
            Section("实际发送的原文") {
                if let job = store.automaticReviewState.jobs.first(where: { $0.id == request.jobID }) {
                    ForEach(job.input.sources.filter { request.sourceIDs.contains($0.id) }) { source in
                        VStack(alignment: .leading, spacing: 8) { Text(source.started.journalLabel).font(.caption).foregroundStyle(.secondary); Text(source.text).lineSpacing(4).textSelection(.enabled) }.padding(.vertical, 4)
                    }
                    if job.input.sources.count < request.sourceIDs.count { Text("部分已删除来源的快照已清除；此前发送的内容无法撤回。").font(.footnote) }
                }
            }
            if !(request.contexts ?? []).isEmpty { Section("已授权的上下文") { ForEach(request.contexts ?? []) { context in Text("\(context.label)：\(context.value)") } } }
            Section {
                DisclosureGroup("用途与用量") {
                    LabeledContent("长期记忆", value: request.generateMemories == true ? "开启" : "关闭")
                    LabeledContent("自动重点", value: request.generateHighlights == true ? "开启" : "关闭")
                    Text(request.totalTokens.map { "服务返回 Token：\($0)" } ?? "Token 用量未知，不能当作零")
                }
            } footer: { Text("发送文字、时间、来源 ID 及已独立授权的上下文，不含音频。") }
        }.navigationTitle("自动请求详情").navigationBarTitleDisplayMode(.inline)
    }
}
