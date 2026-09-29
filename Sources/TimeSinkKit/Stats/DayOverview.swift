import Foundation
import Observation

/// One day's persisted evidence. Recording gaps and focus sessions are separate
/// from category-derived engagement; none is inferred from another.
struct DayOverview: Sendable {
    struct Piece: Identifiable, Sendable {
        let start: Date
        var end: Date
        let item: CategorizedSpan?
        var id: String { "\(start.timeIntervalSince1970)|\(item?.span.id.map(String.init) ?? item?.span.appBundleID ?? "gap")|\(item?.span.title ?? "")" }
        var seconds: TimeInterval { end.timeIntervalSince(start) }
    }
    struct CategoryTotal: Identifiable, Sendable {
        let id: String
        let name: String
        let colorHex: String
        let seconds: TimeInterval
    }

    let day: DateInterval
    let displayInterval: DateInterval
    let pieces: [Piece]
    let categories: [CategoryTotal]
    let sessions: [FocusSession]
    let total: TimeInterval
    let engaged: TimeInterval
    let sessionSeconds: TimeInterval
    let gapSeconds: TimeInterval
    let now: Date

    var firstRecord: Date? { pieces.first { $0.item != nil }?.start }
    var vesselHours: Double { max(10, ceil(total / 7200) * 2) }

    init(items: [CategorizedSpan], categories: [String: Category], sessions: [FocusSession],
         now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        let day = calendar.dateInterval(of: .day, for: now)!
        self.day = day
        let clipped = items.compactMap { entry -> CategorizedSpan? in
            var entry = entry
            entry.span.start = max(day.start, entry.span.start)
            entry.span.end = min(day.end, now, entry.span.end)
            return entry.span.end > entry.span.start ? entry : nil
        }.sorted {
            $0.span.start == $1.span.start ? $0.span.end < $1.span.end : $0.span.start < $1.span.start
        }
        let totals = Aggregator.durationByCategory(clipped)
        total = totals.values.reduce(0, +)
        engaged = Aggregator.focusTime(durationByCategory: totals, categories: categories)
        self.categories = totals.map { id, seconds in
            CategoryTotal(id: id, name: categories[id]?.name ?? String(localized: "未分类"),
                          colorHex: categories[id]?.colorHex ?? "#8E8E93", seconds: seconds)
        }.sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
        self.sessions = sessions.compactMap { session in
            var session = session
            session.start = max(session.start, day.start)
            session.end = min(session.end, day.end, now)
            return session.end > session.start ? session : nil
        }
        sessionSeconds = self.sessions.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }

        var result: [Piece] = []
        var coveredUntil: Date?
        var gaps: TimeInterval = 0
        for entry in clipped {
            if let coveredUntil, entry.span.start > coveredUntil {
                result.append(Piece(start: coveredUntil, end: entry.span.start, item: nil))
                gaps += entry.span.start.timeIntervalSince(coveredUntil)
            }
            if let last = result.last, let prior = last.item,
               last.end == entry.span.start, prior.categoryID == entry.categoryID,
               prior.span.appBundleID == entry.span.appBundleID, prior.span.title == entry.span.title,
               prior.span.url == entry.span.url, prior.span.document == entry.span.document {
                result[result.count - 1].end = entry.span.end
            } else {
                result.append(Piece(start: entry.span.start, end: entry.span.end, item: entry))
            }
            coveredUntil = max(coveredUntil ?? entry.span.end, entry.span.end)
        }
        pieces = result
        gapSeconds = gaps
        // Use real local-day boundaries, including 23/25-hour DST days. Always
        // include early/late records and the current time rather than hiding them.
        let defaultStart = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? day.start
        let defaultEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? day.end
        let first = min(clipped.first?.span.start ?? defaultStart, defaultStart, now)
        let start = calendar.dateInterval(of: .hour, for: first)?.start ?? day.start
        let last = max(clipped.last?.span.end ?? defaultEnd, defaultEnd, now)
        let lastHour = calendar.dateInterval(of: .hour, for: last)
        let end = min(day.end, lastHour?.start == last ? last : lastHour?.end ?? day.end)
        displayInterval = DateInterval(start: max(day.start, start), end: max(start.addingTimeInterval(1), end))
    }
}

@MainActor
@Observable
final class DayOverviewModel {
    var overview: DayOverview?
    var loadError: String?
    var budgets: [Budget] = []
    @ObservationIgnored private let worker = StatsWorker()
    @ObservationIgnored private var generation = 0

    func refresh(model: AppModel, now: Date = Date()) async {
        generation += 1
        let request = generation
        do {
            let result = try await worker.dayOverview(store: model.spanStore, focusStore: model.focusStore,
                classification: model.resolver.snapshot(), categories: model.resolver.categoriesByID,
                editVersion: model.dataEditVersion, dataVersion: model.dataVersion, now: now, calendar: .current)
            let budgets = try model.budgetStore?.budgets().filter(\.enabled) ?? []
            try Task.checkCancellation()
            guard generation == request else { return }
            overview = result
            self.budgets = budgets
            loadError = nil
        } catch is CancellationError {
            // Keep the most recent completed snapshot when leaving the page.
        } catch {
            guard generation == request else { return }
            loadError = String(localized: "今天的记录暂时无法读取。请重试。")
        }
    }
}
