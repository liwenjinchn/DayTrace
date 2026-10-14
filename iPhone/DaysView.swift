import SwiftUI
import UniformTypeIdentifiers

struct DaysView: View {
    @EnvironmentObject var store: PhoneStore
    @AppStorage("locale") private var locale = "zh-CN"
    @State private var importing = false
    @State private var pickingDate = false
    @State private var day = Date()
    private var daily: [Clip] { store.clips.filter { TimelineRules.seconds($0, day: day) > 0 } }
    private var dayTitle: String {
        if Calendar.current.isDateInToday(day) { return "今天" }
        if Calendar.current.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN")))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DayOverview(clips: daily, day: day, title: dayTitle)
                        .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 18, trailing: 20))
                }
                Section {
                    PhoneRecordingPanel()
                        .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))
                }
                Section("回顾") {
                    NavigationLink { DailyReviewView(day: day) } label: {
                        FeatureLabel(title: "每日复盘", subtitle: "把这一天，整理成有来源的回顾", symbol: "sun.max.fill", color: .orange)
                    }
                    NavigationLink { HighlightsView() } label: {
                        FeatureLabel(title: "重点与收藏", subtitle: "留下值得再次回听的片段", symbol: "star.fill", color: .yellow)
                    }
                }
                Section("当天记录") {
                    if daily.isEmpty {
                        QuietPlaceholder(title: "这一天，还没有录音", message: "录一段声音，或从右上角导入音频。\n原文准备好后，可以在这里回顾。", symbol: "waveform")
                    }
                    ForEach(daily) { clip in
                        NavigationLink { ClipView(clipID: clip.id) } label: { RecordingRow(clip: clip) }
                    }
                }
                if !daily.isEmpty {
                    Section {
                        NavigationLink { HourTimelineView(day: day) } label: {
                            FeatureLabel(title: "按小时回顾", subtitle: "沿着时间找回当天的记录", symbol: "clock.fill", color: .indigo)
                        }
                        NavigationLink {
                            SharePreviewView(title: "分享当天原文", original: Journal.markdown(store.clips, day: day), contexts: store.contextForSources(Journal.dailySources(store.clips, day: day)))
                        } label: { Label("预览并分享当天原文", systemImage: "square.and.arrow.up") }
                    }
                }
                Section {
                    DisclosureGroup {
                        Label(store.connection, systemImage: "applewatch")
                        Text("待处理 \(store.transcriptionJobs.filter { $0.state == .pending || $0.state == .running }.count) 段").font(.subheadline)
                        Text(store.searchStatus).font(.caption).foregroundStyle(.secondary)
                        ForEach(store.sessionEvents.filter { Calendar.current.isDate($0.time, inSameDayAs: day) }) { event in
                            if event.kind == .mark, let clip = store.clips.first(where: { $0.sessionID == event.sessionID && event.time >= $0.started && event.time <= $0.started.addingTimeInterval($0.duration + 1) }) {
                                NavigationLink("\(event.time.formatted(date: .omitted, time: .standard)) · 手动标记") {
                                    ClipView(clipID: clip.id, offset: max(0, event.time.timeIntervalSince(clip.started)))
                                }
                            } else { Text("\(event.time.formatted(date: .omitted, time: .standard)) · \(event.detail)").font(.caption) }
                        }
                    } label: { Label("设备与处理状态", systemImage: "applewatch") }
                } footer: {
                    Label("录音与转写在本机处理", systemImage: "lock.shield")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("日记")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { pickingDate = true } label: { Image(systemName: "calendar") }.accessibilityLabel("选择日期")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { importing = true } label: { Label("导入音频", systemImage: "square.and.arrow.down") }
                        Button { Task { await store.transcribePending(locale: locale) } } label: {
                            Label("转写待处理音频", systemImage: "text.bubble")
                        }.disabled(store.processing || store.recording || store.clips.isEmpty)
                    } label: { Image(systemName: "plus") }.accessibilityLabel("添加录音或转写")
                }
            }
            .sheet(isPresented: $pickingDate) {
                NavigationStack {
                    DatePicker("选择日期", selection: $day, displayedComponents: .date)
                        .datePickerStyle(.graphical).padding()
                        .navigationTitle("选择日期").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("今天") { day = Date() } }
                            ToolbarItem(placement: .confirmationAction) { Button("完成") { pickingDate = false } }
                        }
                }.presentationDetents([.medium, .large])
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url): Task { await store.importAudio(url) }
                case .failure(let error): store.error = error.localizedDescription
                }
            }
        }
    }
}

