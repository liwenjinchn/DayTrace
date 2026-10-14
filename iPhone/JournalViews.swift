import SwiftUI

struct DailyReviewView: View {
    @EnvironmentObject var store: PhoneStore
    let day: Date
    @AppStorage("endpoint") var endpoint = "https://api.deepseek.com/chat/completions"
    @AppStorage("model") var model = "deepseek-chat"
    @State private var busy = false
    private struct ReviewPreview: Identifiable {
        let id = UUID()
        let sources: [SourceExcerpt]
        let totalRecordings: Int
        let service: AIService
        let contexts: [ContextSample]
    }
    @State private var preview: ReviewPreview?
    @State private var editing = false
    @State private var editedText = ""
    var daily: [Clip] { store.clips.filter { TimelineRules.seconds($0, day: day) > 0 } }
    var review: SavedDailyReview? { store.reviews.first { Calendar.current.isDate($0.day, inSameDayAs: day) && $0.userText != nil } ?? store.reviews.first { Calendar.current.isDate($0.day, inSameDayAs: day) } }
    var batches: [SavedDailyReview] {
        guard let version = review?.dayVersion else { return [] }
        return store.reviews.filter { $0.dayVersion == version && $0.automaticJobID != nil }.sorted { ($0.batchIndex ?? 0) < ($1.batchIndex ?? 0) }
    }
    var combinedReview: String {
        if let edited = review?.userText { return edited }
        if batches.count > 1 { return batches.map { "第 \(($0.batchIndex ?? 0) + 1) 批\n" + $0.answer.answer }.joined(separator: "\n\n") }
        return review?.answer.answer ?? ""
    }
    var body: some View {
        List {
            if let review {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(day.dayLabel).font(.subheadline).foregroundStyle(.secondary)
                        Text(combinedReview).font(.body).lineSpacing(6).textSelection(.enabled)
                    }.padding(.vertical, 8)
                    if review.userText != nil { Text("用户编辑版；引用对应原始 AI 复盘，不保证支持新增内容。").font(.footnote).foregroundStyle(.secondary) }
                    if !(review.invalidatedSourceIDs ?? []).isEmpty || !store.sourcesAreCurrent(review.sources) {
                        Label("来源已变化，请重新核对", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else if Journal.dailySources(store.clips, day: day) != review.sources {
                        Text("有未纳入的原文，可生成新版本。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("引用原文") {
                    ForEach((batches.isEmpty ? [review] : batches).flatMap { item in item.sources.filter { item.answer.sourceIDs.contains($0.id) } }) { source in
                        if store.sourcesAreCurrent([source]) { SourceRow(source: source) }
                        else { Text("该来源已失效").foregroundStyle(.secondary) }
                    }
                }
            } else {
                Section { QuietPlaceholder(title: "这一天，还没有复盘", message: "原文准备好后，可以生成带来源的回顾。", symbol: "sun.max") }
            }
            Section {
                Button {
                    let sources = Array(Journal.dailySources(store.clips, day: day).prefix(8))
                    preview = ReviewPreview(sources: sources, totalRecordings: daily.count,
                        service: AIService(endpoint: endpoint, model: model), contexts: store.contextForSources(sources))
                } label: {
                    if busy { ProgressView() } else { PrimaryActionLabel(title: review == nil ? "生成复盘" : "生成新版本", symbol: "sparkles") }
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(busy || Journal.dailySources(store.clips, day: day).isEmpty)
            } footer: { Text("发送前会预览原文；手动生成最多取前 8 条。") }
            Section {
                DisclosureGroup("记录覆盖与生成详情") {
                    LabeledContent("录音片段", value: "\(daily.count) 段")
                    LabeledContent("已转写", value: "\(daily.filter { $0.status == "ready" }.count) 段")
                    LabeledContent("录音时长", value: DisplayDuration.text(daily.reduce(0) { $0 + TimelineRules.seconds($1, day: day) }))
                    if let review {
                        Text("生成于 \(review.created.journalLabel)")
                        Text("使用 \(review.sources.count) 条原文 · 当时共 \(review.totalRecordings) 段录音")
                        if let total = review.totalSources {
                            Text("完成批次 \(batches.count)/\(review.batchCount ?? 1) · 原文覆盖 \(Set(batches.flatMap { $0.sources.map(\.id) }).count)/\(total) · 待转写 \(review.pendingRecordings ?? 0) 段")
                        }
                    }
                    Text("自动任务按每批最多 8 条处理全部原文，预算不足时保留进度。手动提前复盘仅取前 8 条；未完成部分不代表没有发生。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                NavigationLink("历史版本") {
                    List(store.reviews.filter { Calendar.current.isDate($0.day, inSameDayAs: day) }) { item in
                        NavigationLink { ReviewVersionDetailView(item: item) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.created.journalLabel).font(.subheadline).foregroundStyle(.secondary)
                                Text(item.userText ?? item.answer.answer).lineLimit(3)
                                if !(item.invalidatedSourceIDs ?? []).isEmpty || !store.sourcesAreCurrent(item.sources) { Text("来源已失效").font(.footnote).foregroundStyle(.orange) }
                            }.padding(.vertical, 4)
                        }
                    }.navigationTitle("复盘历史").navigationBarTitleDisplayMode(.inline)
                }
                NavigationLink { MemoryLibraryView() } label: { Label("关联记忆", systemImage: "brain") }
            }
        }.navigationTitle("每日复盘").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if review != nil {
                ToolbarItem(placement: .topBarTrailing) { Button { editedText = combinedReview; editing = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("编辑复盘") }
                ToolbarItem(placement: .topBarTrailing) { NavigationLink { SharePreviewView(title: "分享复盘", original: combinedReview, contexts: review?.contexts ?? []) } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("预览并分享复盘") }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form { TextEditor(text: $editedText).frame(minHeight: 300); Text("原始 AI 版本保留，后续生成不会覆盖本次编辑。") }
                    .navigationTitle("编辑复盘").navigationBarTitleDisplayMode(.inline).toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("保存") {
                            do { if let review { try store.editReview(review.id, text: editedText) }; editing = false }
                            catch { store.error = error.localizedDescription }
                        } }
                    }
            }
        }
        .sheet(item: $preview) { snapshot in
            NavigationStack {
                List {
                    Section { ServiceSummary(service: snapshot.service) } header: { Text("目的服务") } footer: { Text(snapshot.service.endpoint).textSelection(.enabled) }
                    Section("实际发送的原文") { ForEach(snapshot.sources) { source in Text(source.text).lineSpacing(4).padding(.vertical, 4) } }
                    if !snapshot.contexts.isEmpty { Section("已独立授权的上下文") { ForEach(snapshot.contexts) { sample in Text("\(sample.label)：\(sample.value)") } } }
                    Section {} footer: { Text("只发送上述文字、时间与来源，不含音频。") }
                    Button {
                        preview = nil
                        let sent = snapshot.sources; let total = snapshot.totalRecordings; let sentContexts = snapshot.contexts
                        Task {
                            busy = true; store.manualInFlight += 1; defer { busy = false; store.manualInFlight -= 1 }
                            do {
                                guard !sent.isEmpty, store.sourcesAreCurrent(sent), snapshot.service == store.currentAIService, sentContexts == store.contextForSources(sent) else { throw ArchiveFailure.invalidSources }
                                let result = try await AIClient(endpoint: snapshot.service.endpoint, model: snapshot.service.model, auditRoot: store.root).ask("请用中文根据这些原文生成今日复盘：发生的事情、明确的计划和需要核对的信息。不要推断情绪，不把他人说的话当成我的事实；只总结提供的记录，附来源。", sources: sent, contexts: sentContexts)
                                guard sentContexts == store.contextForSources(sent) else { throw AutomaticReviewError.stale }
                                try store.saveReview(day: day, answer: result, sources: sent, totalRecordings: total, contexts: sentContexts)
                            } catch { store.error = error.localizedDescription }
                        }
                    } label: { PrimaryActionLabel(title: "发送并生成复盘", symbol: "sparkles") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(snapshot.sources.isEmpty)
                }.navigationTitle("发送预览").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { preview = nil } } }
            }
        }
    }
}

