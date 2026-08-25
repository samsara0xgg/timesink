import Foundation

/// Human-readable formatting helpers for stats display.
public enum Format {
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

    /// Formats a countdown as zero-padded "mm:ss" (C4 focus sessions --
    /// label countdown, popover running state, HUD). Negative/zero clamps to
    /// "00:00".
    public static func mmss(_ t: TimeInterval) -> String {
        let clamped = max(0, Int(t.rounded()))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}
