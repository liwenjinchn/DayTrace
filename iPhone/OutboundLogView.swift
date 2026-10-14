import SwiftUI

struct OutboundLogView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var items: [OutboundRequest] = []
    var body: some View {
        List {
            if items.isEmpty { QuietPlaceholder(title: "尚无 AI 外发记录", message: "实际发出的文字请求会保存在这里，方便核对。", symbol: "arrow.up.doc") }
            ForEach(items) { item in
                NavigationLink { OutboundRequestDetailView(item: item) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(item.question).lineLimit(2)
                        Text("\(item.time.journalLabel) · \(item.outcome)").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }
        }.navigationTitle("AI 外发记录").navigationBarTitleDisplayMode(.inline).task {
            do { items = try OutboundLog.load(store.root) } catch { store.error = "外发记录不可读，未覆盖原文件。" }
        }
    }
}

struct OutboundRequestDetailView: View {
    let item: OutboundRequest
    var body: some View {
        List {
            Section { Text(item.question).font(.headline).lineSpacing(5); Text(item.outcome).font(.subheadline).foregroundStyle(.secondary) }
            if item.invalidated { Section { Text("关联来源已删除，原文及上下文快照已清除；已发送内容无法撤回。").foregroundStyle(.orange) } }
            if !item.sources.isEmpty { Section("实际发送的原文") { ForEach(item.sources) { source in Text(source.text).lineSpacing(5).textSelection(.enabled).padding(.vertical, 5) } } }
            if !item.memories.isEmpty { Section("实际使用的记忆") { ForEach(item.memories) { Text($0.content).lineSpacing(5) } } }
            if !item.contexts.isEmpty { Section("已授权的上下文") { ForEach(item.contexts) { Text("\($0.label)：\($0.value)") } } }
            Section {
                DisclosureGroup("服务与请求信息") {
                    ServiceSummary(service: item.service)
                    Text(item.service.endpoint).font(.footnote).textSelection(.enabled)
                    Text(item.time.journalLabel).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("实际发送范围").navigationBarTitleDisplayMode(.inline)
    }
}
