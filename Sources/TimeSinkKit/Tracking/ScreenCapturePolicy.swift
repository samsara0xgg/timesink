import Foundation

/// Process + window identity of the front window; a title change alone is
/// never a window change (browser loads and editor dirty flags would churn).
public struct WindowKey: Hashable, Sendable {
    public let bundleID: String
    public let windowID: UInt32
    public init(bundleID: String, windowID: UInt32) {
        self.bundleID = bundleID
        self.windowID = windowID
    }
}

/// When to look at the front window. Pure and clock-free so it is testable:
/// a window has to stay in front for `settleSeconds` before its first check,
/// and the same window is re-checked every `checkInterval` after that.
/// Whether a check turns into a stored capture is decided by
/// `ScreenSignature.changed` afterwards, not here.
///
/// `segment` numbers one continuous observation of one window. It advances
/// when the front window changes (including to nil: excluded app), on an
/// explicit `interrupt()` (lock, sleep, stop, pause, resume), and as a
/// backstop when ticks stop arriving for longer than `maxTickGap`, so a
/// capture row may only be extended inside the segment that created it.
public struct ScreenCapturePolicy: Equatable, Sendable {
    public var settleSeconds: TimeInterval
    public var checkInterval: TimeInterval
    /// Ticks come every second; a longer silence means the tracker was not
    /// looking, whatever the reason. Wide enough that one stalled tick (a
    /// slow AX or Chrome round-trip) does not split a row.
    public var maxTickGap: TimeInterval
    public private(set) var segment = 0

    private var candidate: WindowKey?
    private var candidateSince = Date.distantPast
    private var lastCheck = Date.distantPast
    private var lastTick = Date.distantPast

    public init(settleSeconds: TimeInterval = 3, checkInterval: TimeInterval = 30,
                maxTickGap: TimeInterval = 5) {
        self.settleSeconds = settleSeconds
        self.checkInterval = checkInterval
        self.maxTickGap = maxTickGap
    }

    /// The tracker stopped looking (lock, sleep, stop, pause) or started
    /// again: whatever is in front next is a new observation, even if the
    /// break was shorter than a tick.
    public mutating func interrupt() {
        candidate = nil
        lastCheck = .distantPast
        segment += 1
    }

    /// Returns true when the front window should be inspected now.
    /// `window == nil` (no front window, or an excluded app) resets the
    /// settle timer. Out-of-order ticks are ignored.
    public mutating func tick(now: Date, window: WindowKey?) -> Bool {
        guard now >= lastTick else { return false }
        let gap = now.timeIntervalSince(lastTick) > maxTickGap
        lastTick = now
        if window != candidate || gap {
            candidate = window
            candidateSince = now
            lastCheck = .distantPast
            segment += 1
            return false
        }
        guard window != nil else { return false }
        guard now.timeIntervalSince(candidateSince) >= settleSeconds else { return false }
        guard now.timeIntervalSince(lastCheck) >= checkInterval else { return false }
        lastCheck = now
        return true
    }
}

/// A coarse grayscale thumbnail (`columns` x `rows` cells) compared cell by
/// cell, so a blinking cursor or a clock digit cannot count as new content.
public enum ScreenSignature {
    public static let columns = 32
    public static let rows = 20
    /// Per-cell luminance delta (0...255) that counts the cell as changed.
    public static let cellDelta = 24
    /// Fraction of changed cells that counts the frame as new content.
    /// ponytail: starting guess; tune against real apps after a day of use.
    public static let changedFraction = 0.10

    public static func changed(_ a: [UInt8], _ b: [UInt8], fraction: Double = changedFraction) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        var differing = 0
        for (x, y) in zip(a, b) where abs(Int(x) - Int(y)) > cellDelta {
            differing += 1
        }
        return Double(differing) / Double(a.count) >= fraction
    }
}

/// Image retention: day folders are named by local date, so pruning is a
/// string comparison against the cutoff day.
public enum CaptureRetention {
    public static let days = 7

    public static func dayStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func cutoff(now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
    }

    public static func isExpired(dayFolder: String, now: Date, calendar: Calendar = .current) -> Bool {
        dayFolder < dayStamp(cutoff(now: now, calendar: calendar), calendar: calendar)
    }
}
