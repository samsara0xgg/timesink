import Foundation

/// Human-readable formatting helpers for stats display.
public enum Format {
    /// Prose use of `duration` (kept so sentences read the same as the columns).
    public static func chineseDuration(_ seconds: TimeInterval) -> String { duration(seconds) }

    /// The one duration formatter, in the interface language: en "1h 36m",
    /// "9m", "<1m", "0m"; zh "1 小时 36 分", "9 分", "不到 1 分", "0 分".
    /// `compact` is for tight numeric columns: whole hours and minutes as
    /// "1:36" from one hour up, plain minutes below it.
    public static func duration(_ t: TimeInterval, compact: Bool = false, locale: Locale = AppLanguage.locale) -> String {
        let zh = locale.language.languageCode?.identifier == "zh"
        guard t > 0 else { return zh ? "0 分" : "0m" } // l10n: data
        guard t >= 60 else { return zh ? "不到 1 分" : "<1m" } // l10n: data
        let totalMinutes = Int(t / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, compact { return "\(hours):" + (minutes < 10 ? "0" : "") + "\(minutes)" }
        guard hours > 0 else { return zh ? "\(minutes) 分" : "\(minutes)m" } // l10n: data
        return zh ? "\(hours) 小时 \(minutes) 分" : "\(hours)h \(minutes)m" // l10n: data
    }

    /// Formats a signed duration delta, e.g. "+42m" / "-1h 3m".
    public static func durationDelta(_ t: TimeInterval, locale: Locale = AppLanguage.locale) -> String {
        (t >= 0 ? "+" : "-") + Format.duration(abs(t), locale: locale)
    }

    /// `a - b` as the two would read on screen: each cut to whole minutes the
    /// way `duration` shows it, then subtracted, so "6h 36m", "5h 49m" and
    /// "+47m" always agree.
    public static func minuteDelta(_ a: TimeInterval, _ b: TimeInterval) -> TimeInterval {
        TimeInterval(minutes(a) - minutes(b)) * 60
    }

    /// Whole minutes, cut the way `duration` shows them.
    public static func minutes(_ t: TimeInterval) -> Int { Int(max(0, t) / 60) }

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
