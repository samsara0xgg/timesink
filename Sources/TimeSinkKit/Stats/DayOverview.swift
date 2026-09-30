import Foundation
import Observation

/// One day's persisted evidence. Recording gaps and focus sessions are separate
/// from category-derived engagement; none is inferred from another.
struct DayOverview: Sendable {
    /// A folded stretch of activity (`segment`) or of unrecorded time.
    struct Piece: Identifiable, Sendable {
        let start: Date
        var end: Date
        var segment: TimelineSegment?
        /// The segment's representative raw span: the longest one of its
        /// leading row. Opening a piece selects this in Activities.
        var item: CategorizedSpan? { segment?.dominant.longest }
        var id: String { "\(start.timeIntervalSince1970)|\(segment == nil ? "gap" : "activity")" }
        /// Recorded time for activity, elapsed time for a gap.
        var seconds: TimeInterval { segment?.recorded ?? end.timeIntervalSince(start) }
    }
    struct CategoryTotal: Identifiable, Sendable {
        let id: String
        let name: String
        let colorHex: String
        let seconds: TimeInterval
    }

    /// The resolution the day's list of pieces is folded at: a row per stretch
    /// of at least five minutes, not one per window switch.
    static let listResolution: TimeInterval = 300

    let day: DateInterval
    /// What the day ribbon draws: from the hour of the first record to a
    /// little after now, never to midnight.
    let displayInterval: DateInterval
    /// The day's raw spans, clipped and sorted, for re-folding at other scales.
    let items: [CategorizedSpan]
    let pieces: [Piece]
    let categories: [CategoryTotal]
    let sessions: [FocusSession]
    let total: TimeInterval
    let engaged: TimeInterval
    let sessionSeconds: TimeInterval
    let gapSeconds: TimeInterval
    let now: Date

    var firstRecord: Date? { pieces.first { $0.item != nil }?.start }

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

        self.items = clipped
        pieces = Self.pieces(clipped, resolution: Self.listResolution, grouping: .activity)
        gapSeconds = pieces.filter { $0.segment == nil }.reduce(0) { $0 + $1.seconds }
        // Use real local-day boundaries, including 23/25-hour DST days. Records
        // end at now, so the span with data runs from the first record's hour
        // to the hour boundary at least half an hour past now.
        let first = min(clipped.first?.span.start ?? now, now)
        let start = calendar.dateInterval(of: .hour, for: first)?.start ?? day.start
        let last = now.addingTimeInterval(1800)
        let lastHour = calendar.dateInterval(of: .hour, for: last)
        let end = min(day.end, lastHour?.start == last ? last : lastHour?.end ?? day.end)
        displayInterval = DateInterval(start: max(day.start, start), end: max(start.addingTimeInterval(1), end))
    }

    /// Folded activity with the unrecorded stretches between it, in time order.
    /// `forDrawing`: see `TimelineSegmenter`.
    static func pieces(_ items: [CategorizedSpan], resolution: TimeInterval,
                       grouping: TimelineSegmenter.Grouping, forDrawing: Bool = false) -> [Piece] {
        var result: [Piece] = []
        for segment in TimelineSegmenter.segments(items, resolution: resolution, grouping: grouping,
                                                  forDrawing: forDrawing) {
            if let previous = result.last, segment.start > previous.end {
                result.append(Piece(start: previous.end, end: segment.start, segment: nil))
            }
            result.append(Piece(start: segment.start, end: segment.end, segment: segment))
        }
        return result
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
