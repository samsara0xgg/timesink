import XCTest
import AppKit
import SwiftUI
import GRDB
@testable import TimeSinkKit

/// A stable digest of everything `recompute` publishes, so two paths (or two
/// builds) can be compared by one line of output.
@MainActor enum ActivitiesFingerprint {
    static func text(_ a: ActivitiesModel) -> String {
        var out = ["count=\(a.rangeCount.map(String.init) ?? "nil")", "range=\(Int(a.rangeSeconds))", "shown=\(Int(a.shownSeconds))",
                   "match=\(a.matchCount.map(String.init) ?? "nil")", "matchSec=\(a.matchSeconds.map { String(Int($0)) } ?? "nil")",
                   "meeting=\(Int(a.meetingSeconds))", "meetingIDs=\(a.meetingSpanIDs.sorted())",
                   "displayed=\(a.displayedItems.count)"]
        for g in a.groups {
            out.append("G \(g.id) \(g.name) \(g.colorHex) \(Int(g.seconds))")
            for r in g.rows {
                out.append("R \(r.id) \(r.label) \(Int(r.seconds)) \(r.isDomain) \(r.reassignKey) \(r.isEntity) \(r.hasMeeting)")
                for t in r.titles { out.append("T \(t.title) \(Int(t.seconds))") }
            }
        }
        for (key, value) in a.segmentCounts.sorted(by: { "\($0.key)" < "\($1.key)" }) { out.append("S \(key) \(value)") }
        for b in a.timelineBlocks {
            out.append("B \(b.id) \(b.start.timeIntervalSince1970) \(b.end.timeIntervalSince1970) \(b.label) \(b.matchesFilter) \(b.isHighlight) \(b.ticks.count) \(b.mix.count) \(b.tooltip)")
        }
        for b in a.focusBlocks { out.append("F \(b.id) \(b.start.timeIntervalSince1970) \(b.end.timeIntervalSince1970)") }
        for b in a.calendarBlocks { out.append("C \(b.id) \(b.title)") }
        out.append("allDay=\(a.allDayTitles)")
        for n in a.awayNotes { out.append("A \(n.start.timeIntervalSince1970) \(n.end.timeIntervalSince1970)") }
        out.append("selA=\(String(describing: a.selectedActivity)) selStart=\(String(describing: a.selectedStart?.timeIntervalSince1970))")
        return out.joined(separator: "\n")
    }

    /// FNV-1a over the text; stable across runs, unlike `Hasher`.
    static func digest(_ a: ActivitiesModel) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text(a).utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}

/// Opt-in, read-only (TIMESINK_PERF_DB = a COPY of the real database): what
/// the main thread does while the Activities page loads a month, and how the
/// day timeline behaves at its highest zoom. Prints timings and digests only.
@MainActor
final class ActivitiesLoadPerfTests: XCTestCase {
    @MainActor private struct Host {
        let model: AppModel
        let activities: ActivitiesModel
        let window: NSWindow
        let monitor = PerfReview.Monitor()

        init(path: String, page: SidebarItem, range: DateRangeSelection) throws {
            model = try PerfReview.realModel(path: path)
            _ = NSApplication.shared
            NSApp.appearance = NSAppearance(named: .aqua)
            model.sidebarSelection = page
            model.range = range
            activities = ActivitiesModel()
            let size = NSSize(width: 1460, height: 880)
            let controller = NSHostingController(rootView: MainWindowView(model: model, activities: activities)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.colorScheme, .light)
                .frame(width: size.width, height: size.height))
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.contentViewController = controller
            window.isReleasedWhenClosed = false
            window.setContentSize(size)
        }

        func settle(_ seconds: Double = 0.4) async {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            try? await Task.sleep(for: .seconds(seconds))
        }

        var isLoaded: Bool { activities.rangeCount != nil && activities.shownRange?.window == model.range.window }

