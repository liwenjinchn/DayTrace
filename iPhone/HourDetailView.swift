import SwiftUI

struct HourDetailView: View {
    @EnvironmentObject var store: PhoneStore
    let day: Date
    let hour: Int
    @State private var tab = "原文"
    var clips: [Clip] { store.clips.filter { TimelineRules.seconds($0, day: day, hour: hour) > 0 }.sorted { $0.started < $1.started } }
    var sources: [SourceExcerpt] {
        Journal.dailySources(clips, day: day).filter { Calendar.current.component(.hour, from: $0.started.addingTimeInterval($0.offset)) == hour }
    }
    var highlights: [AudioHighlight] { store.audioVault.highlights.filter { h in sources.contains { $0.id == h.source.id } } }
    var body: some View {
        List {
            Picker("内容", selection: $tab) { ForEach(["原文", "重点", "摘要"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            if tab == "原文" {
                ForEach(clips) { clip in
                    NavigationLink { ClipView(clipID: clip.id) } label: {
                        VStack(alignment: .leading) {
                            Text(clip.started.timeLabel).font(.caption).foregroundStyle(.secondary)
                            Text(clip.text.isEmpty ? clip.statusLabel : clip.text).lineLimit(6)
                            if !clip.marks.isEmpty { Label("手动 Mark \(clip.marks.count)", systemImage: "bookmark") }
                        }
                    }
                }
            } else if tab == "重点" {
                ForEach(highlights) { highlight in NavigationLink(highlight.title) { HighlightDetail(id: highlight.id) } }
                if highlights.isEmpty { Text("本小时尚无 AI 重点；手动 Mark 在原文中保留。") }
            } else {
                // Reuse grounded review results instead of silently creating another paid request.
                let relevant = store.reviews.filter { item in item.sources.contains { source in sources.contains { $0.id == source.id } } }
                if let latest = relevant.first {
                    Text(latest.userText ?? latest.answer.answer).textSelection(.enabled)
                    Text("这是包含本小时来源的复盘批次，也可能覆盖其他时间；不是独立生成的小时摘要。").font(.caption)
                    NavigationLink("查看每日复盘与引用") { DailyReviewView(day: day) }
                } else { Text("尚无相关复盘。原文已经可以阅读和检索，无需等待 AI。") }
            }
            Section { DisclosureGroup("关联上下文") { ContextRows(sources: sources) } }
        }.navigationTitle(String(format: "%02d:00 的记录", hour)).navigationBarTitleDisplayMode(.inline)
    }
}
