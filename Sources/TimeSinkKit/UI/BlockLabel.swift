import AppKit

/// The duration written inside a Today timeline block, decided by one rule so
/// that similar blocks never look different by chance:
///
/// - recorded >= 30 minutes: always a duration; recorded < 30 minutes: never.
/// - When the full form does not fit it degrades in a fixed order, taking the
///   first form that fits: "1h 17m", "1h17", "77m", "1h" (hours cut down to
///   whole hours, so 60...119 minutes read "1h"). Under an hour there is only
///   "47m".
/// - Only when some block of 30 minutes or more cannot hold even its shortest
///   form does the whole timeline hide every label at once (`fitsAll`), so
///   blocks never differ by chance: all of them have a label or none do.
///
/// The same rule runs on every day and window width; what changes is only the
/// scale (points per hour) it is applied to.
enum BlockLabel {
    /// Shortest recorded time that gets a label.
    static let threshold: TimeInterval = 1800
    /// Space inside a block either side of the text.
    static let padding: CGFloat = 6

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

    /// The text for a block `available` points wide inside its padding, or nil.
    static func text(_ seconds: TimeInterval, available: CGFloat, locale: Locale = AppLanguage.locale,
                     width: (String) -> CGFloat) -> String? {
        guard seconds >= threshold else { return nil }
        return forms(seconds, locale: locale).first { width($0) <= available }
    }

    /// Whether the timeline shows labels at all: every block of 30 minutes or more must have some form that fits.
    /// If one cannot, no block gets a label, so the blocks never differ by chance.
    static func fitsAll(_ blocks: [(recorded: TimeInterval, width: CGFloat)], locale: Locale = AppLanguage.locale,
                        width: (String) -> CGFloat) -> Bool {
        blocks.allSatisfy { $0.recorded < threshold || text($0.recorded, available: $0.width - 2 * padding, locale: locale, width: width) != nil }
    }

    /// The width of `text` in the font the block draws it in: the note size, semibold, figures of one width.
    @MainActor static func noteWidth(_ text: String) -> CGFloat {
        let size = NSFont.preferredFont(forTextStyle: .subheadline).pointSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
