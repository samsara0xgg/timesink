import XCTest
@testable import TimeSinkKit

/// Covers the day-timeline block builder's merge/absorb gap guard: a
/// same-category span across a real idle gap must stay its own block rather
/// than being painted as one continuous active span.
final class ActivitiesModelTests: XCTestCase {
    private let categories: [String: TimeSinkKit.Category] = [
        "work": TimeSinkKit.Category(id: "work", name: "Work", colorHex: "#000000", productivity: 1, sortOrder: 0),
        "chat": TimeSinkKit.Category(id: "chat", name: "Chat", colorHex: "#111111", productivity: -1, sortOrder: 1),
    ]

    private func mkSpan(_ startISO: String, _ endISO: String, app: String = "App") -> Span {
        let formatter = ISO8601DateFormatter()
        return Span(
            start: formatter.date(from: startISO)!,
            end: formatter.date(from: endISO)!,
            appBundleID: "com.example.\(app)",
            appName: app,
            title: nil,
            url: nil,
            domain: nil
        )
    }

    /// Xcode 09:00-09:30, idle until 14:00, Xcode 14:00-14:10: same category
    /// either side of a 4.5h gap must NOT merge into one 09:00-14:10 block.
    func testLargeGapBetweenSameCategorySpansStaysTwoBlocks() {
        let items = [
            CategorizedSpan(span: mkSpan("2026-08-23T09:00:00Z", "2026-08-23T09:30:00Z"), categoryID: "work"),
            CategorizedSpan(span: mkSpan("2026-08-23T14:00:00Z", "2026-08-23T14:10:00Z"), categoryID: "work"),
        ]
        let blocks = ActivitiesModel.timelineBlocks(items, categories: categories)
        XCTAssertEqual(blocks.count, 2)
    }

    /// A <30s sliver contiguous with the previous block (small gap) is
    /// absorbed into it — the previous block's end extends to cover it.
    func testContiguousSliverIsAbsorbedIntoPreviousBlock() {
        let items = [
            CategorizedSpan(span: mkSpan("2026-08-23T09:00:00Z", "2026-08-23T09:30:00Z"), categoryID: "work"),
            CategorizedSpan(span: mkSpan("2026-08-23T09:30:05Z", "2026-08-23T09:30:20Z"), categoryID: "chat"),
        ]
        let blocks = ActivitiesModel.timelineBlocks(items, categories: categories)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].label, "Work")
        XCTAssertEqual(blocks[0].end, mkSpan("2026-08-23T09:30:05Z", "2026-08-23T09:30:20Z").end)
    }

    /// A <30s sliver hours after the previous block (large gap) is dropped
    /// entirely rather than teleporting the previous block's end forward.
    func testDistantSliverIsDropped() {
        let items = [
            CategorizedSpan(span: mkSpan("2026-08-23T09:00:00Z", "2026-08-23T09:30:00Z"), categoryID: "work"),
            CategorizedSpan(span: mkSpan("2026-08-23T14:00:00Z", "2026-08-23T14:00:10Z"), categoryID: "chat"),
        ]
        let blocks = ActivitiesModel.timelineBlocks(items, categories: categories)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].label, "Work")
        XCTAssertEqual(blocks[0].end, mkSpan("2026-08-23T09:00:00Z", "2026-08-23T09:30:00Z").end)
    }
}
