import Foundation

/// Human-readable formatting helpers for stats display.
public enum Format {
    public static func chineseDuration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return String(localized: "0 分钟") }
        guard seconds >= 60 else { return String(localized: "不到 1 分钟") }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return String(localized: "\(minutes) 分钟") }
        return minutes % 60 == 0 ? String(localized: "\(minutes / 60) 小时") : String(localized: "\(minutes / 60) 小时 \(minutes % 60) 分钟")
    }
    /// Formats a duration in seconds as e.g. "1h 1m", "9m", "<1m" (0 < t < 60s), "0m" (t <= 0).
    public static func duration(_ t: TimeInterval) -> String {
        guard t > 0 else { return "0m" }
        guard t >= 60 else { return "<1m" }
        let totalMinutes = Int(t / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        guard hours > 0 else { return "\(minutes)m" }
        return "\(hours)h \(minutes)m"
    }

    /// Formats a signed duration delta, e.g. "+42m" / "-1h 3m".
    public static func durationDelta(_ t: TimeInterval) -> String {
        (t >= 0 ? "+" : "-") + Format.duration(abs(t))
    }

    /// `a - b` as the two would read on screen: each cut to whole minutes the
    /// way `duration` shows it, then subtracted, so "6h 36m", "5h 49m" and
    /// "+47m" always agree.
    public static func minuteDelta(_ a: TimeInterval, _ b: TimeInterval) -> TimeInterval {
        TimeInterval(Int(max(0, a) / 60) - Int(max(0, b) / 60)) * 60
    }

    /// Formats a countdown as zero-padded "mm:ss" (C4 focus sessions --
    /// label countdown, popover running state, HUD). Negative/zero clamps to
    /// "00:00".
    public static func mmss(_ t: TimeInterval) -> String {
        let clamped = max(0, Int(t.rounded()))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    /// Formats a signed integer delta, e.g. "+6" / "-3" / "+0". Shared by
    /// the menu-bar popover's pulse-delta chip and its 分数环 drill-down's
    /// 较昨日 line (fold-in 6: previously duplicated as two private
    /// one-liners, one per file).
    public static func signedInt(_ v: Int) -> String {
        v >= 0 ? "+\(v)" : "\(v)"
    }
}
