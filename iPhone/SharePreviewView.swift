import SwiftUI
struct SharePreviewView: View {
    let title: String
    let original: String
    var contexts: [ContextSample] = []
    @State private var draft: String
    @State private var hiddenTerms = ""
    @State private var includeHealth = false
    @State private var includeLocation = false
    init(title: String, original: String, contexts: [ContextSample] = []) {
        self.title = title; self.original = original; self.contexts = contexts
        _draft = State(initialValue: original)
    }
    var preview: String {
        var result = draft
        let selected = contexts.filter { $0.category == .health ? includeHealth : includeLocation }
        if !selected.isEmpty { result += "\n\n" + selected.map { "\($0.label)：\($0.value)" }.joined(separator: "\n") }
        for term in hiddenTerms.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" }).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !term.isEmpty {
            result = result.replacingOccurrences(of: term, with: "[已隐藏]")
        }
        return result
    }
    var body: some View {
        Form {
            Section("最终内容") { Text(preview.isEmpty ? "内容为空" : preview).lineSpacing(5).textSelection(.enabled).padding(.vertical, 8) }
            Section {
                ShareLink(item: preview) { PrimaryActionLabel(title: "分享以上内容", symbol: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: { Text("请先核对预览，再选择分享位置。") }
            Section {
                DisclosureGroup("编辑与排除内容") {
                    TextEditor(text: $draft).frame(minHeight: 180).accessibilityLabel("分享文字")
                    TextField("隐藏词语，用逗号分隔", text: $hiddenTerms, axis: .vertical)
                    Toggle("附带健康上下文", isOn: $includeHealth)
                    Toggle("附带位置上下文", isOn: $includeLocation)
                    Text("开关只控制附加数据。正文中的人物、身体或位置信息需手动删除或指定隐藏词语，不保证识别全部敏感内容。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}
