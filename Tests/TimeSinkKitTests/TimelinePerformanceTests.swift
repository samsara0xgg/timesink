import XCTest
import AppKit
import SwiftUI
import GRDB
@testable import TimeSinkKit

/// Opt-in, read-only profiling of the day timelines against a copy of a real
/// database. Set TIMESINK_PERF_DB (and optionally TIMESINK_PERF_DAY as
/// yyyy-MM-dd, default yesterday). Never starts the tracker or writes.
final class TimelinePerformanceTests: XCTestCase {
    @MainActor
    func testLocalTimelineCost() throws {
        guard let path = ProcessInfo.processInfo.environment["TIMESINK_PERF_DB"] else {
            throw XCTSkip("Set TIMESINK_PERF_DB to profile a read-only database")
        }
        var configuration = Configuration()
        configuration.readonly = true
        let db = try DatabasePool(path: path, configuration: configuration)
        let store = SpanStore(db)
        let categories = CategoryStore(db)
        let settings = SettingsStore(db)
        let model = AppModel(categoryStore: categories, spanStore: store, settings: settings,
                             resolver: CategoryResolver(categoryStore: categories),
                             engine: TrackerEngine(spanStore: store, settings: settings))
        let calendar = Calendar.current
        let day: Date = {
            if let text = ProcessInfo.processInfo.environment["TIMESINK_PERF_DAY"] {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                if let date = formatter.date(from: text) { return calendar.startOfDay(for: date) }
            }
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
        }()
        let range = DateRangeSelection(kind: .day, anchor: day)
        _ = NSApplication.shared

        var start = CFAbsoluteTimeGetCurrent()
        let items = model.rangedSpans(for: range)
        report("day_fetch_classify", since: start)
        print("PERF day_spans=\(items.count)")

        model.range = range
        let activities = ActivitiesModel()
        start = CFAbsoluteTimeGetCurrent()
        activities.recompute(model: model)
        report("activities_recompute", since: start)
        print("PERF timeline_blocks=\(activities.timelineBlocks.count)")
        let byStop = TimelineZoom.stops.map { stop in
            "\(Int(stop)):\(ActivitiesModel.timelineBlocks(items, categories: model.resolver.categoriesByID, resolution: TimelineZoom.resolution(for: stop)).count)"
        }
        print("PERF timeline_blocks_by_stop=\(byStop.joined(separator: ","))")

        let now = day.addingTimeInterval(86399)
        start = CFAbsoluteTimeGetCurrent()
        let overview = DayOverview(items: items, categories: model.resolver.categoriesByID, sessions: [], now: now)
        report("day_overview", since: start)
        print("PERF list_pieces=\(overview.pieces.count) gaps=\(overview.pieces.filter { $0.item == nil }.count)")
        let hours = max(overview.displayInterval.duration / 3600, 1)
        for (label, points, width) in [("compact", 3.0, 312.0), ("full", 4.0, 1100.0)] {
            let pieces = DayOverview.pieces(overview.items, resolution: TimelineSegmenter.resolution(points: points, pointsPerHour: width / hours), grouping: .category)
            print("PERF ribbon_\(label)_pieces=\(pieces.count) gaps=\(pieces.filter { $0.item == nil }.count)")
        }

        var hourHeight: CGFloat = 64
        let timeline = DayTimelineView(day: day, blocks: activities.timelineBlocks,
                                       hourHeight: Binding(get: { hourHeight }, set: { hourHeight = $0 }), onSelect: { _ in })
        render("timeline_render", timeline, size: NSSize(width: 230, height: 820))
        render("ribbon_compact_render", DayRibbonView(overview: overview, compact: true), size: NSSize(width: 312, height: 40))
        render("ribbon_full_render", DayRibbonView(overview: overview), size: NSSize(width: 1100, height: 100))
        render("menu_popover_render", MenuBarDashboardView(model: model), size: NSSize(width: 340, height: 760))

        // The badge is counted on a worker; the main actor only reads it.
        start = CFAbsoluteTimeGetCurrent()
        _ = model.pendingClassificationCount
        report("sidebar_badge_main", since: start)
        start = CFAbsoluteTimeGetCurrent()
        model.dataChanged()
        report("data_changed_main", since: start)
    }

    @MainActor
    private func render<V: View>(_ label: String, _ view: V, size: NSSize) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        report(label, since: start)
    }

    private func report(_ label: String, since start: Double) {
        print(String(format: "PERF %@_ms=%.2f", label, (CFAbsoluteTimeGetCurrent() - start) * 1000))
    }
}
