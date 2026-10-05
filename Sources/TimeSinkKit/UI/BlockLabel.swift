import AppKit

/// The duration written inside a Today timeline block, decided by one rule per
/// timeline so that similar blocks never look different by chance:
///
/// - The timeline's scale (points per second) fixes one threshold N, the
///   smallest of 30, 45, 60, 90, 120 minutes whose block can hold its shortest
///   form ("30m", "45m", "1h", "1h", "2h") inside the padding (`minutes(...)`).
///   Blocks recorded for N minutes or more show a label, shorter blocks never
///   do. If even 120 minutes does not fit, no block has a label.
/// - A block shows the longest form that fits: "1h 17m", "1h17", "77m", "1h"
///   (hours cut down to whole hours, so 60...119 minutes read "1h"). Under an
///   hour there is only "47m". Every block of N minutes or more is at least as
///   wide as the N-minute block, so it always has its shortest form.
///
/// The same rule runs on every day and window width; only the scale changes N.
enum BlockLabel {
    /// The candidate thresholds, in minutes, smallest first. Nothing under 30 minutes ever has a label.
    static let candidates = [30, 45, 60, 90, 120]
    /// Space inside a block either side of the text.
    static let padding: CGFloat = 4
    /// The seam between abutting blocks, taken off each block's width.
    static let seam: CGFloat = 2

    /// The forms of the label, longest first.
    static func forms(_ seconds: TimeInterval, locale: Locale = AppLanguage.locale) -> [String] {
        let zh = locale.language.languageCode?.identifier == "zh"
        let total = Format.minutes(seconds), hours = total / 60, minutes = total % 60
        guard hours > 0, minutes > 0 else { return [Format.duration(seconds, locale: locale)] }
        let compact = String(format: "%dh%02d", hours, minutes)
        var result = [Format.duration(seconds, locale: locale)]
        result += [zh ? String(format: "%d时%02d", hours, minutes) : compact, zh ? "\(total) 分" : "\(total)m", zh ? "\(hours) 小时" : "\(hours)h"] // l10n: data
        return result
    }

    /// The timeline's threshold N in minutes at `pointsPerSecond`, or nil when no label fits anywhere.
    static func minutes(pointsPerSecond: CGFloat, locale: Locale = AppLanguage.locale, width: (String) -> CGFloat) -> Int? {
        candidates.first { n in
            let seconds = TimeInterval(n * 60)
            let shortest = forms(seconds, locale: locale).last ?? ""
            return width(shortest) + 2 * padding <= seconds * pointsPerSecond - seam
        }
    }

    /// The text for a block `available` points wide inside its padding, or nil below the threshold.
    static func text(_ seconds: TimeInterval, threshold: Int?, available: CGFloat, locale: Locale = AppLanguage.locale,
                     width: (String) -> CGFloat) -> String? {
        guard let threshold, Format.minutes(seconds) >= threshold else { return nil }
        return forms(seconds, locale: locale).first { width($0) <= available }
    }

    /// The width of `text` in the font the block draws it in: the note size, semibold, figures of one width.
    @MainActor static func noteWidth(_ text: String) -> CGFloat {
        let size = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
