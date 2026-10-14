import SwiftUI

extension PhoneStore {
    var authorizedContextSamples: [ContextSample] {
        guard contextHealthy, let consent = contextState.consent, consent.service == currentAIService else { return [] }
        return contextState.samples.filter { $0.category == .health ? consent.health : consent.location }.sorted { $0.id < $1.id }
    }

    func contextForSources(_ sources: [SourceExcerpt]) -> [ContextSample] {
        guard contextHealthy else { return [] }
        return ContextRules.select(contextState.samples, sources: sources, consent: contextState.consent, service: currentAIService)
    }
    func saveContextSamples(_ samples: [ContextSample]) {
        do {
            guard contextHealthy else { throw ArchiveFailure.invalidClip }
            var next = contextState; let ids = Set(samples.map(\.id))
            next.samples.removeAll { ids.contains($0.id) }; next.samples += samples
            try ContextRules.save(next, root: root); contextState = next
        } catch { self.error = error.localizedDescription }
    }
    func consentContext(health: Bool, location: Bool) {
        do {
            guard contextHealthy else { throw ArchiveFailure.invalidClip }
            var next = contextState; next.consent = ContextConsent(service: currentAIService, health: health, location: location)
            try ContextRules.save(next, root: root); contextState = next
        } catch { self.error = error.localizedDescription }
    }
}
struct ContextRows: View {
    @EnvironmentObject var store: PhoneStore
    let sources: [SourceExcerpt]
    var samples: [ContextSample] {
        ContextRules.select(store.contextState.samples, sources: sources,
            consent: ContextConsent(service: store.currentAIService, health: UserDefaults.standard.bool(forKey: "localHealth"), location: UserDefaults.standard.bool(forKey: "localLocation")), service: store.currentAIService)
    }
    var body: some View {
        if samples.isEmpty { Text("没有可用或已开启的上下文；缺失不表示正常或零值。").font(.caption) }
        ForEach(samples) { sample in
            VStack(alignment: .leading) { Text("\(sample.label)：\(sample.value)"); Text(sample.origin).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
struct ContextSettingsView: View {
    @EnvironmentObject var store: PhoneStore
    @StateObject private var collector = ContextCollector()
    @AppStorage("localHealth") var localHealth = false
    @AppStorage("localLocation") var localLocation = false
    @State private var health = false
    @State private var location = false
    @State private var confirm = false
    @State private var day = Date()
    @State private var busy = false
    var body: some View {
        Form {
            Section {
                Toggle("本地显示健康与活动", isOn: $localHealth)
                if localHealth {
                    DatePicker("读取日期", selection: $day, displayedComponents: .date)
                    Button("请求健康权限并读取当天数据") { Task {
                        busy = true; defer { busy = false }
                        do { store.saveContextSamples(try await collector.readHealth(day: day)) } catch { store.error = error.localizedDescription }
                    } }.disabled(busy)
                }
                Toggle("本地显示位置", isOn: $localLocation)
                if localLocation { Button("读取当前位置") { collector.requestLocation() }; Text(collector.message).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("只在本机显示") } footer: { Text("本地显示不会授权 AI 外发；健康只显示日汇总，位置仅在你点击时读取。") }
            Section {
                Toggle("发送相关健康数据", isOn: $health).onChange(of: health) { _, value in if !value { store.consentContext(health: false, location: store.contextState.consent?.service == store.currentAIService && store.contextState.consent?.location == true) } }
                Toggle("发送相关位置数据", isOn: $location).onChange(of: location) { _, value in if !value { store.consentContext(health: store.contextState.consent?.service == store.currentAIService && store.contextState.consent?.health == true, location: false) } }
                Button("查看并确认外发范围") { confirm = true }
            } header: { Text("向 AI 服务发送") } footer: {
                Text("关闭立即生效，开启需要确认。目的接口：\(store.currentAIService.endpoint)。已发送数据无法撤回，更换服务后旧授权不生效。")
            }
            Section {
                NavigationLink("本地样本（\(store.contextState.samples.count)）") { ContextSamplesView() }
                DisclosureGroup("采集与关联说明") {
                    Text("健康不用于推断压力、情绪或因果。位置约公里精度，关联前后 15 分钟，不后台追踪。未读到数据不会填零。")
                }.font(.subheadline)
            }
        }.navigationTitle("健康与位置").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let consent = store.contextState.consent
            health = consent?.service == store.currentAIService && consent?.health == true
            location = consent?.service == store.currentAIService && consent?.location == true
            collector.onLocation = { store.saveContextSamples([$0]) }
        }
        .confirmationDialog("允许向当前服务发送与原文时间匹配的以下类别：\(health ? "健康 " : "")\(location ? "位置" : "")。不发送原始音频。", isPresented: $confirm, titleVisibility: .visible) {
            Button("确认以上独立类别") { store.consentContext(health: health, location: location) }
        }
    }
}

struct ContextSamplesView: View {
    @EnvironmentObject var store: PhoneStore
    var body: some View {
        List {
            if store.contextState.samples.isEmpty { QuietPlaceholder(title: "还没有本地样本", message: "主动读取健康或位置数据后，可在这里核对。", symbol: "heart.text.square") }
            ForEach(store.contextState.samples.sorted { $0.start > $1.start }) { sample in
                NavigationLink { ContextSampleDetailView(sample: sample) } label: {
                    VStack(alignment: .leading, spacing: 6) { Text("\(sample.label)：\(sample.value)"); Text(sample.start.journalLabel).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 4)
                }
            }
            if !store.contextState.samples.isEmpty {
                Section { Button("删除本地上下文样本", role: .destructive) {
                    do { var next = store.contextState; next.samples = []; try ContextRules.save(next, root: store.root); store.contextState = next }
                    catch { store.error = error.localizedDescription }
                } }
            }
        }.navigationTitle("本地上下文样本").navigationBarTitleDisplayMode(.inline)
    }
}

struct ContextSampleDetailView: View {
    @EnvironmentObject var store: PhoneStore
    let sample: ContextSample
    var body: some View {
        List {
            Section { Text(sample.label).font(.headline); Text(sample.value).font(.title3).padding(.vertical, 4) }
            Section("时间关联的原文") { ForEach(ArchiveRules.excerpts(store.clips).filter { let time = $0.started.addingTimeInterval($0.offset); return time >= sample.start && time < sample.end }) { source in SourceRow(source: source) } }
            Section { DisclosureGroup("样本信息") { Text(sample.origin); Text(sample.start.journalLabel); Text("这里只显示时间相关的原文，不代表因果或情绪判断。").font(.footnote).foregroundStyle(.secondary) } }
        }.navigationTitle("上下文关联原文").navigationBarTitleDisplayMode(.inline)
    }
}