private struct DayOverview: View {
    let clips: [Clip]
    let day: Date
    let title: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.bold())
                Spacer()
                Text(day.formatted(.dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) { metrics }
                } else { HStack(alignment: .top, spacing: 12) { metrics } }
            }
            HourBars(clips: clips, day: day)
        }
    }
    @ViewBuilder private var metrics: some View {
        metric(DisplayDuration.text(clips.reduce(0) { $0 + TimelineRules.seconds($1, day: day) }), label: "录音时长", symbol: "waveform", color: .blue)
        metric("\(clips.count)", label: "录音片段", symbol: "mic", color: .purple)
        metric("\(clips.reduce(0) { $0 + $1.marks.count })", label: "手动标记", symbol: "bookmark", color: .orange)
    }
    private func metric(_ value: String, label: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(color)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HourBars: View {
    let clips: [Clip]
    let day: Date
    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<24) { hour in
                    let seconds = clips.reduce(0) { $0 + TimelineRules.seconds($1, day: day, hour: hour) }
                    Capsule().fill(seconds > 0 ? Color.blue : Color.secondary.opacity(0.12))
                        .frame(height: max(3, min(36, seconds / 100)))
                }
            }.frame(height: 36)
            HStack { Text("00:00"); Spacer(); Text("12:00"); Spacer(); Text("24:00") }
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }.accessibilityElement(children: .ignore).accessibilityLabel("当天每小时录音分布")
    }
}

private struct PhoneRecordingPanel: View {
    @EnvironmentObject var store: PhoneStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "mic.fill").font(.title3).foregroundStyle(.red)
                    .frame(width: 42, height: 42).background(Color.red.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.recording ? "正在记录" : "记录此刻").font(.headline)
                    Text(store.recording ? "结束后保存到今天的日记" : "用一段声音，留下这一天")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if store.recording {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: "%.1f / 60 秒", store.recordingDuration)).font(.title2.monospacedDigit()).foregroundStyle(.red)
                        let levels = store.recordingLevels
                        HStack(alignment: .center, spacing: 3) {
                            ForEach(0..<48, id: \.self) { index in
                                Capsule().fill(.red.opacity(0.75)).frame(height: max(3, (index < levels.count ? levels[index] : 0) * 36))
                            }
                        }.frame(height: 36).accessibilityLabel("麦克风输入音量")
                        Text((levels.suffix(12).max() ?? 0) > 0.15 ? "收到声音" : "输入较弱，请靠近麦克风")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Button { store.markRecording() } label: { Label("标记 \(store.recordingMarks)", systemImage: "bookmark") }
                        .buttonStyle(.bordered)
                    Button { store.stopRecording() } label: { Label("结束并保存", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(.red)
                }.controlSize(.large)
            } else {
                Button { Task { await store.startRecording() } } label: {
                    Label("开始录音", systemImage: "record.circle").font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large).disabled(store.processing)
            }
        }
    }
}

private struct RecordingRow: View {
    let clip: Clip
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: clip.marks.isEmpty ? "waveform" : "bookmark.fill")
                .foregroundStyle(clip.marks.isEmpty ? Color.blue : .orange)
                .frame(width: 34, height: 34).background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(clip.started.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN")))).font(.subheadline.weight(.semibold)).monospacedDigit()
                    Spacer()
                    Text(DisplayDuration.text(clip.duration)).font(.caption).foregroundStyle(.secondary)
                }
                Text(clip.text.isEmpty ? clip.statusLabel : clip.text)
                    .font(.subheadline).foregroundStyle(clip.text.isEmpty ? .secondary : .primary).lineLimit(3)
                if let failure = clip.failure { Text(failure).font(.caption).foregroundStyle(.red) }
            }
        }.padding(.vertical, 6)
    }
}

private struct HourTimelineView: View {
    @EnvironmentObject var store: PhoneStore
    let day: Date
    var body: some View {
        List {
            ForEach(Array(0..<24).filter { hour in store.clips.contains { TimelineRules.seconds($0, day: day, hour: hour) > 0 } }, id: \.self) { hour in
                NavigationLink { HourDetailView(day: day, hour: hour) } label: {
                    Label(String(format: "%02d:00 的记录", hour), systemImage: "clock")
                }
            }
        }.navigationTitle("按小时回顾").navigationBarTitleDisplayMode(.inline)
    }
}
