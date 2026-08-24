import Foundation
import Observation

/// Computes every StatsView card's data from a single `rangedSpans()` call.
/// `recompute` does one pass over the fetched spans (fanning out into several
/// pure `Aggregator` calls plus a couple of local groupings), never issuing
/// its own DB queries — callers re-invoke it on `onAppear` and whenever
/// `AppModel.dataVersion`/`range` change.
@MainActor
@Observable
final class StatsModel {
    enum Granularity: String, CaseIterable, Hashable {
        case day, week
    }

    struct ProfilePoint: Identifiable, Hashable {
        var id: String { label }
        let label: String
        let hours: Double
    }

    struct StackedPoint: Identifiable {
        var id: String { "\(bucketStart.timeIntervalSince1970)_\(categoryID)" }
        let bucketStart: Date
        let categoryID: String
        let categoryName: String
        let colorHex: String
        let hours: Double
    }

    struct RankingRow: Identifiable {
        let id: String
        let name: String
        let colorHex: String
        let seconds: TimeInterval
    }

    private static let weekdayLabels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    var total: TimeInterval = 0
    var avgPerDay: TimeInterval = 0
    var pulse: Int?

    var hourProfile: [ProfilePoint] = []
    var weekdayProfile: [ProfilePoint] = []
    var prodHourProfile: [ProfilePoint] = []
    var prodWeekdayProfile: [ProfilePoint] = []

    var stackedByDay: [StackedPoint] = []
    var stackedByWeek: [StackedPoint] = []
    var stackedDomainNames: [String] = []
    var stackedDomainColorHex: [String] = []

    var appRows: [RankingRow] = []
    var categoryRows: [RankingRow] = []

    func recompute(model: AppModel) {
        let items = model.rangedSpans()
        let calendar = Calendar.current
        let categories = model.resolver.categoriesByID

        total = Aggregator.totalDuration(items.map(\.span))
        let days = max(1, Int((model.range.interval.duration / 86400).rounded()))
        avgPerDay = total / Double(days)

        let byCategory = Aggregator.durationByCategory(items)
        pulse = Aggregator.pulse(durationByCategory: byCategory, categories: categories)

        hourProfile = Self.densifyHours(Aggregator.profileByHourOfDay(items, calendar: calendar))
        weekdayProfile = Self.densifyWeekdays(Aggregator.profileByWeekday(items, calendar: calendar))
        prodHourProfile = Self.densifyHours(
            Aggregator.productivityProfileByHourOfDay(items, categories: categories, calendar: calendar)
        )
        prodWeekdayProfile = Self.densifyWeekdays(
            Aggregator.productivityProfileByWeekday(items, categories: categories, calendar: calendar)
        )

        let dayStacks = Aggregator.stackedSeries(items, bucket: .day, calendar: calendar)
        let weekStacks = Aggregator.stackedSeries(items, bucket: .weekOfYear, calendar: calendar)
        stackedByDay = Self.stackedPoints(dayStacks, categories: categories)
        stackedByWeek = Self.stackedPoints(weekStacks, categories: categories)

        let presentCategoryIDs = Set(dayStacks.map(\.categoryID)).union(weekStacks.map(\.categoryID))
        let orderedCategories = presentCategoryIDs
            .compactMap { categories[$0] }
            .sorted { $0.sortOrder < $1.sortOrder }
        stackedDomainNames = orderedCategories.map(\.name)
        stackedDomainColorHex = orderedCategories.map(\.colorHex)

        // Ranking rows are colored by category, not per-app icons (ruling R4).
        // For apps, use each app's single largest-duration category.
        var appCategorySeconds: [String: [String: TimeInterval]] = [:]
        for item in items {
            appCategorySeconds[item.span.appBundleID, default: [:]][item.categoryID, default: 0] += item.span.duration
        }
        appRows = Aggregator.durationByApp(items.map(\.span))
            .prefix(10)
            .map { entry in
                let dominant = appCategorySeconds[entry.bundleID]?.max { $0.value < $1.value }?.key
                let colorHex = dominant.flatMap { categories[$0]?.colorHex } ?? "#98989D"
                return RankingRow(id: entry.bundleID, name: entry.appName, colorHex: colorHex, seconds: entry.seconds)
            }

        categoryRows = Array(
            byCategory
                .compactMap { categoryID, seconds -> RankingRow? in
                    guard let category = categories[categoryID] else { return nil }
                    return RankingRow(id: category.id, name: category.name, colorHex: category.colorHex, seconds: seconds)
                }
                .sorted { $0.seconds > $1.seconds }
                .prefix(10)
        )
    }

    private static func densifyHours(_ profile: [Int: TimeInterval]) -> [ProfilePoint] {
        (0..<24).map { hour in
            ProfilePoint(label: "\(hour)", hours: (profile[hour] ?? 0) / 3600.0)
        }
    }

    private static func densifyWeekdays(_ profile: [Int: TimeInterval]) -> [ProfilePoint] {
        (0..<7).map { day in
            ProfilePoint(label: weekdayLabels[day], hours: (profile[day] ?? 0) / 3600.0)
        }
    }

    private static func stackedPoints(
        _ series: [(bucketStart: Date, categoryID: String, seconds: TimeInterval)],
        categories: [String: Category]
    ) -> [StackedPoint] {
        series.map { entry in
            let category = categories[entry.categoryID]
            return StackedPoint(
                bucketStart: entry.bucketStart,
                categoryID: entry.categoryID,
                categoryName: category?.name ?? entry.categoryID,
                colorHex: category?.colorHex ?? "#98989D",
                hours: entry.seconds / 3600.0
            )
        }
    }
}
