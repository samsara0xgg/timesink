import Foundation

/// F3 回到刚才: once a switch out of productive work turns into an
/// interruption (by the same rule the timeline draws), offers the window
/// that was left. The offer goes away when you go back yourself, after two
/// minutes, or while a focus session runs. A peek never raises it.
struct ReturnTracker {
    struct Origin: Equatable, Sendable {
        let bundleID: String
        let appName: String
        let title: String?
        /// The page, when the window was a browser tab.
        var url: String? = nil
    }

    static let offerLifetime: TimeInterval = 120

    private(set) var origin: Origin?
    private(set) var offer: Origin?
    private var offeredAt: Date?
    private var offeredThisTrip = false
    /// This trip so far, counted as `InterruptionClassifier` counts an
    /// episode: only time and key-seconds in distracting windows, summed
    /// over every one of them since the productive window was left. Time in
    /// a window that neither works nor distracts does not count, so a peek
    /// followed by a while in Finder is still a peek.
    private var dwell: TimeInterval = 0
    private var keySeconds = 0
    /// The distracting span in front, not yet in `dwell`, as last seen.
    private var visit: (start: Date, bundleID: String, seconds: TimeInterval, keySeconds: Int)?

    /// One tracker tick: `current` is the open span (nil while away), with
    /// its category's productivity and whether that category distracts.
    mutating func observe(current: Span?, productivity: Int, distracting: Bool, now: Date,
                          rule: InterruptionRule, focusing: Bool) {
        if let offeredAt, now.timeIntervalSince(offeredAt) >= Self.offerLifetime { offer = nil; self.offeredAt = nil }
        if focusing { offer = nil }
        guard let current else {
            // Away time forgets the origin, as the classifier does.
            origin = nil; offeredThisTrip = false; resetTrip()
            return
        }
        if productivity >= InterruptionRule.productiveFloor {
            origin = Origin(bundleID: current.appBundleID, appName: current.appName, title: current.title, url: current.url)
            offer = nil; offeredAt = nil; offeredThisTrip = false; resetTrip()
            return
        }
        guard let origin else { return }
        // A distracting span that is no longer in front is done: bank it.
        if let visit, visit.start != current.start || visit.bundleID != current.appBundleID {
            dwell += visit.seconds
            keySeconds += visit.keySeconds
            self.visit = nil
        }
        guard distracting else { return }
        // The span in front is still growing; between ticks its end trails `now`.
        let held = max(current.duration, now.timeIntervalSince(current.start))
        visit = (current.start, current.appBundleID, held, current.keySeconds)
        guard !focusing, !offeredThisTrip else { return }
        let typed = rule.countsTyping && keySeconds + current.keySeconds >= InterruptionRule.typedKeySeconds
        if typed || dwell + held >= rule.dwell {
            offer = origin; offeredAt = now; offeredThisTrip = true
        }
    }

    private mutating func resetTrip() {
        dwell = 0
        keySeconds = 0
        visit = nil
    }

    mutating func clearOffer() { offer = nil; offeredAt = nil }
}
