import SwiftUI

struct HighlightsView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var favoritesOnly = false
    private var visible: [AudioHighlight] { store.audioVault.highlights.filter { !favoritesOnly || $0.favorite } }
    var body: some View {
        List {
            Section { Picker("显示范围", selection: $favoritesOnly) { Text("全部重点").tag(false); Text("收藏").tag(true) }.pickerStyle(.segmented) }
            Section {
                if visible.isEmpty { QuietPlaceholder(title: favoritesOnly ? "还没有收藏" : "还没有重点", message: favoritesOnly ? "收藏重点后，可以再次回听对应的音频。" : "授权自动重点提取后，有来源的片段会出现在这里。", symbol: "star") }
                ForEach(visible) { highlight in
                    NavigationLink { HighlightDetail(id: highlight.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(highlight.title, systemImage: highlight.favorite ? "star.fill" : "text.quote").foregroundStyle(.primary)
                            Text(highlight.source.started.journalLabel).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }
            } footer: { Text("标题需结合原文核对。只有收藏或手动标记会额外保护音频。") }
            Section { NavigationLink("配置自动重点授权") { AutomaticReviewSettingsView() } }
        }.navigationTitle("重点与收藏").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { AudioRetentionSettingsView() } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("音频保留设置") } }
    }
}

struct AudioRetentionSettingsView: View {
    @EnvironmentObject var store: PhoneStore
    @State private var before = 30.0
    @State private var after = 60.0
    var body: some View {
        Form {
            Section {
                Stepper("标记前 \(Int(before)) 秒", value: $before, in: 0...120, step: 5)
                Stepper("标记后 \(Int(after)) 秒", value: $after, in: 5...120, step: 5)
                Button { store.setMarkWindow(before: before, after: after) } label: { PrimaryActionLabel(title: "保存范围并提取", symbol: "waveform") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } header: { Text("手动标记的全局范围") } footer: { Text("扩大范围不能恢复已经清理的声音。") }
            Section {
                Button(store.preparingAudio ? "正在本地提取…" : "提取或重试保留音频") { Task { await store.prepareRetainedAudio() } }
                    .disabled(store.preparingAudio || store.recording || store.processing)
                Text(store.preservationStatus).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("范围与保护规则") {
                    Text("缩小范围后，已有片段可能继续覆盖较宽范围；清理不会删除其他标记或收藏仍引用的音频。")
                    Text("新版 Watch 会话未结束、缺段或中断后没有结束清单时，继续保留原文件。所有片段仍在本机，没有自动上传或备份。")
                }.font(.subheadline)
            }
        }.navigationTitle("音频保留范围").navigationBarTitleDisplayMode(.inline)
        .onAppear { before = store.audioVault.markBefore; after = store.audioVault.markAfter }
    }
}

struct HighlightDetail: View {
    @EnvironmentObject var store: PhoneStore
    let id: String
    @State private var before = 15.0
    @State private var after = 15.0
    @State private var cancelFavorite = false
    @State private var deleteHighlight = false
    var highlight: AudioHighlight? { store.audioVault.highlights.first { $0.id == id } }
    var body: some View {
        List {
            if let h = highlight {
                Section {
                    Text(h.title).font(.title3.weight(.semibold)).padding(.vertical, 6)
                    Text(h.source.text).lineSpacing(6).textSelection(.enabled).padding(.vertical, 6)
                    NavigationLink("核对原文与时间") { ClipView(clipID: h.source.clipID, offset: h.start) }
                }
                Section {
                    Button { if h.favorite { cancelFavorite = true } else { store.setFavorite(id) } } label: {
                        Label(h.favorite ? "取消收藏" : "收藏并保留音频", systemImage: h.favorite ? "star.slash" : "star")
                    }.buttonStyle(.bordered).controlSize(.large)
                } footer: { Text(h.favorite ? "已收藏文字；音频以实际提取状态为准。" : "未收藏的重点不会额外保留音频。") }
                Section {
                    DisclosureGroup("音频范围与提取状态") {
                        Stepper("前 \(Int(before)) 秒", value: $before, in: 0...120, step: 5)
                        Stepper("后 \(Int(after)) 秒", value: $after, in: 0...120, step: 5)
                        Button(h.favorite ? "保存范围" : "收藏并保存范围") { store.setFavorite(id, before: before, after: after) }
                        if h.favorite {
                            ForEach(store.clips.sorted { $0.started < $1.started }) { clip in
                                let ranges = highlightRanges(h, clip: clip)
                                if !ranges.isEmpty {
                                    NavigationLink { ClipView(clipID: clip.id, offset: ranges[0].lowerBound) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(clip.started.journalLabel)
                                            let slices = store.audioVault.slices.filter { $0.clipID == clip.id && AudioVault.verified($0, root: store.root) }
                                            Text(ranges.allSatisfy { AudioVault.covered($0, slices: slices) } ? "音频已提取并校验" : "音频待提取或不可恢复，请核查").font(.footnote).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        ContextRows(sources: [h.source])
                    }
                }
                Section { Button("删除这条重点", role: .destructive) { deleteHighlight = true } }
            } else { QuietPlaceholder(title: "重点已不可用", message: "这条重点已删除或来源已变化。", symbol: "text.quote") }
        }.navigationTitle("重点详情").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("取消收藏后，音频回到原到期时间；已过期且无其他保护的范围可能立即清理。", isPresented: $cancelFavorite, titleVisibility: .visible) {
            Button("确认取消收藏", role: .destructive) { store.setFavorite(id) }
        }
        .confirmationDialog("删除重点将取消它的音频保护；已到期且无其他保护的音频可能被清理。", isPresented: $deleteHighlight, titleVisibility: .visible) {
            Button("确认删除重点", role: .destructive) { store.dismissHighlight(id) }
        }
        .onAppear { before = highlight?.before ?? 15; after = highlight?.after ?? 15 }
    }
    private func highlightRanges(_ h: AudioHighlight, clip: Clip) -> [Range<Double>] {
        // Reuse production range mapping, excluding independent Mark/pin claims.
        var state = AudioVaultState(); state.highlights = [h]
        let archive = store.clips.map { c -> Clip in var copy = c; copy.marks = []; copy.audioPinned = false; return copy }
        var target = clip; target.marks = []; target.audioPinned = false
        return AudioVault.ranges(target, archive: archive, state: state)
    }
}
