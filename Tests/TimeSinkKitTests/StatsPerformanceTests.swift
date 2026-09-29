import XCTest
import AppKit
import SwiftUI
import GRDB
@testable import TimeSinkKit

/// Opt-in, read-only local profiling. Never starts the tracker or exports records.
final class StatsPerformanceTests: XCTestCase {
    @MainActor
    func testLocalMenuLatency() async throws {
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
        let dashboard = TodayDashboardModel()
        var gaps: [Double] = []
        var previous = CFAbsoluteTimeGetCurrent()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
                let now = CFAbsoluteTimeGetCurrent()
                gaps.append((now - previous) * 1000)
                previous = now
            }
        }
        await Task.yield()
        var start = CFAbsoluteTimeGetCurrent()
        await dashboard.recompute(model: model, forceStreak: true)
        report("cold_menu", since: start)
        heartbeat.cancel()
        await heartbeat.value
        print(String(format: "PERF menu_main_actor_max_gap_ms=%.2f samples=%d", gaps.max() ?? 0, gaps.count))
        XCTAssertFalse(gaps.isEmpty)
        start = CFAbsoluteTimeGetCurrent()
        await dashboard.recompute(model: model, forceStreak: true)
        report("warm_menu", since: start)
        start = CFAbsoluteTimeGetCurrent()
        await dashboard.recompute(model: model, forceStreak: false)
        report("cached_menu", since: start)
    }

    @MainActor
    func testLocalStatsLatency() async throws {
        guard let path = ProcessInfo.processInfo.environment["TIMESINK_PERF_DB"] else {
            throw XCTSkip("Set TIMESINK_PERF_DB to profile a read-only database")
        }
        var configuration = Configuration()
        configuration.readonly = true
        let db = try DatabasePool(path: path, configuration: configuration)
        let store = SpanStore(db)
        let categoryStore = CategoryStore(db)
        let settings = SettingsStore(db)
        let resolver = CategoryResolver(categoryStore: categoryStore)
        let model = AppModel(categoryStore: categoryStore, spanStore: store, settings: settings,
                             resolver: resolver, engine: TrackerEngine(spanStore: store, settings: settings))
        let stats = StatsModel()
        var mainActorGaps: [Double] = []
        var previous = CFAbsoluteTimeGetCurrent()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { break }
                let now = CFAbsoluteTimeGetCurrent()
                mainActorGaps.append((now - previous) * 1000)
                previous = now
            }
        }
        await Task.yield()
        var start = CFAbsoluteTimeGetCurrent()
        await stats.recompute(model: model, forceHeavy: true)
        report("cold_stats", since: start)
        heartbeat.cancel()
        await heartbeat.value
        print(String(format: "PERF cold_main_actor_max_gap_ms=%.2f samples=%d", mainActorGaps.max() ?? 0, mainActorGaps.count))
        XCTAssertFalse(mainActorGaps.isEmpty, "The main actor must remain available during cold aggregation")
        for _ in 0..<3 {
            start = CFAbsoluteTimeGetCurrent()
            await stats.recompute(model: model, forceHeavy: true)
            report("warm_forced_stats", since: start)
            start = CFAbsoluteTimeGetCurrent()
            await stats.recompute(model: model, forceHeavy: false)
            report("warm_cached_stats", since: start)
        }
        let lookback = model.rangedSpans(for: DateRangeSelection(kind: .last30, anchor: Date()))
        print("PERF rows_30d=\(lookback.count)")
        let data = try XCTUnwrap(stats.heatmapData)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: HeatmapCard(data: data, interaction: Binding(
            get: { stats.heatmapInteraction }, set: { stats.heatmapInteraction = $0 }), onOpenDay: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 780, height: 620)
        start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        report("heatmap_first_layout", since: start)
        // Force layout after each state change; no mouse synthesis or personal screenshots.
        var times: [Double] = []
        for index in 0..<48 {
            start = CFAbsoluteTimeGetCurrent()
            stats.heatmapInteraction.hovered = .init(weekday: index % 7, hour: index % 24)
            host.layoutSubtreeIfNeeded()
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        times.sort()
        print(String(format: "PERF heatmap_updates_median_ms=%.2f p95_ms=%.2f", times[times.count / 2], times[Int(Double(times.count) * 0.95)]))
        let mainHost = NSHostingView(rootView: MainWindowView(model: model))
        mainHost.frame = NSRect(x: 0, y: 0, width: 1040, height: 740)
        start = CFAbsoluteTimeGetCurrent()
        mainHost.layoutSubtreeIfNeeded()
        report("main_window_first_layout", since: start)
    }

    private func report(_ label: String, since start: Double) {
        print(String(format: "PERF %@_ms=%.2f", label, (CFAbsoluteTimeGetCurrent() - start) * 1000))
    }
}
