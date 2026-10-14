import Foundation
import HealthKit
import CoreLocation

@MainActor final class ContextCollector: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published var message = "未读取健康或位置数据"
    private let health = HKHealthStore()
    private let location = CLLocationManager()
    var onLocation: ((ContextSample) -> Void)?
    override init() { super.init(); location.delegate = self; location.desiredAccuracy = kCLLocationAccuracyKilometer }
    func requestLocation() {
        switch location.authorizationStatus {
        case .notDetermined: location.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: location.requestLocation()
        default: message = "位置未授权，录音和检索仍可使用"
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Request a fresh point only in response to an explicit user action.
        message = "位置权限状态已更新；点击读取当前位置以采集"
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let point = locations.last, point.horizontalAccuracy >= 0, abs(point.timestamp.timeIntervalSinceNow) < 300 else { message = "没有可用的新位置"; return }
        onLocation?(ContextSample(id: UUID().uuidString, category: .location, label: "大致位置（约公里精度）",
            value: String(format: "%.2f, %.2f · 定位精度约 %.0f 米", point.coordinate.latitude, point.coordinate.longitude, point.horizontalAccuracy),
            start: point.timestamp.addingTimeInterval(-900), end: point.timestamp.addingTimeInterval(900), origin: "CoreLocation · 单次定位，关联时间前后15分钟"))
        message = "已在本机保存位置；是否外发由独立开关决定"
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { message = "位置不可用：\(error.localizedDescription)" }
    func readHealth(day: Date) async throws -> [ContextSample] {
        guard HKHealthStore.isHealthDataAvailable() else { message = "此环境不提供健康数据"; return [] }
        let specifications: [(HKQuantityTypeIdentifier, String, HKUnit, HKStatisticsOptions)] = [
            (.stepCount, "当日步数", .count(), .cumulativeSum),
            (.heartRate, "当日平均心率（次/分钟）", HKUnit.count().unitDivided(by: .minute()), .discreteAverage),
            (.heartRateVariabilitySDNN, "当日平均 HRV SDNN（毫秒）", .secondUnit(with: .milli), .discreteAverage),
            (.appleExerciseTime, "当日运动分钟", .minute(), .cumulativeSum)
        ]
        let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let types = Set<HKObjectType>(specifications.compactMap { HKQuantityType.quantityType(forIdentifier: $0.0) } + [sleep])
        try await health.requestAuthorization(toShare: [], read: types)
        let start = Calendar.current.startOfDay(for: day), end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: day))!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        var samples: [ContextSample] = []
        for (id, label, unit, options) in specifications {
            let type = HKQuantityType.quantityType(forIdentifier: id)!
            let value: Double? = try await withCheckedThrowingContinuation { continuation in
                health.execute(HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: options) { _, stats, error in
                    if let error { continuation.resume(throwing: error); return }
                    continuation.resume(returning: (options == .cumulativeSum ? stats?.sumQuantity() : stats?.averageQuantity())?.doubleValue(for: unit))
                })
            }
            if let value, value.isFinite {
                samples.append(ContextSample(id: "\(id.rawValue)|\(start.timeIntervalSince1970)", category: .health, label: label, value: String(format: "%.1f", value), start: start, end: end, origin: "HealthKit 日汇总；不表示某一时刻状态或情绪"))
            }
        }
        let sleepSamples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            health.execute(HKSampleQuery(sampleType: sleep, predicate: HKQuery.predicateForSamples(withStart: start, end: end), limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, records, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: records as? [HKCategorySample] ?? [])
            })
        }
        let asleepValues = Set([HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue])
        let ranges = sleepSamples.filter { asleepValues.contains($0.value) }.compactMap { sample -> Range<Double>? in
            let lower = max(start, sample.startDate).timeIntervalSince1970, upper = min(end, sample.endDate).timeIntervalSince1970
            return lower < upper ? lower..<upper : nil
        }
        if !ranges.isEmpty {
            let seconds = AudioVault.merged(ranges).reduce(0) { $0 + $1.upperBound - $1.lowerBound }
            samples.append(ContextSample(id: "sleep|\(start.timeIntervalSince1970)", category: .health, label: "当日时间范围内睡眠（小时）", value: String(format: "%.2f", seconds / 3600), start: start, end: end, origin: "HealthKit 睡眠阶段区间去重合并，不代表睡眠质量"))
        }
        message = samples.isEmpty ? "无可读取样本或未授予读取权限；缺失不记为零" : "已读取 \(samples.count) 项日汇总；没有压力或情绪推断"
        return samples
    }
}
