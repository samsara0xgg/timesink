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
    private var outStart: Date?
    private var offeredThisTrip = false

    /// One tracker tick: `current` is the open span (nil while away), with
    /// its category's productivity and whether that category distracts.
    mutating func observe(current: Span?, productivity: Int, distracting: Bool, now: Date,
                          rule: InterruptionRule, focusing: Bool) {
        if let offeredAt, now.timeIntervalSince(offeredAt) >= Self.offerLifetime { offer = nil; self.offeredAt = nil }
        if focusing { offer = nil }
        guard let current else {
            // Away time forgets the origin, as the classifier does.
            origin = nil; outStart = nil; offeredThisTrip = false
            return
        }
        if productivity >= InterruptionRule.productiveFloor {
            origin = Origin(bundleID: current.appBundleID, appName: current.appName, title: current.title, url: current.url)
            offer = nil; offeredAt = nil; outStart = nil; offeredThisTrip = false
            return
        }
        guard let origin, distracting, !focusing, !offeredThisTrip else { return }
        let start = outStart ?? current.start
        outStart = start
        let typed = rule.countsTyping && current.keySeconds >= InterruptionRule.typedKeySeconds
        if typed || now.timeIntervalSince(start) >= rule.dwell {
            offer = origin; offeredAt = now; offeredThisTrip = true
        }
    }

    mutating func clearOffer() { offer = nil; offeredAt = nil }
}
