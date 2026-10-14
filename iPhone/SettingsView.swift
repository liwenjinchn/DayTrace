import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: PhoneStore
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "waveform")
                            .font(.title.weight(.medium)).foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 15))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("DayTrace").font(.title2.bold())
                            Text("录音与原文保存在本机")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
                Section("录音与理解") {
                    NavigationLink { TranscriptionSettingsView() } label: {
                        FeatureLabel(title: "本地转写", subtitle: "语言、自动处理与待办", symbol: "text.bubble.fill", color: .blue)
                    }
                    NavigationLink { AIServiceSettingsView() } label: {
                        FeatureLabel(title: "AI 服务", subtitle: "接口、模型与安全保存的密钥", symbol: "sparkles", color: .purple)
                    }
                    NavigationLink { AutomaticReviewSettingsView() } label: {
                        FeatureLabel(title: "自动复盘", subtitle: "授权范围与使用预算", symbol: "sun.max.fill", color: .orange)
                    }
                }
                Section("数据与隐私") {
                    NavigationLink { StorageView() } label: { FeatureLabel(title: "存储与留存", subtitle: "音频到期与保留范围", symbol: "internaldrive.fill", color: .gray) }
                    NavigationLink { ContextSettingsView() } label: { FeatureLabel(title: "健康与位置", subtitle: "分别控制展示和发送授权", symbol: "heart.fill", color: .pink) }
                    NavigationLink { BackupView() } label: { FeatureLabel(title: "加密备份", subtitle: "导出与恢复本地记录", symbol: "lock.fill", color: .green) }
                    NavigationLink { OutboundLogView() } label: { FeatureLabel(title: "AI 外发记录", subtitle: "查看实际发送的请求", symbol: "arrow.up.doc.fill", color: .indigo) }
                }
                Section("设备") {
                    Label(store.connection, systemImage: "applewatch")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }.navigationTitle("设置")
                .onAppear { store.refreshConnection() }
        }
    }
}

struct AIServiceSettingsView: View {
    @EnvironmentObject var store: PhoneStore
    @AppStorage("endpoint") private var endpoint = "https://api.deepseek.com/chat/completions"
    @AppStorage("model") private var model = "deepseek-chat"
    @State private var key = ""
    @State private var saved = false
    @State private var testing = false
    @State private var testStatus = ""
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("接口地址").font(.subheadline).foregroundStyle(.secondary)
                    TextField("完整 HTTPS 接口", text: $endpoint).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }.padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text("模型").font(.subheadline).foregroundStyle(.secondary)
                    TextField("模型名称", text: $model).keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }.padding(.vertical, 4)
            } header: { Text("服务配置") } footer: { Text("更换接口或模型后，自动复盘需要重新授权。") }
            Section {
                SecureField("API 密钥", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    do { try KeyVault.save(key, endpoint: endpoint); saved = true }
                    catch { store.error = error.localizedDescription }
                } label: { PrimaryActionLabel(title: saved ? "已保存" : "保存密钥", symbol: "key.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text("安全凭据") } footer: { Text("密钥只供保存时的接口使用；接口改变后请重新保存。") }
            Section {
                Button(testing ? "正在测试连接…" : "测试连接") { Task {
                    testing = true; testStatus = "正在发送合成文字，请等待本次结果。"; store.manualInFlight += 1
                    defer { testing = false; store.manualInFlight -= 1 }
                    do {
                        let source = SourceExcerpt(id: "connection-test", clipID: UUID().uuidString, offset: 0, text: "这是一条合成连接测试，不含个人记录。", started: Date())
                        _ = try await AIClient(endpoint: endpoint, model: model, auditRoot: store.root).ask("确认连接并引用此测试来源", sources: [source])
                        testStatus = "实际请求、结构化响应和引用验证通过"
                    } catch { testStatus = "连接测试失败：\(error.localizedDescription)" }
                } }.disabled(testing || key.isEmpty)
                if !testStatus.isEmpty { Text(testStatus).font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text("测试会发送一段合成文字，服务可能计费。") }
            Section {
                Button(role: .destructive) {
                    do { try KeyVault.save(""); key = ""; saved = false }
                    catch { store.error = error.localizedDescription }
                } label: { Label("删除密钥", systemImage: "trash") }
            }
        }.navigationTitle("AI 服务").navigationBarTitleDisplayMode(.inline)
            .onChange(of: endpoint) { _, _ in saved = false; store.pauseAutomaticReviews() }
            .onChange(of: key) { _, _ in saved = false }
            .onChange(of: model) { _, _ in store.pauseAutomaticReviews() }
            .onAppear { key = KeyVault.load() }
    }
}

struct TranscriptionSettingsView: View {
    @EnvironmentObject var store: PhoneStore
    @AppStorage("locale") private var locale = "zh-CN"
    @AppStorage("automaticTranscription") private var automaticTranscription = false
    var body: some View {
        Form {
            Section {
                Picker("语言", selection: $locale) { Text("中文").tag("zh-CN"); Text("English").tag("en-US") }
                Toggle("自动本地转写", isOn: $automaticTranscription)
                    .onChange(of: automaticTranscription) { _, enabled in
                        if enabled { Task { await store.transcribePending(locale: locale, retryFailures: false) } }
                    }
            } footer: { Text("音频只在本机识别。开启后，收到音频或返回 App 时处理；关闭后当前片段完成即暂停。") }
            Section("处理状态") {
                LabeledContent("等待", value: "\(store.transcriptionJobs.filter { $0.state == .pending }.count) 段")
                LabeledContent("处理中", value: "\(store.transcriptionJobs.filter { $0.state == .running }.count) 段")
                LabeledContent("失败", value: "\(store.transcriptionJobs.filter { $0.state == .failed }.count) 段")
                Button("重试未完成转写") { Task { await store.transcribePending(locale: locale) } }
                    .disabled(store.processing || store.recording)
                ForEach(store.transcriptionJobs.filter { $0.state == .failed }) { job in
                    Text("尝试 \(job.attempts) 次：\(job.failure ?? "转写失败")").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {} footer: { Text("系统后台不保证持续运行。") }
        }.navigationTitle("本地转写").navigationBarTitleDisplayMode(.inline)
    }
}
