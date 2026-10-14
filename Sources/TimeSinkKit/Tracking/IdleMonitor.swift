import CoreGraphics
import Foundation

public struct IdleMonitor: Sendable {
    public init() {}
    /// Since any HID input: `kCGAnyInputEventType` (~0), which CoreGraphics
    /// does not import as a case. Not only the six types this used to ask
    /// about one by one -- a drag, a modifier key or a trackpad gesture is
    /// someone at the Mac too.
    public func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }
    public func secondsSinceKeyDown() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }
}
