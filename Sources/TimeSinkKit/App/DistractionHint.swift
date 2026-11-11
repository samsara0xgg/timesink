import Foundation

/// 5 minutes straight in a distracting category turns the menu bar hourglass
/// orange; leaving for any other category, idling or pausing starts over.
struct DistractionStreak {
    static let threshold: TimeInterval = 5 * 60
    private(set) var since: Date?

    mutating func observe(distracting: Bool, now: Date) -> Bool {
        guard distracting else { since = nil; return false }
        let start = since ?? now
        since = start
        return now.timeIntervalSince(start) >= Self.threshold
    }
}

extension AppModel {
    func observeForDistraction(_ span: Span?, now: Date) {
        var distracting = false
        if let span, !trackingPaused {
            // Categorize once per window, not once per second.
            if let cached = distractionCategory, cached.start == span.start, cached.bundleID == span.appBundleID {
                distracting = cached.distracting
            } else {
                distracting = resolver.distractingIDs.contains(resolver.categoryID(for: span))
                distractionCategory = (span.start, span.appBundleID, distracting)
            }
        }
        let over = distractionStreak.observe(distracting: distracting, now: now)
        if over != distracted { distracted = over }
    }
}
