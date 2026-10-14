import SwiftUI
import UniformTypeIdentifiers

@main struct DayTraceApp: App {
    @StateObject private var store = PhoneStore()
    var body: some Scene { WindowGroup { RootView().environmentObject(store) } }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var store: PhoneStore
    var body: some View {
        TabView {
            DaysView().tabItem { Label("日记", systemImage: "book.closed") }
            ChatView().tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
            SearchView().tabItem { Label("搜索", systemImage: "magnifyingglass") }
            SettingsView().tabItem { Label("设置", systemImage: "gearshape") }
        }.environment(\.locale, Locale(identifier: "zh_CN")).tint(.blue)
        .task { await store.resumeAutomaticTranscription() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.resumeAutomaticTranscription() } } }
        .alert("DayTrace", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("好") { store.error = nil } } message: { Text(store.error ?? "") }
    }
}

struct ClipView: View {
    @EnvironmentObject var store: PhoneStore
    let clipID: String
    @State private var deleting = false
    @State private var markIndex: Int?
    @State private var confirmingMark = false
    @State private var editingWord: WordSpan?
    var offset: Double = 0
    var clip: Clip? { store.clips.first { $0.id == clipID } }
    @ViewBuilder private func retainedAudio(_ clip: Clip) -> some View {
        let slices = store.audioVault.slices.filter { $0.clipID == clip.id }
        if !slices.isEmpty {
            Section("已提取的保留音频") {
                ForEach(slices) { slice in
                    Button(String(format: "回听 %.1f–%.1f 秒", slice.start, slice.end)) { store.playSlice(slice) }
                }
            }
        }
    }
    var body: some View {
        if let clip {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(clip.started.formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN")))).font(.headline)
                        Label(DisplayDuration.text(clip.duration), systemImage: "waveform").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                    if clip.audioExpiredAt != nil { Label("整段原音已到期，可回听下方已保留片段", systemImage: "clock").foregroundStyle(.secondary) }
                    HStack(spacing: 16) {
                        Button { store.play(clip, offset: offset) } label: { Label("回听原音", systemImage: "play.fill").font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(clip.audioExpiredAt != nil)
                        Button { store.stopPlayback() } label: { Image(systemName: "stop.fill").frame(minWidth: 44, minHeight: 44) }
                            .buttonStyle(.bordered).accessibilityLabel("停止播放")
                    }.padding(.vertical, 4)
                    PlaybackControls(clip: clip)
                }
                if clip.audioExpiredAt != nil { retainedAudio(clip) }
                Section {
                    if clip.transcript.isEmpty { Text(clip.failure ?? clip.statusLabel).foregroundStyle(.secondary) }
                    ForEach(clip.transcript) { word in
                        HStack(alignment: .top, spacing: 12) {
                            Button { store.play(clip, offset: word.offset) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(String(format: "%02d:%02d", Int(word.offset)/60, Int(word.offset)%60)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(word.text).lineSpacing(5).foregroundStyle(store.playingID == clip.id && store.playbackPosition >= word.offset && store.playbackPosition < word.offset + word.duration ? Color.blue : Color.primary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.borderless)
                            Menu {
                                Button("纠错") { editingWord = word }
                            } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                                .buttonStyle(.borderless).accessibilityLabel("原文操作，\(Int(word.offset)) 秒")
                        }.padding(.vertical, 4).swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("纠错") { editingWord = word }.tint(.blue)
                        }
                    }
                 } header: { Text("原文") } footer: { Text("姓名、数字和英文术语请结合原音核对；纠错会使相关旧 AI 引用失效。") }
                if clip.audioExpiredAt == nil { retainedAudio(clip) }
                Section {
                    DisclosureGroup("关联上下文") { ContextRows(sources: ArchiveRules.excerpts([clip])) }
                }
                Section("音频保护") {
                    if clip.audioExpiredAt == nil, !AudioVault.ranges(clip, archive: store.clips, state: store.audioVault).isEmpty, clip.audioPinned != true { Text("Mark 上下文受保护；提取成功后才可清理整段原音") }
                    if clip.audioExpiredAt == nil || clip.audioPinned == true {
                        Button(clip.audioPinned == true ? "取消长期保留" : "长期保留整段音频") { store.pinAudio(clip) }
                        if AudioVault.ranges(clip, archive: store.clips, state: store.audioVault).isEmpty { Text("到期：\(RetentionRules.expires(clip).formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN"))))").font(.caption) }
                    }
                    Button("删除这条记录及音频", role: .destructive) { deleting = true }
                }
                if !clip.marks.isEmpty { Section("手动标记") { ForEach(clip.marks.indices, id: \.self) { i in
                    Button { store.play(clip, offset: clip.marks[i]) } label: { Label(String(format: "%.1fs", clip.marks[i]), systemImage: "bookmark.fill") }
                    Button((store.audioVault.disabledMarks ?? []).contains("\(clip.id):mark:\(i)") ? "恢复该 Mark 的音频保留" : "取消该 Mark 的音频保留") { markIndex = i; confirmingMark = true }
                } } }
                if !clip.marks.isEmpty {
                    Section("Mark 前后文 · 已同步片段") {
                        Text("范围可在“存储与留存”中调整。点选片段可查看原文和已保留音频。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(store.clips.sorted { $0.started < $1.started }) { neighbor in
                            let ranges = AudioVault.ranges(neighbor, archive: [clip], state: store.audioVault)
                            if !ranges.isEmpty {
                                NavigationLink {
                                    ClipView(clipID: neighbor.id, offset: ranges[0].lowerBound)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(neighbor.started.formatted(.dateTime.hour().minute().second()))
                                        Text(ranges.map { String(format: "%.1f–%.1f 秒", $0.lowerBound, $0.upperBound) }.joined(separator: "、"))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if neighbor.audioExpiredAt != nil { Text("音频此前已到期，仅剩原文").font(.caption) }
                                    }
                                }
                            }
                        }
                    }
                }
            }.listStyle(.insetGrouped).sheet(item: $editingWord) { word in
                TranscriptWordEditor(clipID: clipID, word: word)
            }.confirmationDialog("切换此 Mark 的音频保留。取消后恢复原到期时间；超过30天且无其他引用的音频可被清理，已清理声音无法恢复。", isPresented: $confirmingMark, titleVisibility: .visible) {
                Button("确认切换") { if let markIndex { store.toggleMarkRetention(clipID: clip.id, index: markIndex) } }
            }.navigationTitle("原文与回听").navigationBarTitleDisplayMode(.inline).onDisappear { store.stopPlayback() }
            .confirmationDialog("删除原文和音频，相关复盘和历史回答将标记为来源失效。此操作不可恢复。", isPresented: $deleting, titleVisibility: .visible) {
                Button("确认删除", role: .destructive) { store.deleteRecording(clip) }
            }
        } else { ContentUnavailableView("记录已删除", systemImage: "trash") }
    }
}

