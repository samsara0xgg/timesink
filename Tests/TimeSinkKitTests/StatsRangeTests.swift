import XCTest
@testable import TimeSinkKit

final class StatsRangeTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    func testWeekAlignsMonday() {
        let sel = DateRangeSelection(kind: .week, anchor: date(2026, 8, 27))  // 周四
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.weekday, from: sel.interval.start), 2)  // 周一
        XCTAssertEqual(cal.startOfDay(for: sel.interval.start), cal.startOfDay(for: date(2026, 8, 24)))
        XCTAssertEqual(sel.interval.duration, 7 * 86400, accuracy: 3700)      // 容 DST
    }
    func testMonthInterval() {
        let sel = DateRangeSelection(kind: .month, anchor: date(2026, 8, 15))
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.day, from: sel.interval.start), 1)
        XCTAssertEqual(cal.component(.month, from: sel.interval.start), 8)
    }
    func testMonthShiftLandsPreviousMonth() {
        var sel = DateRangeSelection(kind: .month, anchor: date(2026, 8, 31))
        sel.shift(-1)  // 8/31 回退一个月：日历分量步进，不是 -31 天
        XCTAssertEqual(Calendar.current.component(.month, from: sel.anchor), 7)
    }
    func testShiftNeverPassesToday() {
        var sel = DateRangeSelection(kind: .week, anchor: Date())
        sel.shift(1)
        XCTAssertLessThanOrEqual(Calendar.current.startOfDay(for: sel.anchor),
                                 Calendar.current.startOfDay(for: Date()))
    }
    func testCustomSingleDay() {
        var sel = DateRangeSelection(kind: .custom, anchor: date(2026, 8, 10))
        sel.customStart = date(2026, 8, 10); sel.customEnd = date(2026, 8, 10)
        XCTAssertEqual(sel.interval.duration, 86400, accuracy: 3700)
    }
    func testPreviousIntervalWeekIsPreviousCalendarWeek() {
        let sel = DateRangeSelection(kind: .week, anchor: date(2026, 8, 27))
        XCTAssertEqual(sel.previousInterval.end, sel.interval.start)
        XCTAssertEqual(sel.previousInterval.duration, sel.interval.duration, accuracy: 3700)
    }
    func testPreviousIntervalLast7IsEqualLengthPreceding() {
        let sel = DateRangeSelection(kind: .last7, anchor: date(2026, 8, 24))
        XCTAssertEqual(sel.previousInterval.end, sel.interval.start)
        XCTAssertEqual(sel.previousInterval.duration, sel.interval.duration)
    }
    func testLabelForNewKinds() {
        XCTAssertEqual(DateRangeSelection(kind: .week, anchor: Date()).label, "本周")
        XCTAssertEqual(DateRangeSelection(kind: .month, anchor: Date()).label, "本月")
    }

    // MARK: - Fix round 1 (review findings)

    /// CRITICAL 1: `customStart`/`customEnd` are independently settable (the
    /// popover's two DatePickers, or any other caller) and `DateInterval`
    /// fatalErrors on end < start. A reversed pair must normalize instead of
    /// crashing `.interval`.
    func testCustomRangeReversedIsNormalized() {
        var sel = DateRangeSelection(kind: .custom, anchor: date(2026, 8, 10))
        sel.customStart = date(2026, 8, 16)
        sel.customEnd = date(2026, 8, 10)
        let iv = sel.interval
        let cal = Calendar.current
        XCTAssertLessThan(iv.start, iv.end)
        XCTAssertEqual(cal.startOfDay(for: iv.start), cal.startOfDay(for: date(2026, 8, 10)))
        XCTAssertEqual(cal.startOfDay(for: iv.end), cal.startOfDay(for: date(2026, 8, 17)))
    }

    /// CRITICAL 1, second trap path: `customStart` set past `anchor` with
    /// `customEnd` left `nil` (so `customEnd ?? anchor` resolves behind
    /// `customStart`) must also normalize rather than crash.
    func testCustomRangeStartAfterAnchorWithNilEndIsNormalized() {
        var sel = DateRangeSelection(kind: .custom, anchor: date(2026, 8, 10))
        sel.customStart = date(2026, 8, 20)
        let iv = sel.interval
        let cal = Calendar.current
        XCTAssertLessThan(iv.start, iv.end)
        XCTAssertEqual(cal.startOfDay(for: iv.start), cal.startOfDay(for: date(2026, 8, 10)))
        XCTAssertEqual(cal.startOfDay(for: iv.end), cal.startOfDay(for: date(2026, 8, 21)))
    }

    /// IMPORTANT 2 (ruling R-T7a): 2026-03-08 is the US DST "spring forward"
    /// day (2am -> 3am), so this calendar day is only 23 wall-clock hours
    /// long -- `previousInterval` must still land on a calendar-day
    /// boundary, not slip by the missing hour. Meaningful only on a
    /// DST-observing machine timezone (this repo's dev/CI machines are US
    /// Pacific, so this holds); on a non-DST TZ the day is a plain 86400s
    /// and the assertion holds trivially either way.
    func testPreviousIntervalDayAlignedAcrossSpringForwardDST() {
        let sel = DateRangeSelection(kind: .day, anchor: date(2026, 3, 8))
        let cal = Calendar.current
        XCTAssertEqual(cal.startOfDay(for: sel.previousInterval.start), sel.previousInterval.start)
    }

    /// IMPORTANT 2 (ruling R-T7a): 2026-11-01 is the US DST "fall back" day
    /// (2am -> 1am); anchoring `.last7` a few days after it makes the
    /// current 7-day window span that 25-hour day, so its own duration is
    /// inflated by an hour. `previousInterval` must still land on a
    /// calendar-day boundary. Same DST-observing-TZ caveat as above.
    func testPreviousIntervalLast7DayAlignedAcrossFallBackDST() {
        let sel = DateRangeSelection(kind: .last7, anchor: date(2026, 11, 4))
        let cal = Calendar.current
        XCTAssertEqual(cal.startOfDay(for: sel.previousInterval.start), sel.previousInterval.start)
    }

    /// FOLD-IN 5: `containsNow`/`contains(_:)` must be half-open
    /// (`[start, end)`), not `DateInterval.contains(_:)`'s closed-both-ends
    /// semantics -- otherwise two adjacent day selections both report
    /// `true` exactly at midnight.
    func testContainsIsHalfOpenAtIntervalEnd() {
        let sel = DateRangeSelection(kind: .day, anchor: date(2026, 8, 10))
        let iv = sel.interval
        XCTAssertTrue(sel.contains(iv.start))
        XCTAssertTrue(sel.contains(iv.end.addingTimeInterval(-1)))
        XCTAssertFalse(sel.contains(iv.end))
    }

    // MARK: - Task 8 (C2 stats): delta semantics + heavy-recompute gating

    func testDurationDeltaUsesClippedPreviousButPulseUsesFull() {
        let cal = Calendar.current
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        let todayStart = cal.startOfDay(for: ts(200_000))
        let prevStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
        // 昨天：0-4h softwareDev(+2)，18h-20h entertainment(-2)；今天走到 5h，产出 2h softwareDev
        let prev = [
            CategorizedSpan(span: Span(start: prevStart, end: prevStart.addingTimeInterval(4 * 3600),
                appBundleID: "x", appName: "X", title: nil, url: nil, domain: nil), categoryID: "softwareDev"),
            CategorizedSpan(span: Span(start: prevStart.addingTimeInterval(18 * 3600),
                end: prevStart.addingTimeInterval(20 * 3600),
                appBundleID: "y", appName: "Y", title: nil, url: nil, domain: nil), categoryID: "entertainment"),
        ]
        let elapsed: TimeInterval = 5 * 3600
        let clipped = Aggregator.clippedToElapsed(prev, windowStart: prevStart, elapsed: elapsed)
        // 裁剪后昨天只剩 0-4h 的 softwareDev：时长基准 4h，娱乐段被裁掉
        XCTAssertEqual(Aggregator.totalDuration(clipped.map(\.span)), 4 * 3600)
        // 分数基准用未裁全天：4h*100 + 2h*0 → (400+0)/6 ≈ 67
        let fullPulse = Aggregator.pulse(
            durationByCategory: Aggregator.durationByCategory(prev), categories: cats)
        XCTAssertEqual(fullPulse, 67)
    }

    @MainActor func testHeavyRecomputeGatedByDay() async throws {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        _ = try store.insert(Span(start: Date().addingTimeInterval(-3600), end: Date(),
                                  appBundleID: "a", appName: "A", title: nil, url: nil, domain: nil))
        let catStore = CategoryStore(db)
        let model = AppModel(categoryStore: catStore, spanStore: store,
                             settings: SettingsStore(db),
                             resolver: CategoryResolver(categoryStore: catStore),
                             engine: TrackerEngine(spanStore: store, settings: SettingsStore(db)))
        let stats = StatsModel()
        await stats.recompute(model: model, forceHeavy: true)
        let firstTrend = stats.scoreTrend
        XCTAssertEqual(firstTrend.count, 30)
        stats.scoreTrend = []                                  // 打标
        await stats.recompute(model: model, forceHeavy: false)       // 同日非强制：不重算重部分
        XCTAssertEqual(stats.scoreTrend, [])
        await stats.recompute(model: model, forceHeavy: true)        // 强制：重算
        XCTAssertEqual(stats.scoreTrend.count, 30)
    }

    // MARK: - Fix round 1, IMPORTANT 6: StatsModel-level delta coverage
    //
    // `testDurationDeltaUsesClippedPreviousButPulseUsesFull` above only
    // exercises the `Aggregator` primitives directly -- it never calls
    // `StatsModel.recompute`, so it can't catch a wiring bug in
    // `recomputeDeltas` itself (e.g. an unclipped `prev` fed into
    // `totalDelta`, or an inverted delta sign). These three tests drive a
    // real in-memory `AppModel` through `StatsModel.recompute` and pin
    // concrete `totalDelta`/`focusDelta`/`pulseDelta` values.

    @MainActor
    private func makeStatsRangeModel() throws -> (AppModel, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let catStore = CategoryStore(db)
        let model = AppModel(categoryStore: catStore, spanStore: store,
                             settings: SettingsStore(db),
                             resolver: CategoryResolver(categoryStore: catStore),
                             engine: TrackerEngine(spanStore: store, settings: SettingsStore(db)))
        return (model, store)
    }

    private func span(_ appBundleID: String, appName: String, start: Date, seconds: TimeInterval) -> Span {
        Span(start: start, end: start.addingTimeInterval(seconds),
             appBundleID: appBundleID, appName: appName, title: nil, url: nil, domain: nil)
    }

    /// `.today()` (the default range) is always `containsNow` by
    /// construction, so this pins the CLIPPED branch: previous-day spans are
    /// clipped to `[yesterdayStart, yesterdayStart + elapsed]` before being
    /// used for `totalDelta`/`focusDelta`, but NOT for `pulseDelta`. Fix
    /// round 2, item 1: placements are derived from `elapsed` -- the actual
    /// elapsed time-of-day measured at test start -- rather than fixed clock
    /// positions (00:01/00:31/23:00), which only held for `now` in
    /// `[00:31, 23:00)` and deterministically failed outside it (in
    /// particular, always between 23:00 and 00:31). The surviving span sits
    /// entirely within the first half of the measured elapsed window, so it
    /// survives even against a strictly-later actual `elapsed` (the
    /// production code re-measures `Date()` at recompute time, which can
    /// only be >= this test's measurement). The clipped-away span starts at
    /// the midpoint between the measured elapsed and midnight, with a
    /// duration of half of whatever room remains after that -- both scale
    /// down automatically as `elapsed` approaches a full day, so the
    /// placement (a) always stays strictly inside yesterday's calendar day
    /// (needed so it still counts toward the FULL previous-day pulse) while
    /// (b) always starting strictly after the measured elapsed (needed to
    /// guarantee the clip drops it, even against that same race) --
    /// analytically true for any `elapsed` in `(0, 86400)`, not just a
    /// fixed-constant margin that can itself overflow past midnight late in
    /// the day. Expected deltas are computed from these same placements, not
    /// hardcoded, so the assertion stays exact.
    @MainActor func testRecomputeDeltasClipPreviousToElapsedTimeOfDayWhenRangeContainsNow() async throws {
        let (model, store) = try makeStatsRangeModel()
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!

        // Current period (today): 1h softwareDev (Xcode, productivity +2),
        // placed a minute after midnight so it's inside today's window
        // regardless of the current time.
        try store.insert(span("com.apple.dt.Xcode", appName: "Xcode",
                               start: todayStart.addingTimeInterval(60), seconds: 3600))

        // Previous period (yesterday): a softwareDev span entirely inside
        // the first half of the elapsed window (survives the elapsed clip)
        // and an entertainment span starting at the midpoint between the
        // elapsed watermark and midnight (dropped by the elapsed clip, but
        // still inside yesterday's calendar day, so it still counts toward
        // the FULL previous-day pulse) -- see the doc comment above.
        // Rounded down to a whole second: `SpanStore` round-trips `Date`
        // through GRDB's millisecond-precision storage, so a span boundary
        // derived from a sub-millisecond-precision `Date()` reading would
        // silently drift by a fraction of a millisecond between what this
        // test computes in-memory and what `stats.recompute` reads back from
        // the store, breaking the exact-equality assertions below. A whole
        // second (and the half/quarter-second fractions the arithmetic below
        // derives from it) is always representable losslessly at that
        // precision.
        let elapsed = Date().timeIntervalSince(todayStart).rounded(.down)
        let survivingSeconds = elapsed / 2
        let clippedAwayStart = elapsed + (86400 - elapsed) / 2
        let clippedAwaySeconds = (86400 - clippedAwayStart) / 2
        try store.insert(span("com.apple.dt.Xcode", appName: "Xcode",
                               start: yesterdayStart, seconds: survivingSeconds))
        try store.insert(span("com.spotify.client", appName: "Spotify",
                               start: yesterdayStart.addingTimeInterval(clippedAwayStart), seconds: clippedAwaySeconds))

        let stats = StatsModel()
        await stats.recompute(model: model, forceHeavy: true)

        XCTAssertEqual(stats.total, 3600)
        XCTAssertEqual(stats.focus, 3600)
        XCTAssertEqual(stats.pulse, 100)

        // Duration deltas: current (1h) minus the CLIPPED previous (only the
        // surviving softwareDev span), computed exactly from its placement.
        XCTAssertEqual(stats.totalDelta, 3600 - survivingSeconds)
        XCTAssertEqual(stats.focusDelta, 3600 - survivingSeconds)
        // Pulse delta: current (100) minus the UNCLIPPED previous full-day
        // pulse (survivingSeconds softwareDev @100 + clippedAwaySeconds
        // entertainment @0, duration-weighted).
        let prevFullPulse = Int(((survivingSeconds * 100) / (survivingSeconds + clippedAwaySeconds)).rounded())
        XCTAssertEqual(stats.pulseDelta, 100 - prevFullPulse)
    }

    /// A historical (never `containsNow`) day range, so this test has no
    /// wall-clock dependency at all: pins the UNCLIPPED branch, where
    /// duration deltas compare against the full previous day.
    @MainActor func testRecomputeDeltasUseFullPreviousPeriodWhenRangeDoesNotContainNow() async throws {
        let (model, store) = try makeStatsRangeModel()
        let cal = Calendar.current
        let currentDayStart = cal.startOfDay(for: Date().addingTimeInterval(-10 * 86400))
        let previousDayStart = cal.date(byAdding: .day, value: -1, to: currentDayStart)!

        try store.insert(span("com.apple.dt.Xcode", appName: "Xcode",
                               start: currentDayStart.addingTimeInterval(9 * 3600), seconds: 3 * 3600))
        try store.insert(span("com.spotify.client", appName: "Spotify",
                               start: previousDayStart.addingTimeInterval(8 * 3600), seconds: 3600))

        model.range = DateRangeSelection(kind: .day, anchor: currentDayStart.addingTimeInterval(12 * 3600))
        XCTAssertFalse(model.range.containsNow)

        let stats = StatsModel()
        await stats.recompute(model: model, forceHeavy: true)

        XCTAssertEqual(stats.total, 3 * 3600)
        XCTAssertEqual(stats.focus, 3 * 3600)
        XCTAssertEqual(stats.pulse, 100)

        XCTAssertEqual(stats.totalDelta, 2 * 3600)   // 3h - 1h
        XCTAssertEqual(stats.focusDelta, 3 * 3600)   // 3h - 0 (entertainment isn't focus time)
        XCTAssertEqual(stats.pulseDelta, 100)        // 100 - 0
    }

    @MainActor func testRecomputeDeltasAreNilWhenPreviousPeriodIsEmpty() async throws {
        let (model, store) = try makeStatsRangeModel()
        let todayStart = Calendar.current.startOfDay(for: Date())
        try store.insert(span("com.apple.dt.Xcode", appName: "Xcode",
                               start: todayStart.addingTimeInterval(60), seconds: 3600))
        // No spans inserted for yesterday -- `prev` is empty.

        let stats = StatsModel()
        await stats.recompute(model: model, forceHeavy: true)

        XCTAssertNil(stats.totalDelta)
        XCTAssertNil(stats.focusDelta)
        XCTAssertNil(stats.pulseDelta)
    }
}
