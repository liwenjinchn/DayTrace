import SwiftUI

struct SearchView: View {
    @EnvironmentObject var store: PhoneStore
    @AppStorage("locale") private var locale = "zh-CN"
    @State private var query = ""
    @State private var semantic = false
    @State private var results: [SourceExcerpt] = []
    @State private var dateFilter = false
    @State private var since = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var until = Date()
    @State private var submitted = false
    @State private var filtering = false
    private var visibleResults: [SourceExcerpt] { results.filter { store.sourcesAreCurrent([$0]) } }
    private var invalidDateRange: Bool { dateFilter && Calendar.current.startOfDay(for: since) > Calendar.current.startOfDay(for: until) }
    private var queryIsEmpty: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func refreshResults() {
        guard !invalidDateRange else { results = []; return }
        submitted = !queryIsEmpty
        results = store.search(query, semantic: semantic, locale: locale,
            since: dateFilter ? Calendar.current.startOfDay(for: since) : .distantPast,
            until: dateFilter ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: until))! : .distantFuture)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("检索方式", selection: $semantic) { Text("关键词").tag(false); Text("语义相近").tag(true) }
                        .pickerStyle(.segmented).listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                if dateFilter {
                    Section {
                        HStack(alignment: .top) {
                            Label("已限定日期", systemImage: "calendar").font(.subheadline)
                            Spacer()
                            Text("\(since.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN")))) – \(until.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if invalidDateRange {
                    Section { Label("开始日期不能晚于结束日期", systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                } else if visibleResults.isEmpty {
                    Section {
                        QuietPlaceholder(title: submitted ? "没有找到相关原文" : "找回记忆里的细节",
                            message: submitted ? "试试更短的关键词，或调整日期范围。" : "搜索人名、地点或一句话。\n结果会带你回到原文和录音。", symbol: "magnifyingglass")
                    }
                    if queryIsEmpty {
                        Section("搜索提示") {
                            FeatureLabel(title: "记得原话", subtitle: "用关键词查找准确出现过的内容", symbol: "text.quote", color: .blue)
                            FeatureLabel(title: "只记得大意", subtitle: "切换语义相近，找到可能相关的片段", symbol: "sparkle.magnifyingglass", color: .purple)
                        }
                    }
                } else {
                    Section("相关原文 · \(visibleResults.count) 条") {
                        ForEach(visibleResults) { source in SourceRow(source: source) }
                    }
                }
                Section {} footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("仅搜索本机原文", systemImage: "lock.shield")
                        if semantic { Text("语义相近不等于包含答案，请核对原话。") }
                        Text(store.searchStatus)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("搜索")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "人名、地点、关键词")
            .onSubmit(of: .search) { refreshResults() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { filtering = true } label: {
                        Image(systemName: dateFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    }.accessibilityLabel("筛选日期")
                }
            }
            .sheet(isPresented: $filtering) {
                NavigationStack {
                    Form {
                        Toggle("限定日期", isOn: $dateFilter)
                        if dateFilter {
                            DatePicker("开始", selection: $since, displayedComponents: .date)
                            DatePicker("结束", selection: $until, displayedComponents: .date)
                            if invalidDateRange { Text("开始日期不能晚于结束日期").foregroundStyle(.red) }
                        }
                    }.navigationTitle("日期范围").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { filtering = false } } }
                }.presentationDetents([.medium, .large])
            }
            .onChange(of: query) { _, _ in results = []; submitted = false }
            .onChange(of: semantic) { _, _ in refreshResults() }
            .onChange(of: dateFilter) { _, _ in refreshResults() }
            .onChange(of: since) { _, _ in refreshResults() }
            .onChange(of: until) { _, _ in refreshResults() }
            .onChange(of: locale) { _, _ in refreshResults() }
        }
    }
}
