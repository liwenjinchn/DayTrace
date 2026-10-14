import SwiftUI

// System colors and semantic type scale with appearance and accessibility settings.
struct FeatureLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    var color: Color = .blue

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(color, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
    }
}

struct QuietPlaceholder: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle.weight(.light))
                .foregroundStyle(.blue)
                .padding(18)
                .background(Color.blue.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 24)
    }
}

enum DisplayDuration {
    static func text(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return "\(total / 3600) 小时 \(total % 3600 / 60) 分" }
        if total >= 60 { return "\(total / 60) 分 \(total % 60) 秒" }
        return "\(total) 秒"
    }
}

struct PrimaryActionLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol).font(.headline).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 2)
    }
}

struct ServiceSummary: View {
    let service: AIService
    var body: some View {
        LabeledContent("服务", value: URL(string: service.endpoint)?.host ?? service.endpoint)
        LabeledContent("模型", value: service.model)
    }
}

extension Date {
    var dayLabel: String { formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) }
    var timeLabel: String { formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN"))) }
    var journalLabel: String { formatted(.dateTime.year().month().day().hour().minute().locale(Locale(identifier: "zh_CN"))) }
}