        /// From the change until the page shows the new range: main-thread
        /// passes (a pass longer than 16.7 ms is a dropped frame) and the wait.
        @discardableResult
        func measure(_ label: String, timeout: Double = 30, until: (() -> Bool)? = nil, _ change: () -> Void) async -> Double {
            monitor.passes.removeAll()
            let t0 = CACurrentMediaTime()
            change()
            var toContent = -1.0
            while CACurrentMediaTime() - t0 < timeout {
                try? await Task.sleep(for: .milliseconds(4))
                if until?() ?? isLoaded { toContent = (CACurrentMediaTime() - t0) * 1000; break }
            }
            await settle(0.5)
            let passes = monitor.passes.filter { $0.end >= t0 }.map(\.ms)
            let (longest, drops, total) = (passes.max() ?? 0, passes.filter { $0 > 16.7 }.count, passes.reduce(0, +))
            print(String(format: "PERF load %@ toContent=%.0f longestPass=%.1f drops=%d totalPassMs=%.0f digest=%@", label, toContent,
                         longest, drops, total, ActivitiesFingerprint.digest(activities)))
            // The digest is a long pass of its own; let it end before the next measurement starts.
            await settle(0.3)
            return toContent
        }
    }

    private func perfDB() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["TIMESINK_PERF_DB"] else {
            throw XCTSkip("Set TIMESINK_PERF_DB to profile a read-only database")
        }
        return path
    }

    /// Entering the page, then changing the range and the filters, on a month
    /// of real data.
    func testRangeChangeLoad() async throws {
        let path = try perfDB()
        let host = try Host(path: path, page: .today, range: DateRangeSelection(kind: .last30, anchor: Date()))
        defer { host.window.close() }
        await host.settle(1.0)
        await host.measure("enter_activities_last30") { host.model.sidebarSelection = .activities }
        print("PERF load spans=\(host.model.rangedSpans().count) groups=\(host.activities.groups.count)")
        await host.measure("range_last7") { host.model.range = DateRangeSelection(kind: .last7, anchor: Date()) }
        await host.measure("range_last30_again") { host.model.range = DateRangeSelection(kind: .last30, anchor: Date()) }
        let now = Date()
        await host.measure("range_custom60") {
            host.model.range = DateRangeSelection(kind: .custom, anchor: now, customStart: now.addingTimeInterval(-60 * 86400), customEnd: now)
        }
        await host.measure("range_last30_third") { host.model.range = DateRangeSelection(kind: .last30, anchor: Date()) }
        // The shown range stays; the content is replaced when the new rows are ready.
        let a = host.activities
        if let id = a.groups.first?.id {
            var before = a.displayedItems.count
            await host.measure("filter_first_category", until: { a.displayedItems.count != before }) { host.model.activityFilter = id }
            before = a.displayedItems.count
            await host.measure("filter_clear", until: { a.displayedItems.count != before }) { host.model.activityFilter = nil }
        }
        let before = a.displayedItems.count
        await host.measure("search_safari", until: { a.displayedItems.count != before }) { host.model.activitySearch = "safari" }
        await host.measure("search_clear", until: { a.displayedItems.count == before }) { host.model.activitySearch = "" }
        // A tracker write or an edit: the range is read again.
        await host.measure("data_changed_same_range", timeout: 3, until: { false }) { host.model.dataChanged() }
    }

    /// The off-main load against the synchronous recompute, on a month of real
    /// data (two separate models, so both start from cold caches).
    func testOffMainMatchesSynchronousOnRealData() async throws {
        let path = try perfDB()
        let monitor = PerfReview.Monitor()
        for (label, search, filtered) in [("plain", "", false), ("search", "safari", false), ("category", "", true)] {
            let (syncModel, offModel) = (try PerfReview.realModel(path: path), try PerfReview.realModel(path: path))
            for model in [syncModel, offModel] {
                model.range = DateRangeSelection(kind: .last30, anchor: Date())
                model.activitySearch = search
            }
            if filtered {
                let probe = ActivitiesModel()
                let unfiltered = try PerfReview.realModel(path: path)
                unfiltered.range = syncModel.range
                probe.recompute(model: unfiltered)
                for model in [syncModel, offModel] { model.activityFilter = probe.groups.first?.id }
            }
            let sync = ActivitiesModel(), off = ActivitiesModel()
            var t = CFAbsoluteTimeGetCurrent()
            sync.recompute(model: syncModel)
            let syncMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
            try? await Task.sleep(for: .milliseconds(200))  // let that long pass end before measuring
            monitor.passes.removeAll()
            t = CACurrentMediaTime()
            off.reload(model: offModel)
            await off.loadTask?.value
            let offMs = (CACurrentMediaTime() - t) * 1000
            let blocked = monitor.passes.filter { $0.end >= t }.map(\.ms).max() ?? 0
            let identical = ActivitiesFingerprint.text(off) == ActivitiesFingerprint.text(sync)
            XCTAssertTrue(identical)
            print(String(format: "PERF parity %@ spans=%d shown=%d groups=%d identical=%d syncColdMs=%.0f offMainTotalMs=%.0f offMainLongestPass=%.1f digest=%@", label,
                         sync.rangeCount ?? 0, sync.displayedItems.count, sync.groups.count, identical ? 1 : 0, syncMs, offMs, blocked,
                         ActivitiesFingerprint.digest(sync)))
        }
    }

    /// The busiest recent day as the detailed timeline, at every zoom stop.
    func testTimelineZoom() async throws {
        let path = try perfDB()
        var day = DateRangeSelection(kind: .day, anchor: Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1))!)
        let host = try Host(path: path, page: .activities, range: .today())
        defer { host.window.close() }
        day.firstWeekday = host.model.firstWeekday
        await host.settle(1.0)
        await host.measure("day_switch") { host.model.range = day }
        host.activities.mode = .timeline
        await host.settle(1.0)
        print("PERF zoom day spans=\(host.model.rangedSpans().count) sessions=\(host.activities.sessions.count)")

        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        func scroller() -> NSScrollView? {
            host.window.contentView.flatMap { scrollViews($0).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) } }
        }
        func sweep(_ label: String) async {
            guard let scroller = scroller(), let document = scroller.documentView else { print("PERF zoom \(label) no scroller"); return }
            let travel = max(0, document.frame.height - scroller.contentView.bounds.height)
            host.monitor.passes.removeAll()
            let t0 = CACurrentMediaTime()
            let steps = 66
            for step in 0...steps {
                scroller.contentView.scroll(to: NSPoint(x: 0, y: travel * Double(step) / Double(steps)))
                scroller.reflectScrolledClipView(scroller.contentView)
                host.window.contentView?.layoutSubtreeIfNeeded()
                host.window.contentView?.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(8))
            }
            let passes = host.monitor.passes.filter { $0.end >= t0 }.map(\.ms).sorted()
            print(String(format: "PERF zoom %@ doc=%.0f passes=%d median=%.1f p95=%.1f longest=%.1f drops=%d", label, document.frame.height, passes.count,
                         passes.isEmpty ? 0 : passes[passes.count / 2], passes.isEmpty ? 0 : passes[min(passes.count - 1, Int(Double(passes.count) * 0.95))],
                         passes.last ?? 0, passes.filter { $0 > 16.7 }.count))
            scroller.contentView.scroll(to: .zero)
            scroller.reflectScrolledClipView(scroller.contentView)
        }
        for stop in TimelineZoom.stops {
            host.monitor.passes.removeAll()
            let t0 = CACurrentMediaTime()
            host.activities.timelineHourHeight = stop
            await host.settle(0.8)
            let passes = host.monitor.passes.filter { $0.end >= t0 }.map(\.ms)
            print(String(format: "PERF zoom stop=%d blocks=%d change longest=%.1f drops=%d totalPassMs=%.0f", Int(stop), host.activities.timelineBlocks.count,
                         passes.max() ?? 0, passes.filter { $0 > 16.7 }.count, passes.reduce(0, +)))
            await sweep("stop\(Int(stop))")
            await sweep("stop\(Int(stop))_again")
        }
    }
}
