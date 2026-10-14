import SwiftUI

struct MemoryLibraryView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var filter = "all"
    @State private var query = ""
    @State private var category = "all"
    var visible: [PersonalMemory] {
        store.memoryState.items.filter {
            (filter == "all" || $0.status.rawValue == filter) && (category == "all" || $0.category.rawValue == category) &&
            (query.isEmpty || $0.content.localizedCaseInsensitiveContains(query) || $0.topic.localizedCaseInsensitiveContains(query))
        }.sorted { $0.updated > $1.updated }
    }
    var body: some View {
        List {
            Section {
                Picker("分类", selection: $category) {
                    Text("全部").tag("all")
                    ForEach(MemoryCategory.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                Picker("状态", selection: $filter) {
                    Text("全部").tag("all")
                    ForEach(PersonalMemory.Status.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
            }
            if !store.memoriesHealthy { Text("记忆文件不可读，已停止写入和记忆外发。原文件保留。").foregroundStyle(.red) }
            if visible.isEmpty {
                ContentUnavailableView("暂无此类记忆", systemImage: "brain", description: Text("在自动复盘授权中启用记忆提取后，有依据的候选将出现在这里。"))
            }
            ForEach(visible) { memory in
                NavigationLink { MemoryDetailView(memoryID: memory.id) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(memory.content).lineLimit(3)
                        Text("\(memory.category.label) · \(memory.status.label) · \(memory.userEdited ? "用户确认/修改" : "AI 自动保存")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                DisclosureGroup("记忆来源与管理说明") {
                    Text("记忆来自原文。没有可靠的说话人身份时，关于本人或他人的候选需要核实；录音中的陈述不等于用户事实。")
                    Text("编辑、停用或删除会阻止同一原文段再次自动写入，并抑制同主题和相同内容的自动候选。此保护较保守，可能跳过同段其他候选；已有记忆仍可手动恢复。不同来源、不同措辞的重复需人工核对。")
                }.font(.subheadline)
            }
        }.navigationTitle("记忆库").navigationBarTitleDisplayMode(.inline).searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索记忆或主题")
        .onAppear { do { try store.reconcileMemories() } catch { store.error = error.localizedDescription } }
    }
}

struct MemoryDetailView: View {
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    let memoryID: UUID
    @State private var draft = ""
    @State private var loadedDraft = false
    @State private var confirmingDelete = false
    var memory: PersonalMemory? { store.memoryState.items.first { $0.id == memoryID } }
    var body: some View {
        List {
            if let memory {
                Section("记忆内容") {
                    TextEditor(text: $draft).frame(minHeight: 120)
                    if !memory.lostSourceIDs.isEmpty {
                        Text("部分来源已删除或修改。当前内容不能仅凭剩余引用视为已证实，请重新核对。").foregroundStyle(.orange)
                    }
                }
                Section("原文来源") {
                    if memory.sources.isEmpty { Text("没有有效来源，不能启用") }
                    ForEach(memory.sources) { source in
                        if store.sourcesAreCurrent([source]) { SourceRow(source: source) }
                        else { Text("来源已失效") }
                    }
                }
                Section {
                    LabeledContent("状态", value: memory.status.label)
                    LabeledContent("主体", value: memory.subject.label)
                    if memory.status == .active {
                        Button("停用这条记忆") { store.setMemoryActive(memoryID, active: false) }
                    } else {
                        Button("已核实内容、主体与来源，启用") { store.setMemoryActive(memoryID, active: true) }.disabled(memory.sources.isEmpty)
                    }
                } footer: { Text("停用后不再进入新问答；旧问答会标记记忆已变化。") }
                Section {
                    DisclosureGroup("分类与修改历史") {
                        LabeledContent("分类", value: memory.category.label)
                        LabeledContent("版本", value: "\(memory.revision)")
                        Text("生成于 \(memory.created.journalLabel)").font(.footnote).foregroundStyle(.secondary)
                        ForEach(Array(memory.history.enumerated()), id: \.offset) { _, version in
                            VStack(alignment: .leading, spacing: 8) { Text(version.changedAt.journalLabel).font(.caption).foregroundStyle(.secondary); Text(version.content).lineSpacing(4) }
                        }
                    }
                }
                Section {
                    Button("删除这条记忆", role: .destructive) { confirmingDelete = true }
                } footer: { Text("删除会移除内容与修改历史，保留不含原文的去重标记。") }
            } else { Text("这条记忆已删除") }
        }.navigationTitle("记忆详情").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { store.editMemory(memoryID, content: draft) }.disabled(memory == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 600) } }
        .onAppear { if !loadedDraft { draft = memory?.content ?? ""; loadedDraft = true } }
        .confirmationDialog("删除本条内容和修改历史，并阻止同一来源自动重建？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { store.deleteMemory(memoryID); if store.error == nil { dismiss() } }
        }
    }
}
