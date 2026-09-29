import Foundation

/// Serial background executor: the resolver memo survives refreshes but is never
/// shared mutably with CategoryResolver on the main actor.
actor StatsWorker {
    struct Heavy: Sendable {
        let trend: [Int?]
        let data: HeatmapData
        let occurrences: [Int]
    }
    struct Result: Sendable {
        let summary: StatsSummary
        let heavy: Heavy?
    }

    private var classification: CategoryResolver.Snapshot?
    private var editVersion = -1
    private var dataVersion = -1
    private var windows: [DateInterval: [CategorizedSpan]] = [:]

    func dailyPulses(store: SpanStore, classification seed: CategoryResolver.Snapshot,
                     categories: [String: Category], editVersion: Int, dataVersion: Int,
                     days: Int, endingAt: Date, calendar: Calendar) throws -> [Int?] {
        try prepare(classification: seed, editVersion: editVersion, dataVersion: dataVersion)
        let pulses = try DailyPulseSummary.compute(store: store, days: days, endingAt: endingAt,
            calendar: calendar, categories: categories) { classification!.categoryID(for: $0) }
        try Task.checkCancellation()
        return pulses
    }

    func compute(store: SpanStore, classification seed: CategoryResolver.Snapshot,
                 categories: [String: Category], editVersion: Int, dataVersion: Int, range: DateRangeSelection,
                 includeHeavy: Bool, now: Date, calendar: Calendar) throws -> Result {
        try prepare(classification: seed, editVersion: editVersion, dataVersion: dataVersion)
        let current = try items(store: store, in: range.interval)
        let previous = try items(store: store, in: range.previousInterval)
        try Task.checkCancellation()
        let summary = StatsSummary(items: current, previous: previous, range: range,
                                   categories: categories, now: now, calendar: calendar)
        var heavy: Heavy?
        if includeHeavy {
            let window = DateRangeSelection(kind: .last30, anchor: now).interval
            let lookback = try items(store: store, in: window)
            try Task.checkCancellation()
            let trend = Aggregator.dailyPulses(items: lookback, categories: categories,
                                              days: 30, endingAt: now, calendar: calendar)
            let data = HeatmapData.build(lookback, categories: categories, window: window, now: now, calendar: calendar)
            var occurrences = Array(repeating: 0, count: 7)
            var day = calendar.startOfDay(for: window.start)
            while day < window.end {
                occurrences[(calendar.component(.weekday, from: day) + 5) % 7] += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            heavy = Heavy(trend: trend, data: data, occurrences: occurrences)
        }
        try Task.checkCancellation()
        return Result(summary: summary, heavy: heavy)
    }

    func categoryRows(store: SpanStore, classification seed: CategoryResolver.Snapshot,
                      categories: [String: Category], editVersion: Int, dataVersion: Int,
                      interval: DateInterval) throws -> [StatsModel.RankingRow] {
        try prepare(classification: seed, editVersion: editVersion, dataVersion: dataVersion)
        let totals = Aggregator.durationByCategory(try items(store: store, in: interval))
        try Task.checkCancellation()
        return totals.compactMap { id, seconds in
            categories[id].map { StatsModel.RankingRow(id: id, name: $0.name, colorHex: $0.colorHex, seconds: seconds) }
        }.sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
    }

    private func prepare(classification seed: CategoryResolver.Snapshot, editVersion: Int, dataVersion: Int) throws {
        try Task.checkCancellation()
        if classification == nil || self.editVersion != editVersion {
            classification = seed
            self.editVersion = editVersion
            windows.removeAll()
        }
        // Keep at most four windows; a tracking write invalidates rows without
        // throwing away the classification memo. Re-entering Stats reuses both.
        if self.dataVersion != dataVersion {
            windows.removeAll()
            self.dataVersion = dataVersion
        }
    }

    func dayOverview(store: SpanStore, focusStore: FocusSessionStore?, classification seed: CategoryResolver.Snapshot,
                     categories: [String: Category], editVersion: Int, dataVersion: Int,
                     now: Date, calendar: Calendar) throws -> DayOverview {
        try prepare(classification: seed, editVersion: editVersion, dataVersion: dataVersion)
        let day = calendar.dateInterval(of: .day, for: now)!
        let records = try items(store: store, in: day)
        let sessions = try focusStore?.sessions(overlapping: day) ?? []
        try Task.checkCancellation()
        return DayOverview(items: records, categories: categories, sessions: sessions, now: now, calendar: calendar)
    }

    /// Distinct apps and sites still uncategorized in `interval`.
    func uncategorizedCount(store: SpanStore, classification seed: CategoryResolver.Snapshot,
                            editVersion: Int, dataVersion: Int, interval: DateInterval) throws -> Int {
        try prepare(classification: seed, editVersion: editVersion, dataVersion: dataVersion)
        return Set(try items(store: store, in: interval).lazy
            .filter { $0.categoryID == "uncategorized" }.map { $0.span.domain ?? $0.span.appBundleID }).count
    }

    private func items(store: SpanStore, in interval: DateInterval) throws -> [CategorizedSpan] {
        if let cached = windows[interval] { return cached }
        try Task.checkCancellation()
        let spans = try store.spans(overlapping: interval)
        var result: [CategorizedSpan] = []
        result.reserveCapacity(spans.count)
        for (index, span) in spans.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            var clipped = span
            clipped.start = max(span.start, interval.start)
            clipped.end = min(span.end, interval.end)
            result.append(CategorizedSpan(span: clipped, categoryID: classification!.categoryID(for: clipped)))
        }
        if windows.count >= 4 { windows.removeAll() }
        windows[interval] = result
        return result
    }

}