struct SourceRow: View {
    let source: SourceExcerpt
    var body: some View {
        NavigationLink { ClipView(clipID: source.clipID, offset: source.offset) } label: {
            VStack(alignment: .leading, spacing: 8) { Text(source.started.addingTimeInterval(source.offset).journalLabel).font(.caption).foregroundStyle(.secondary); Text(source.text).lineLimit(3) }.padding(.vertical, 4)
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var store: PhoneStore
    @AppStorage("locale") var locale = "zh-CN"
    @AppStorage("endpoint") var endpoint = "https://api.deepseek.com/chat/completions"
    @AppStorage("model") var model = "deepseek-chat"
    @FocusState private var questionFocused: Bool
    @State var question = ""
    @State var sources: [SourceExcerpt] = []
    @State var answer: GroundedAnswer?
    @State var busy = false
    @State var approving = false
    @State var choosing = false
    @State var answerMemories: [MemoryContext] = []
    @State var requestTask: Task<Void, Never>?
    @State var since = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
    @State var until = Date()
    @State var dateFilter = false
    var body: some View {
        NavigationStack {
            List {
                if sources.isEmpty && answer == nil {
                    Section {
                        QuietPlaceholder(title: "让原文帮你想起来", message: "关于一天里的事情，问一个问题。\n先在本机找来源，再由你决定是否发送。", symbol: "bubble.left.and.bubble.right")
                    }
                }
                Section {
                    TextField("想找回什么？", text: $question, axis: .vertical)
                        .font(.body).lineLimit(3...6).disabled(busy).focused($questionFocused)
                        .padding(.vertical, 8)
                    Button { sources = Array(store.retrieve(question, locale: locale, since: dateFilter ? Calendar.current.startOfDay(for: since) : .distantPast, until: dateFilter ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: until))! : .distantFuture).prefix(8)); answer = nil } label: {
                        Label("查找相关记录", systemImage: "doc.text.magnifyingglass").font(.headline)
                            .foregroundStyle(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy ? Color.secondary : Color.white)
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    Button { choosing = true } label: { Label("手动选择原文", systemImage: "checklist") }.disabled(busy)
                } header: { Text("你的问题") } footer: { Text("查找记录只在本机进行，不会发送 AI 请求。") }
                if busy { Section { Button("取消请求") { requestTask?.cancel() } } }
                Section {
                    DisclosureGroup {
                        Toggle("限定查询日期", isOn: $dateFilter)
                        if dateFilter { DatePicker("开始", selection: $since, displayedComponents: .date); DatePicker("结束", selection: $until, displayedComponents: .date) }
                    } label: { FeatureLabel(title: "查询范围", subtitle: "", symbol: "calendar", color: .blue) }
                }
                if let answer { Section("回答") { Text(answer.answer).textSelection(.enabled); if !store.memoryContextsAreCurrent(answerMemories, sources: sources) { Text("本次记忆上下文已变化，回答需重新核对").foregroundStyle(.orange) }; ForEach(sources.filter { answer.sourceIDs.contains($0.id) }) { SourceRow(source: $0) } } }
                if !sources.isEmpty {
                    let contexts = store.contextForSources(sources)
                    if !contexts.isEmpty { Section("将发送的上下文") { ForEach(contexts) { sample in Text("\(sample.label)：\(sample.value)") } } }
                    Section("已选原文") { ForEach(sources.filter { store.sourcesAreCurrent([$0]) }) { source in SourceRow(source: source) }
                        .onDelete { offsets in
                            if !busy {
                                let visible = sources.filter { store.sourcesAreCurrent([$0]) }
                                let removed = Set(offsets.map { visible[$0].id })
                                sources.removeAll { removed.contains($0.id) }; answer = nil
                            }
                        }
                        ForEach(store.memoryContexts(for: sources)) { memory in
                            VStack(alignment: .leading) { Text("将使用的生效记忆").font(.caption); Text(memory.content) }
                        }
                        Button { approving = true } label: { if busy { ProgressView() } else { Label("向 AI 提问", systemImage: "arrow.up.circle.fill").font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity) } }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(busy || question.isEmpty)
                    }
                }
                Section {
                    NavigationLink { MemoryLibraryView() } label: {
                        FeatureLabel(title: "记忆库", subtitle: "查看、编辑与停用你的记忆", symbol: "brain", color: .purple)
                    }
                }
            }.navigationTitle("对话")
            .listStyle(.insetGrouped).scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成输入") { questionFocused = false } }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { ConversationHistoryView() } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("会话历史，\(store.conversations.count) 条")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { question = ""; sources = []; answer = nil } label: { Image(systemName: "square.and.pencil") }
                        .disabled(busy).accessibilityLabel("新对话")
                }
            }
            .sheet(isPresented: $choosing) {
                NavigationStack {
                    List(ArchiveRules.excerpts(store.clips)) { source in
                        Button {
                            if sources.contains(where: { $0.id == source.id }) { sources.removeAll { $0.id == source.id } }
                            else if sources.count < 8 { sources.append(source) }
                        } label: { HStack(alignment: .top, spacing: 12) { Image(systemName: sources.contains(where: { $0.id == source.id }) ? "checkmark.circle.fill" : "circle"); VStack(alignment: .leading, spacing: 8) { Text(source.started.journalLabel).font(.caption).foregroundStyle(.secondary); Text(source.text).lineLimit(3).foregroundStyle(.primary) } }.padding(.vertical, 6) }.buttonStyle(.plain)
                    }.navigationTitle("选择原文（\(sources.count)/8）").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { choosing = false } } }
                }
            }
            .confirmationDialog("将 \(sources.count) 条原文、\(store.memoryContexts(for: sources).count) 条生效记忆和问题发送至 \(URL(string: endpoint)?.host ?? endpoint)？", isPresented: $approving, titleVisibility: .visible) {
                Button("发送文字到 AI 服务") { requestTask = Task {
                    busy = true; store.manualInFlight += 1; defer { busy = false; store.manualInFlight -= 1 }
                    do {
                        let sentQuestion = question; let sentSources = sources
                        let sentMemories = store.memoryContexts(for: sentSources)
                        let sentContexts = store.contextForSources(sentSources)
                        guard store.contextHealthy else { throw ArchiveFailure.invalidSources }
                        guard store.sourcesAreCurrent(sentSources) else { throw ArchiveFailure.invalidSources }
                        let result = try await AIClient(endpoint: endpoint, model: model, auditRoot: store.root).ask(sentQuestion, sources: sentSources, memories: sentMemories, contexts: sentContexts)
                        try Task.checkCancellation()
                        guard sentContexts == store.contextForSources(sentSources) else { throw AutomaticReviewError.stale }
                        try store.saveAnswer(question: sentQuestion, answer: result, sources: sentSources, memories: sentMemories, contexts: sentContexts)
                        answerMemories = sentMemories; answer = result
                    } catch { store.error = error.localizedDescription }
                } }
            }
        }
    }
}

struct TranscriptWordEditor: View {
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) var dismiss
    let clipID: String
    let word: WordSpan
    @State private var draft: String
    @State private var failure: String?
    init(clipID: String, word: WordSpan) {
        self.clipID = clipID; self.word = word
        _draft = State(initialValue: word.text)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("修正文字") { TextEditor(text: $draft).frame(minHeight: 120) }
                Section("最初识别") { Text(word.originalText ?? word.text) }
                Text("只修改这处文字，保留原音和时间位置。相关旧回答需重新核对，来源已变化的记忆不会继续用于 AI。")
                if let failure { Text(failure).foregroundStyle(.red) }
            }.navigationTitle("转写纠错").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    do { try store.correctTranscript(clipID: clipID, expected: word, text: draft); dismiss() }
                    catch { failure = "保存未完成，请返回检查当前原文后重试。" }
                }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 2000) }
            }
        }
    }
}
