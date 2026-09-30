import CoreGraphics
import Foundation

public struct IdleMonitor: Sendable {
    public init() {}
    public func idleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown,
                                    .rightMouseDown, .scrollWheel, .otherMouseDown]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }.min() ?? 0
    }
    public func secondsSinceKeyDown() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }
}
