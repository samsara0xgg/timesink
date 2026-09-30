import XCTest
@testable import TimeSinkKit

final class TimelineSegmenterTests: XCTestCase {
    private func item(_ start: Double, _ end: Double, app: String = "editor", category: String = "work",
                      title: String = "t") -> CategorizedSpan {
        CategorizedSpan(span: Span(start: Date(timeIntervalSince1970: 1_777_593_600 + start),
                                   end: Date(timeIntervalSince1970: 1_777_593_600 + end),
                                   appBundleID: app, appName: app, title: title, url: nil, domain: nil),
                        categoryID: category)
    }

    /// Churn at any resolution: segments are ordered, never overlap, account
    /// for every recorded second, and none is shorter than the resolution
    /// unless its whole stretch of recording is.
    func testEverySecondAccountedAndNothingIllegible() {
        var items: [CategorizedSpan] = []
        var cursor: Double = 0
        for index in 0..<400 {
            let length = Double([3, 7, 12, 40, 5, 180, 9, 2][index % 8])
            items.append(item(cursor, cursor + length, app: ["editor", "chat", "browser"][index % 3],
                              category: index % 3 == 1 ? "chat" : "work", title: "t\(index % 4)"))
            cursor += length + (index % 50 == 49 ? 120 : 0)  // a real gap now and then
        }
        let total = items.reduce(0) { $0 + $1.span.duration }
        for resolution in [0.0, 60, 300, 900] {
            let segments = TimelineSegmenter.segments(items, resolution: resolution)
            XCTAssertEqual(segments.reduce(0) { $0 + $1.recorded }, total, accuracy: 0.001)
            XCTAssertEqual(segments.reduce(0) { $0 + $1.spanCount }, items.count)
            for (previous, next) in zip(segments, segments.dropFirst()) {
                XCTAssertLessThanOrEqual(previous.end, next.start)
            }
            // Islands are 50 spans (~2.5k s) long, so every segment can reach the resolution.
            XCTAssertTrue(segments.allSatisfy { $0.duration >= resolution }, "resolution \(resolution)")
        }
        XCTAssertGreaterThan(TimelineSegmenter.segments(items, resolution: 60).count,
                             TimelineSegmenter.segments(items, resolution: 300).count)
    }

    func testBridgeSeparatesJitterFromTimeAway() {
        let jitter = TimelineSegmenter.segments([item(0, 600), item(629, 900)], resolution: 0)
        XCTAssertEqual(jitter.count, 1)
        XCTAssertEqual(jitter[0].recorded, 871)
        let away = TimelineSegmenter.segments([item(0, 600), item(631, 900)], resolution: 0)
        XCTAssertEqual(away.map(\.end), [item(0, 600).span.end, item(631, 900).span.end])
    }

    func testCategoryGroupingJoinsAppsOfOneCategory() {
        let items = [item(0, 60, app: "editor"), item(60, 120, app: "terminal"), item(120, 180, app: "chat", category: "chat")]
        XCTAssertEqual(TimelineSegmenter.segments(items, resolution: 0, grouping: .category).count, 2)
        XCTAssertEqual(TimelineSegmenter.segments(items, resolution: 0, grouping: .activity).count, 3)
    }

    func testMixedSegmentKeepsComposition() {
        let items = [item(0, 100, app: "editor"), item(100, 160, app: "chat", category: "chat"),
                     item(160, 250, app: "editor"), item(250, 300, app: "chat", category: "chat")]
        let segment = try! XCTUnwrap(TimelineSegmenter.segments(items, resolution: 300).first)
        XCTAssertEqual(segment.parts.map(\.appName), ["editor", "chat"])
        XCTAssertEqual(segment.parts.map(\.seconds), [190, 110])
        XCTAssertEqual(segment.switches, 3)
        XCTAssertTrue(segment.isMixed)
        XCTAssertEqual(segment.leadingCategoryID, "work")
    }

    /// A glance at chat in the middle of an hour of editing is not a block.
    func testBriefSwitchFoldsIntoTheTaskAroundIt() {
        let items = [item(0, 1200), item(1200, 1260, app: "chat", category: "chat"), item(1260, 2460)]
        let segments = TimelineSegmenter.segments(items, resolution: 450)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].parts.map(\.appName), ["editor", "chat"])
        // The glance stays visible as a mark where it happened.
        XCTAssertEqual(segments[0].excursions.map(\.start), [items[1].span.start])
        XCTAssertEqual(segments[0].excursions.map(\.categoryID), ["chat"])
    }

    /// Back-and-forth reads as one mixed stretch, not a stack of slices.
    func testBackAndForthIsOneStretch() {
        let items: [CategorizedSpan] = (0..<40).map { index in
            let start = Double(index) * 60
            return item(start, start + 60, app: index % 2 == 0 ? "editor" : "terminal")
        }
        let segments = TimelineSegmenter.segments(items, resolution: 450)
        XCTAssertEqual(segments.count, 1)
        // Every stretch on the other row is an excursion, whatever its
        // category: whether it is drawn is the display layer's call.
        XCTAssertEqual(segments[0].excursions.count, 20)
        XCTAssertTrue(segments[0].excursions.allSatisfy { $0.seconds == 60 })
    }

    /// Ten minutes spent mostly elsewhere stay visible between two long tasks,
    /// even when no single run in them reaches the resolution.
    func testStretchOfAnotherCategoryStandsOut() {
        var items = [item(0, 1800)]
        for index in 0..<6 {
            let start = 1800 + Double(index) * 100
            items += [item(start, start + 90, app: index % 2 == 0 ? "chat" : "mail", category: "chat"),
                      item(start + 90, start + 100)]
        }
        items.append(item(2400, 4200))
        let segments = TimelineSegmenter.segments(items, resolution: 450)
        XCTAssertEqual(segments.map(\.leadingCategoryID), ["work", "chat", "work"])
    }

    /// Drawn to scale, stray seconds are left out and a short break does not
    /// split one task; lists keep both.
    func testDrawingLeavesOutStraySecondsAndClosesShortBreaks() {
        let items = [item(0, 1200), item(1320, 2520), item(4320, 4340, app: "chat", category: "chat")]
        let drawn = TimelineSegmenter.segments(items, resolution: 450, forDrawing: true)
        XCTAssertEqual(drawn.map(\.recorded), [2400])
        XCTAssertEqual(drawn[0].end, items[1].span.end)
        XCTAssertEqual(TimelineSegmenter.segments(items, resolution: 450).count, 3)
    }
}