struct ConversationHistoryView: View {
    @EnvironmentObject var store: PhoneStore
    var body: some View {
        List {
            if store.conversations.isEmpty { ContentUnavailableView("还没有对话", systemImage: "bubble.left.and.bubble.right") }
            ForEach(store.conversations) { conversation in
                NavigationLink {
                    List {
                        Section("问题") { Text(conversation.question).textSelection(.enabled) }
                        Section("回答") {
                            Text(conversation.answer.answer).lineSpacing(6).textSelection(.enabled).padding(.vertical, 6)
                            if !(conversation.invalidatedSourceIDs ?? []).isEmpty || !(conversation.invalidatedMemoryIDs ?? []).isEmpty || !store.sourcesAreCurrent(conversation.sources) || !store.memoryContextsAreCurrent(conversation.memories ?? [], sources: conversation.sources) {
                                Label("来源或记忆已变化，历史回答需重新核对", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                        if !(conversation.contexts ?? []).isEmpty { Section("当时发送的上下文") { ForEach(conversation.contexts ?? []) { sample in Text("\(sample.label)：\(sample.value)") } } }
                        if !(conversation.memories ?? []).isEmpty { Section("当时使用的记忆") { ForEach(conversation.memories ?? []) { memory in Text(memory.content) } } }
                        Section("引用原文") {
                            ForEach(conversation.sources) { source in
                                if store.sourcesAreCurrent([source]) { SourceRow(source: source) }
                                else { Text("该来源已失效").foregroundStyle(.secondary) }
                            }
                        }
                    }.navigationTitle("历史对话").navigationBarTitleDisplayMode(.inline)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(conversation.question).lineLimit(2)
                        Text(conversation.created.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN")))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("会话历史").navigationBarTitleDisplayMode(.inline)
    }
}

struct StorageView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var confirming = false
    @AppStorage("automaticRetention") private var automaticRetention = false
    @State private var storageText = "正在统计占用"
    var body: some View {
        List {
            Section {
                Text(storageText).font(.headline).padding(.vertical, 8)
                LabeledContent("已到期音频", value: "\(store.clips.filter { $0.audioExpiredAt != nil }.count) 段")
                LabeledContent("已提取片段", value: "\(store.audioVault.slices.count) 个")
            }
            Section {
                Toggle("到期自动清理", isOn: $automaticRetention)
                NavigationLink("音频保留范围") { AudioRetentionSettingsView() }
            } footer: { Text("普通原音保留 30 天，到期后保留原文。Mark、收藏和长期保留另行保护。") }
            Section("本次可清理 · \(store.cleanupCandidates().count) 段") {
                ForEach(store.cleanupCandidates()) { clip in
                    VStack(alignment: .leading, spacing: 6) { Text(clip.started.journalLabel); Text("\(Int(clip.duration)) 秒 · 原文保留").font(.subheadline).foregroundStyle(.secondary) }
                }
                Button("清理已到期的普通音频", role: .destructive) { confirming = true }
                    .disabled(store.cleanupCandidates().isEmpty || store.processing || store.recording || store.preparingAudio)
            }
            Section {
                DisclosureGroup("留存规则与提取状态") {
                    Text("自动清理在 App 可运行且提取完成时检查；失败、缺段、未完成转写和播放中的音频继续保护，不保证后台准点执行。")
                    Text("Mark 和收藏范围在本地提取为片段。会话未收齐或旧录音缺少会话信息时，原文件继续保留。长期保留不等于备份，记录排除系统备份，可主动导出加密备份。")
                    Button("提取或重试保留音频") { Task { await store.prepareRetainedAudio() } }.disabled(store.preparingAudio)
                    Text(store.preservationStatus).font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("查看重点与收藏") { HighlightsView() }
                }.font(.subheadline)
            }
        }.navigationTitle("存储与留存").navigationBarTitleDisplayMode(.inline)
        .task {
            let root = store.root
            let sizes = await Task.detached(priority: .utility) { () -> (Int64, Int64) in
                var all: Int64 = 0, retained: Int64 = 0
                for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                    let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    all += size; if file.lastPathComponent.hasPrefix("retained-") { retained += size }
                }
                return (all, retained)
            }.value
            storageText = "本地总占用 \(ByteCountFormatter.string(fromByteCount: sizes.0, countStyle: .file)) · 保留片段 \(ByteCountFormatter.string(fromByteCount: sizes.1, countStyle: .file))"
        }
        .confirmationDialog("清理整段原音后，仅已成功提取的保留片段可回听；原文和文字引用保留。", isPresented: $confirming, titleVisibility: .visible) {
            Button("确认清理", role: .destructive) { store.cleanupAudio() }
        }
    }
}

struct ReviewVersionDetailView: View {
    @EnvironmentObject var store: PhoneStore
    let item: SavedDailyReview
    var body: some View {
        List {
            Section { Text(item.created.journalLabel).font(.subheadline).foregroundStyle(.secondary); Text(item.userText ?? item.answer.answer).lineSpacing(6).textSelection(.enabled).padding(.vertical, 6) }
            if !(item.invalidatedSourceIDs ?? []).isEmpty || !store.sourcesAreCurrent(item.sources) { Section { Label("来源已变化，请重新核对", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
            Section("引用原文") { ForEach(item.sources.filter { item.answer.sourceIDs.contains($0.id) }) { source in if store.sourcesAreCurrent([source]) { SourceRow(source: source) } else { Text("该来源已失效").foregroundStyle(.secondary) } } }
            if item.userText != nil { Section {} footer: { Text("用户编辑版；引用对应原始 AI 复盘，不保证支持新增内容。") } }
        }.navigationTitle("复盘版本").navigationBarTitleDisplayMode(.inline)
    }
}
