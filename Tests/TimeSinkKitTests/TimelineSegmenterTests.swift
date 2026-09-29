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
}
