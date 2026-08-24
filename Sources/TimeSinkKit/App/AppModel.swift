import Foundation
import Observation
import os

/// Top-level sidebar destination.
public enum SidebarItem: Hashable {
    case stats, activities
}

/// App-wide observable state: the shared stores/engine, the current date-range
/// selection, and the menu bar's live summary text. Views read `range`,
/// `sidebarSelection`, `activityFilter` directly (tracked by `@Observable`);
/// `dataVersion` is bumped on every engine write so views that cache derived
/// data (e.g. per-category totals) know to re-query via
/// `.onChange(of: model.dataVersion)`.
@MainActor
@Observable
public final class AppModel {
    public let categoryStore: CategoryStore
    public let spanStore: SpanStore
    public let settings: SettingsStore
    public let resolver: CategoryResolver
    public let engine: TrackerEngine

    public var range: DateRangeSelection = .today()
    public var sidebarSelection: SidebarItem = .stats
    public var activityFilter: String?

    /// Bumped on every `dataChanged()`; views observe this to know when to
    /// re-run range/category queries.
    public var dataVersion: Int = 0

    /// Menu bar icon label: today's focus time, kept in sync by `refreshMenu()`.
    public var menuTitle: String = "0m"
    /// Today's total tracked duration, for the menu bar dropdown.
    public var todayTotalTitle: String = "0m"
    /// Today's productivity score (0-100), for the menu bar dropdown. "--" if no data yet.
    public var todayPulseTitle: String = "--"

    private let logger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "appModel")

    /// Memoizes categorized fetches between `dataChanged()` bumps. Three
    /// consumers (StatsModel, ActivitiesModel, refreshMenu) re-query on every
    /// dataVersion change with overlapping ranges; without this each bump
    /// costs up to 4 identical full fetch+classify passes on the main actor.
    private var rangeCache: [String: [CategorizedSpan]] = [:]

    /// Trailing debounce for `scheduleEngineDataChanged()` -- see its doc
    /// comment.
    private static let engineChangeDebounce: Duration = .seconds(1.5)
    private var pendingEngineRefresh: Task<Void, Never>?

    public init(
        categoryStore: CategoryStore,
        spanStore: SpanStore,
        settings: SettingsStore,
        resolver: CategoryResolver,
        engine: TrackerEngine
    ) {
        self.categoryStore = categoryStore
        self.spanStore = spanStore
        self.settings = settings
        self.resolver = resolver
        self.engine = engine
        refreshMenu()
        // refreshMenu() just seeded rangeCache with a "today" snapshot taken
        // before any caller-visible dataChanged() boundary; drop it so the
        // first real query after construction always re-reads the store
        // rather than serving that bootstrap-time snapshot indefinitely.
        rangeCache.removeAll()
        engine.onChange = { [weak self] in self?.scheduleEngineDataChanged() }
    }

    /// Spans in the current `range`, clipped to it, and categorized.
    public func rangedSpans() -> [CategorizedSpan] {
        rangedSpans(for: range)
    }

    public func todayFocusText() -> String {
        let items = rangedSpans(for: .today())
        let byCategory = Aggregator.durationByCategory(items)
        let focus = Aggregator.focusTime(durationByCategory: byCategory, categories: resolver.categoriesByID)
        return Format.duration(focus)
    }

    public func refreshMenu() {
        let items = rangedSpans(for: .today())
        let byCategory = Aggregator.durationByCategory(items)
        let focus = Aggregator.focusTime(durationByCategory: byCategory, categories: resolver.categoriesByID)
        menuTitle = Format.duration(focus)
        todayTotalTitle = Format.duration(Aggregator.totalDuration(items.map(\.span)))
        if let pulse = Aggregator.pulse(durationByCategory: byCategory, categories: resolver.categoriesByID) {
            todayPulseTitle = "\(pulse)"
        } else {
            todayPulseTitle = "--"
        }
    }

    public func dataChanged() {
        rangeCache.removeAll()
        refreshMenu()
        dataVersion += 1
    }

    /// Debounced entry point wired ONLY to `engine.onChange` -- every span
    /// insert/update while live tracking is running. Every live view
    /// responds to `dataVersion` with a full `rangedSpans()` + aggregation
    /// recompute on the main actor, so with months of data at a wide range,
    /// rapid app switching (many writes in quick succession) would visibly
    /// hitch the UI if each one ran `dataChanged()` immediately. This
    /// coalesces bursts behind a short trailing delay. Explicit user
    /// actions (reassignment, settings edits) call `dataChanged()` directly
    /// elsewhere and must stay immediate -- do not route them through here.
    private func scheduleEngineDataChanged() {
        pendingEngineRefresh?.cancel()
        pendingEngineRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.engineChangeDebounce)
            guard !Task.isCancelled else { return }
            self?.dataChanged()
        }
    }

    /// `spanStore.spans(overlapping:)`, each span clipped to the interval's
    /// intersection, then categorized. Result is memoized per interval in
    /// `rangeCache` until the next `dataChanged()`. DB errors are logged and
    /// yield [] (not cached, so a transient failure doesn't stick).
    public func rangedSpans(for range: DateRangeSelection) -> [CategorizedSpan] {
        let interval = range.interval
        let key = "\(interval.start.timeIntervalSinceReferenceDate)-\(interval.end.timeIntervalSinceReferenceDate)"
        if let cached = rangeCache[key] { return cached }
        do {
            let spans = try spanStore.spans(overlapping: interval)
            let clipped = spans.map { span -> Span in
                var s = span
                s.start = max(s.start, interval.start)
                s.end = min(s.end, interval.end)
                return s
            }
            let result = resolver.categorized(clipped)
            rangeCache[key] = result
            return result
        } catch {
            logger.error("rangedSpans failed: \(String(describing: error))")
            return []
        }
    }
}
