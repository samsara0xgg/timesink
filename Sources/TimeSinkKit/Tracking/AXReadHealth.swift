import Foundation

/// Window-title reads through Accessibility, as a streak. A grant that macOS
/// no longer honours (stale after re-signing) reads nothing and says nothing:
/// the app looks fine while every span has no title. Only failures in an
/// unbroken run count; one successful read clears it.
public struct AXReadHealth: Equatable, Sendable {
    public static let minSpan: TimeInterval = 30 * 60
    public static let minFailures = 300

    public private(set) var failures = 0
    public private(set) var firstFailureAt: Date?

    public init() {}

    public mutating func note(ok: Bool, at now: Date) {
        if ok {
            failures = 0; firstFailureAt = nil
        } else {
            failures += 1
            if firstFailureAt == nil { firstFailureAt = now }
        }
    }

    public func isDegraded(at now: Date) -> Bool {
        guard let first = firstFailureAt else { return false }
        return failures >= Self.minFailures && now.timeIntervalSince(first) >= Self.minSpan
    }
}
