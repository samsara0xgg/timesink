import Foundation

public final class SpanBuilder {
    public private(set) var current: Span?
    private let tick: TimeInterval
    private let maxGap: TimeInterval
    /// A span shorter than this is a frontmost flicker (switching windows), not something the user did.
    public static let minSpanDuration: TimeInterval = 3
    /// The last span `ingest` handed back, still adjacent to `current`: where a flicker's time goes.
    /// Cleared by `close`, so nothing merges across an idle, lock, sleep or excluded-app gap.
    private var previous: Span?

    public init(tick: TimeInterval = 1, maxGap: TimeInterval = 15) {
        self.tick = tick; self.maxGap = maxGap
    }

    public func ingest(_ s: Sample) -> Span? {
        if var cur = current,
           cur.appBundleID == s.appBundleID, cur.title == s.windowTitle, cur.url == s.url,
           cur.document == s.document,
           s.timestamp.timeIntervalSince(cur.end) <= maxGap {
            cur.end = s.timestamp.addingTimeInterval(tick)
            current = cur
            return nil
        }
        let closed = current
        let next = Span(start: s.timestamp, end: s.timestamp.addingTimeInterval(tick),
                        appBundleID: s.appBundleID, appName: s.appName,
                        title: s.windowTitle, url: s.url,
                        domain: s.url.flatMap(DomainParser.domain(from:)),
                        document: s.document)
        current = next
        guard let closed else { return nil }
        if closed.duration < Self.minSpanDuration, var prev = previous,
           closed.start.timeIntervalSince(prev.end) <= tick {
            if prev.appBundleID == s.appBundleID, prev.title == s.windowTitle, prev.url == s.url,
               prev.document == s.document, s.timestamp.timeIntervalSince(closed.end) <= tick {
                // A-x-A: A carries on as the open span; the caller's row for A is reopened by its start.
                prev.end = next.end
                current = prev
                previous = nil
                return nil
            }
            // The flicker's time goes to the span before it, which the caller extends by its start.
            prev.end = closed.end
            previous = prev
            return prev
        }
        previous = closed
        return closed
    }

    /// Counts one key-second on the open span. The caller decides what
    /// counts; the builder only never counts the span's opening tick.
    public func noteKeySecond(at timestamp: Date) {
        guard var cur = current, timestamp > cur.start else { return }
        cur.keySeconds += 1
        current = cur
    }

    public func close(at end: Date) -> Span? {
        guard var cur = current else { return nil }
        cur.end = max(cur.start, min(end, cur.end))
        current = nil
        previous = nil
        return cur
    }
}
