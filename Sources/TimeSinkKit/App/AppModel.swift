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
        engine.onChange = { [weak self] in self?.dataChanged() }
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
        refreshMenu()
        dataVersion += 1
    }

    /// `spanStore.spans(overlapping:)`, each span clipped to the interval's
    /// intersection, then categorized. DB errors are logged and yield [].
    private func rangedSpans(for range: DateRangeSelection) -> [CategorizedSpan] {
        let interval = range.interval
        do {
            let spans = try spanStore.spans(overlapping: interval)
            let clipped = spans.map { span -> Span in
                var s = span
                s.start = max(s.start, interval.start)
                s.end = min(s.end, interval.end)
                return s
            }
            return resolver.categorized(clipped)
        } catch {
            logger.error("rangedSpans failed: \(String(describing: error))")
            return []
        }
    }
}
