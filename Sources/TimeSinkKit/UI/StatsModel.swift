import Foundation
import Observation

/// Runs database reads, classification and chart aggregation on a dedicated actor.
/// The main actor only publishes completed snapshots and handles interaction.
@MainActor
@Observable
final class StatsModel {
    enum Granularity: String, CaseIterable, Hashable {
        case day, week
    }

    struct StackedPoint: Identifiable, Sendable {
        var id: String { "\(bucketStart.timeIntervalSince1970)_\(categoryID)" }
        let bucketStart: Date
        let categoryID: String
        let categoryName: String
        let colorHex: String
        let hours: Double
    }

    struct RankingRow: Identifiable, Sendable {
        let id: String
        let name: String
        let colorHex: String
        let seconds: TimeInterval
        /// The category its color comes from, so the adaptive palette applies.
        var categoryID: String? = nil
        var isDomain = false
    }

    /// The ranking may be shortened; the chart's denominator must never be.
    nonisolated static func distributionRows(_ rows: [RankingRow], limit: Int = 10) -> [RankingRow] {
        let ordered = rows.filter { $0.seconds > 0 }.sorted {
            $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds
        }
        let visibleCount = max(0, limit)
        guard ordered.count > visibleCount else { return ordered }
        let remainder = ordered.dropFirst(visibleCount)
        return Array(ordered.prefix(visibleCount)) + [RankingRow(
            id: "__timesink_distribution_remainder__", name: String(localized: "其余（\(remainder.count) 项）"),
            colorHex: "#98989D", seconds: remainder.reduce(0) { $0 + $1.seconds })]
    }

    static let streakThreshold = 70
    private var summary = StatsSummary()
    var total: TimeInterval { summary.total }
    var avgPerDay: TimeInterval { summary.avgPerDay }
    var pulse: Int? { summary.pulse }
    var focus: TimeInterval { summary.focus }
    var totalDelta: TimeInterval? { summary.totalDelta }
    var focusDelta: TimeInterval? { summary.focusDelta }
    var pulseDelta: Int? { summary.pulseDelta }
    var stackedByDay: [StackedPoint] { summary.stackedByDay }
    var stackedByWeek: [StackedPoint] { summary.stackedByWeek }
    var stackedDomainNames: [String] { summary.stackedDomainNames }
    var days: [Date] { summary.chartDays }
    var dayMarks: [(midday: Date, label: String, isToday: Bool)] { summary.dayMarks }
    var dayHourScale: (top: Double, step: Double) { summary.dayHourScale }
    var weekHourScale: (top: Double, step: Double) { summary.weekHourScale }
    var stackedDomainColorHex: [String] { summary.stackedDomainColorHex }
    var appRows: [RankingRow] { summary.appRows }
    var categoryRows: [RankingRow] { summary.categoryRows }
    var categoryDeltas: [String: TimeInterval] { summary.categoryDeltas }

    var scoreTrend: [Int?] = []
    var trendStreak = 0
    var heatmap: [[(pulse: Int?, seconds: TimeInterval)]] = []
    var heatmapData: HeatmapData?
    var heatmapInteraction = HeatmapInteraction()
    var heatmapOccurrences = Array(repeating: 0, count: 7)
    private(set) var lastHeavyUpdate: Date?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// The range the shown numbers belong to.
    private(set) var shownRange: DateRangeSelection?
    private(set) var loadError: String?

    @ObservationIgnored private let worker = StatsWorker()
    @ObservationIgnored private var lastRange: DateRangeSelection?
    @ObservationIgnored private var lastDataVersion = -1
    @ObservationIgnored private var lastHeavyEditVersion = -1
    @ObservationIgnored private var lastHeavyDay: Date?
    @ObservationIgnored private var generation = 0

    func sidebarRows(model: AppModel) async throws -> [RankingRow] {
        try await worker.categoryRows(store: model.spanStore, classification: model.resolver.snapshot(),
            categories: model.resolver.categoriesByID, editVersion: model.dataEditVersion,
            dataVersion: model.dataVersion, interval: model.range.interval, writes: model.writeLog)
    }

    /// `range` is the stretch to get ready before anyone is looking at it
    /// (the default one, from the main window); without it, the stretch the
    /// page is showing. The same window is not worked out twice.
    func recompute(model: AppModel, range ahead: DateRangeSelection? = nil, forceHeavy: Bool = false) async {
        let now = Date()
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        // Once the page is on screen it asks for its own range; getting ahead is for before.
        let prefetch = ahead != nil && model.sidebarSelection != .stats
        let range = prefetch ? ahead! : model.range
        let version = model.dataVersion
        let editVersion = model.dataEditVersion
        let needsHeavy = forceHeavy || lastHeavyDay != day || lastHeavyEditVersion != editVersion
            || now.timeIntervalSince(lastHeavyUpdate ?? .distantPast) >= 60
        let needsSummary = !hasLoaded || lastRange?.window != range.window || lastDataVersion != version || needsHeavy
        guard needsSummary || needsHeavy else { return }
        generation += 1
        let request = generation
        isLoading = true
        loadError = nil
        defer { if generation == request { isLoading = false } }
        do {
            let result = try await worker.compute(store: model.spanStore,
                classification: model.resolver.snapshot(), categories: model.resolver.categoriesByID,
                editVersion: editVersion, dataVersion: version, range: range, includeHeavy: needsHeavy, now: now, calendar: calendar,
                writes: model.writeLog)
            try Task.checkCancellation()
            // A newer route/edit must never be replaced by an older calculation.
            guard request == generation, prefetch || model.range == range, model.dataEditVersion == editVersion else { return }
            summary = result.summary
            lastRange = range
            if shownRange != range { shownRange = range }
            lastDataVersion = version
            hasLoaded = true
            if let heavy = result.heavy {
                scoreTrend = heavy.trend
                trendStreak = Aggregator.streak(dailyPulses: heavy.trend, threshold: Self.streakThreshold)
                heatmapData = heavy.data
                heatmap = (0..<7).map { weekday in
                    (0..<24).map { hour in
                        let cell = heavy.data[.init(weekday: weekday, hour: hour)]
                        return (pulse: cell.pulse, seconds: cell.seconds)
                    }
                }
                heatmapOccurrences = heavy.occurrences
                lastHeavyDay = day
                lastHeavyEditVersion = editVersion
                lastHeavyUpdate = now
            }
        } catch is CancellationError {
            // Leaving the page cancels the work without clearing a usable snapshot.
        } catch {
            loadError = String(localized: "统计暂时无法读取，请重试。")
        }
    }
}
