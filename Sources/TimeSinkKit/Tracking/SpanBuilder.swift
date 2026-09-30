import Foundation

public final class SpanBuilder {
    public private(set) var current: Span?
    private let tick: TimeInterval
    private let maxGap: TimeInterval

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
        current = Span(start: s.timestamp, end: s.timestamp.addingTimeInterval(tick),
                       appBundleID: s.appBundleID, appName: s.appName,
                       title: s.windowTitle, url: s.url,
                       domain: s.url.flatMap(DomainParser.domain(from:)),
                       document: s.document)
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
        return cur
    }
}
