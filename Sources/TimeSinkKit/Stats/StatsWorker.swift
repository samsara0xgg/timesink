import Foundation

/// Serial background executor: the resolver memo survives refreshes but is never
/// shared mutably with CategoryResolver on the main actor.
actor StatsWorker {
    struct Heavy: Sendable {
        let trend: [Int?]
        let data: HeatmapData
        let occurrences: [Int]
        let fourWeeks: FourWeekComparison
    }
    struct Result: Sendable {
        let summary: StatsSummary
        let heavy: Heavy?
    }

    private var classification: CategoryResolver.Snapshot?
    private var editVersion = -1
    private var dataVersion = -1
    /// The spans of recent short windows (a day or two), for the sidebar and
    /// the day overview. A wider window is held only while one call works on
    /// it: the Trends numbers are kept as summaries, never as spans.
    private var windows: [DateInterval: [CategorizedSpan]] = [:]
    private static let cachedWindowLimit: TimeInterval = 2 * 86400 + 3600
    private func dropWideWindows() { windows = windows.filter { $0.key.duration <= Self.cachedWindowLimit } }

    func dailyPulses(store: SpanStore, classification seed: CategoryResolver.Snapshot,
                     categories: [String: Category], editVersion: Int, dataVersion: Int,
                     days: Int, endingAt: Date, calendar: Calendar) throws -> [Int?] {
        try prepare(classification: seed, editVersion: editVersion, dataVersion: dataVersion)
        let pulses = try DailyPulseSummary.compute(store: store, days: days, endingAt: endingAt,
            calendar: calendar, categories: categories) { classification!.categoryID(for: $0) }
        try Task.checkCancellation()
        return pulses
    }

    /// `writes` is `AppModel.writeLog`: windows ending before every write
    /// since the last version survive it.
    func compute(store: SpanStore, classification seed: CategoryResolver.Snapshot,
                 categories: [String: Category], editVersion: Int, dataVersion: Int, range: DateRangeSelection,
                 includeHeavy: Bool, now: Date, calendar: Calendar, writes: [(version: Int, from: Date)] = []) throws -> Result {
        defer { dropWideWindows() }
        try prepare(classification: seed, editVersion: editVersion, dataVersion: dataVersion, writes: writes)
        let summary: StatsSummary
        do {
            let current = try items(store: store, in: range.interval)
            let previous = try items(store: store, in: range.previousInterval)
            try Task.checkCancellation()
            summary = StatsSummary(items: current, previous: previous, range: range,
                                   categories: categories, now: now, calendar: calendar)
        }
        var heavy: Heavy?
        if includeHeavy {
            let window = DateRangeSelection(kind: .last30, anchor: now).interval
            // Only the lookback is still needed; the two windows above can go first.
            windows = windows.filter { $0.key == window }
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
            let fourWeeks = FourWeekComparison(
                daily: Aggregator.stackedSeries(lookback, bucket: .day, calendar: calendar),
                today: now, categories: categories, calendar: calendar)
            heavy = Heavy(trend: trend, data: data, occurrences: occurrences, fourWeeks: fourWeeks)
        }
        try Task.checkCancellation()
        return Result(summary: summary, heavy: heavy)
    }

    func categoryRows(store: SpanStore, classification seed: CategoryResolver.Snapshot,
                      categories: [String: Category], editVersion: Int, dataVersion: Int,
                      interval: DateInterval, writes: [(version: Int, from: Date)] = []) throws -> [StatsModel.RankingRow] {
        defer { dropWideWindows() }
        try prepare(classification: seed, editVersion: editVersion, dataVersion: dataVersion, writes: writes)
        let totals = Aggregator.durationByCategory(try items(store: store, in: interval))
        try Task.checkCancellation()
        return totals.compactMap { id, seconds in
            categories[id].map { StatsModel.RankingRow(id: id, name: $0.name, colorHex: $0.colorHex, seconds: seconds) }
        }.sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
    }

    private func prepare(classification seed: CategoryResolver.Snapshot, editVersion: Int, dataVersion: Int,
                         writes: [(version: Int, from: Date)] = []) throws {
        try Task.checkCancellation()
        if classification == nil || self.editVersion != editVersion {
            classification = seed
            self.editVersion = editVersion
            windows.removeAll()
        }
        // Keep at most four windows; a tracking write invalidates rows without
        // throwing away the classification memo. Re-entering Stats reuses both.
        // Only windows reaching past a write can have changed: during tracking
        // yesterday and earlier periods stay cached. A version missing from
        // the log could have touched any day.
        if self.dataVersion != dataVersion {
            let seen = writes.filter { $0.version > self.dataVersion && $0.version <= dataVersion }
            let floor = seen.count == dataVersion - self.dataVersion ? seen.map(\.from).min() ?? .distantPast : .distantPast
            windows = windows.filter { $0.key.end <= floor }
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
        defer { dropWideWindows() }
        try prepare(classification: seed, editVersion: editVersion, dataVersion: dataVersion)
        return Set(try items(store: store, in: interval).lazy
            .filter { $0.categoryID == "uncategorized" }.map { $0.span.domain ?? $0.span.appBundleID }).count
    }

    /// The window's spans, classified and cut down to what the Stats numbers
    /// read: the title, address and document are left behind once the span is
    /// classified, and the repeated names share one string each.
    private func items(store: SpanStore, in interval: DateInterval) throws -> [CategorizedSpan] {
        if let cached = windows[interval] { return cached }
        try Task.checkCancellation()
        var result: [CategorizedSpan] = []
        var names: [String: String] = [:]
        func shared(_ string: String) -> String { names[string] ?? { names[string] = string; return string }() }
        var count = 0
        try store.forEachSpan(overlapping: interval) { span in
            count += 1
            if count.isMultiple(of: 128) { try Task.checkCancellation() }
            var clipped = span
            clipped.start = max(span.start, interval.start)
            clipped.end = min(span.end, interval.end)
            let category = classification!.categoryID(for: clipped)
            clipped.title = nil
            clipped.url = nil
            clipped.document = nil
            clipped.appBundleID = shared(clipped.appBundleID)
            clipped.appName = shared(clipped.appName)
            clipped.domain = clipped.domain.map(shared)
            result.append(CategorizedSpan(span: clipped, categoryID: shared(category)))
        }
        result.sort { $0.span.start < $1.span.start }
        if windows.count >= 4 { windows.removeAll() }
        windows[interval] = result
        return result
    }
}
