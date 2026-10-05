import XCTest
import AppKit
import SwiftUI
import GRDB
@testable import TimeSinkKit

/// Opt-in, read-only: the Activities list over a month of a real database
/// copy (TIMESINK_PERF_DB), hosted in a window that is never ordered in.
/// Prints how many rows each interaction builds and how long the main
/// thread takes per scroll step. Never starts the tracker or writes.
final class ActivitiesScrollPerfTests: XCTestCase {
    @MainActor
    func testListScrollAndSelect() async throws {
        guard let path = ProcessInfo.processInfo.environment["TIMESINK_PERF_DB"] else {
            throw XCTSkip("Set TIMESINK_PERF_DB to profile a read-only database")
        }
        let model = try PerfReview.realModel(path: path)
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        model.sidebarSelection = .activities
        model.range = DateRangeSelection(kind: .last30, anchor: Date())
        let activities = ActivitiesModel()
        let size = NSSize(width: 1460, height: 880)
        let controller = NSHostingController(rootView: MainWindowView(model: model, activities: activities)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, .light)
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        defer { window.close() }

        do {
            let interval = DateRangeSelection(kind: .last30, anchor: Date()).interval
            let fresh = try PerfReview.realModel(path: path)
            var t = CFAbsoluteTimeGetCurrent()
            let raw = try fresh.spanStore.spans(overlapping: interval)
            let readMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
            t = CFAbsoluteTimeGetCurrent()
            let categorized = fresh.resolver.categorized(raw)
            let classifyMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
            let probe = ActivitiesModel()
            fresh.range = DateRangeSelection(kind: .last30, anchor: Date())
            _ = fresh.rangedSpans()
            t = CFAbsoluteTimeGetCurrent()
            probe.recompute(model: fresh, events: [])
            let recomputeMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
            print(String(format: "PERF month_load spans=%d dbRead=%.0f classify=%.0f recomputeWarm=%.0f ms", categorized.count, readMs, classifyMs, recomputeMs))
        }
        let monitor = PerfReview.Monitor()
        func spin(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func settle() async {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            await spin(0.6)
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        func listScroller() -> NSScrollView? {
            guard let content = window.contentView else { return nil }
            return scrollViews(content).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        }
        /// Rows built and main-thread milliseconds while `change` settles.
        func measure(_ label: String, _ change: () -> Void) async {
            let rows0 = ActivityListProbe.rows, bodies0 = ActivityListProbe.bodies
            monitor.passes.removeAll()
            let t0 = CACurrentMediaTime()
            change()
            await settle()
            let busy = monitor.passes.filter { $0.end >= t0 }.map(\.ms)
            print(String(format: "PERF %@ rows=%d listBodies=%d longestPass=%.1f ms totalPassMs=%.1f", label,
                         ActivityListProbe.rows - rows0, ActivityListProbe.bodies - bodies0, busy.max() ?? 0, busy.reduce(0, +)))
        }
        func sweep(_ label: String) async {
            guard let scroller = listScroller(), let document = scroller.documentView else { print("PERF \(label) no scroller"); return }
            let travel = max(0, document.frame.height - scroller.contentView.bounds.height)
            let rows0 = ActivityListProbe.rows
            monitor.passes.removeAll()
            let t0 = CACurrentMediaTime()
            let steps = 60
            var heights: [Int] = [Int(document.frame.height)]
            for step in 0...steps {
                scroller.contentView.scroll(to: NSPoint(x: 0, y: min(travel, 4000) * Double(step) / Double(steps)))
                scroller.reflectScrolledClipView(scroller.contentView)
                window.contentView?.layoutSubtreeIfNeeded()
                window.contentView?.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(8))
                if step % 10 == 0 { heights.append(Int(document.frame.height)) }
            }
            print("PERF \(label) docHeights \(heights)")
            let passes = monitor.passes.filter { $0.end >= t0 }.map(\.ms).sorted()
            let p95 = passes.isEmpty ? 0 : passes[min(passes.count - 1, Int(Double(passes.count) * 0.95))]
            print(String(format: "PERF %@ docHeight=%.0f steps=%d rowsBuilt=%d passes=%d median=%.1f p95=%.1f longest=%.1f drops=%d", label,
                         document.frame.height, steps, ActivityListProbe.rows - rows0, passes.count,
                         passes.isEmpty ? 0 : passes[passes.count / 2], p95, passes.last ?? 0, passes.filter { $0 > 16.7 }.count))
            scroller.contentView.scroll(to: .zero)
            scroller.reflectScrolledClipView(scroller.contentView)
        }

        await spin(2.5)
        await settle()
        await settle()
        let groupRows = activities.groups.reduce(0) { $0 + $1.rows.count }
        print("PERF data spans=\(model.rangedSpans().count) categories=\(activities.groups.count) activityRows=\(groupRows) timeRows=\(activities.timeRows.count) appGroups=\(activities.appGroups.count)")

        func shot(_ name: String) {
            guard let dir = ProcessInfo.processInfo.environment["TIMESINK_PERF_SHOTS"], let view = window.contentView else { return }
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
        func jump(_ label: String, to fraction: Double) async {
            guard let scroller = listScroller(), let document = scroller.documentView else { return }
            let travel = max(0, document.frame.height - scroller.contentView.bounds.height)
            scroller.contentView.scroll(to: NSPoint(x: 0, y: travel * fraction))
            scroller.reflectScrolledClipView(scroller.contentView)
            await settle()
            print("PERF \(label) frac=\(fraction) y=\(Int(scroller.contentView.bounds.origin.y)) doc=\(Int(document.frame.height)) viewport=\(Int(scroller.contentView.bounds.height))")
            shot("\(label)-\(Int(fraction * 100))")
        }
        do {
            let all = model.rangedSpans()
            guard let selection = activities.groups.first?.rows.first.map({ ActivitySelection(categoryID: activities.groups[0].id, rowID: $0.id) }) else { return }
            var t = CFAbsoluteTimeGetCurrent()
            let cheap = all.filter { $0.categoryID == selection.categoryID && selection.matches(ActivitiesModel.selection(for: $0)) }.count
            print(String(format: "PERF inspector_rowTotal_scan_prefiltered matched=%d ms=%.1f", cheap, (CFAbsoluteTimeGetCurrent() - t) * 1000))
            t = CFAbsoluteTimeGetCurrent()
            let total = all.filter { selection.matches(ActivitiesModel.selection(for: $0)) }.count
            print(String(format: "PERF inspector_rowTotal_scan spans=%d matched=%d ms=%.1f", all.count, total, (CFAbsoluteTimeGetCurrent() - t) * 1000))
            t = CFAbsoluteTimeGetCurrent()
            let first = all.first { selection.matches(ActivitiesModel.selection(for: $0)) }
            print(String(format: "PERF inspector_first_scan found=%d ms=%.1f", first == nil ? 0 : 1, (CFAbsoluteTimeGetCurrent() - t) * 1000))
            if let first {
                t = CFAbsoluteTimeGetCurrent()
                let caps = (try? model.observationStore?.captures(overlapping: DateInterval(start: first.span.start, end: first.span.end))) ?? []
                print(String(format: "PERF inspector_captures_query n=%d ms=%.1f", caps.count, (CFAbsoluteTimeGetCurrent() - t) * 1000))
            }
        }
        for grouping in [0, 1, 2] {
            await measure("g\(grouping)_switch") { activities.grouping = grouping }
            shot("g\(grouping)-top")
            await sweep("g\(grouping)_scroll")
            await jump("g\(grouping)", to: 0.5)
            await jump("g\(grouping)", to: 1)
            await jump("g\(grouping)", to: 0)
            await sweep("g\(grouping)_scroll_again")
            let visible: [ActivitySelection] = switch grouping {
            case 0: (activities.groups.first?.rows.prefix(8) ?? []).map { ActivitySelection(categoryID: activities.groups[0].id, rowID: $0.id) }
            case 1: activities.appGroups.prefix(6).compactMap { $0.rows.first?.selection }
            default: activities.timeRows.prefix(8).map { $0.dominant.selection }
            }
            let far: ActivitySelection? = switch grouping {
            case 0: activities.groups.dropFirst(5).first?.rows.first.map { ActivitySelection(categoryID: activities.groups[5].id, rowID: $0.id) }
            case 1: activities.appGroups.dropFirst(60).first?.rows.first?.selection
            default: activities.timeRows.dropFirst(900).first.map { $0.dominant.selection }
            }
            for (index, selection) in visible.prefix(3).enumerated() {
                await measure("g\(grouping)_select_visible_\(index)") { activities.select(selection) }
            }
            if let far {
                await measure("g\(grouping)_select_far") { activities.select(far) }
                print("PERF g\(grouping)_select_far scrolledTo y=\(Int(listScroller()?.contentView.bounds.origin.y ?? -1)) (0 means scrollTo did not move)")
            }
            await jump("g\(grouping)-after-far", to: 0)
        }
        if let id = activities.groups.first?.id {
            activities.grouping = 0
            await settle()
            await measure("collapse_first_category") { activities.collapsedCategories.insert(id) }
        }

        // The busiest recent day as sessions and as the detailed timeline.
        var day = DateRangeSelection(kind: .day, anchor: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1))!)
        day.firstWeekday = model.firstWeekday
        await measure("day_switch") { model.range = day }
        await spin(1.5)
        await settle()
        print("PERF day spans=\(model.rangedSpans().count) blocks=\(activities.timelineBlocks.count) sessions=\(activities.sessions.count)")
        await sweep("day_sessions_scroll")
        await measure("day_to_timeline") { activities.mode = .timeline }
        await settle()
        await sweep("day_timeline_scroll")
        if let block = activities.timelineBlocks.filter(\.matchesFilter).dropFirst(20).first, let activity = block.activity {
            await measure("day_timeline_select") { activities.select(activity, start: block.start) }
            await measure("day_timeline_select_again") { activities.select(activity, start: block.start) }
        }
        for stop in TimelineZoom.stops {
            await measure("day_timeline_zoom_\(Int(stop))") { activities.timelineHourHeight = stop }
            await sweep("day_timeline_scroll_zoom_\(Int(stop))")
        }
    }
}
