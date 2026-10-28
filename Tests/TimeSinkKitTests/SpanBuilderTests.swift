import XCTest
@testable import TimeSinkKit

func ts(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

func sample(_ t: TimeInterval, app: String = "com.apple.dt.Xcode", name: String = "Xcode",
            title: String? = "main.swift", url: String? = nil) -> Sample {
    Sample(timestamp: ts(t), appBundleID: app, appName: name, windowTitle: title, url: url)
}

final class SpanBuilderTests: XCTestCase {
    func testFirstSampleOpensSpan() {
        let b = SpanBuilder()
        XCTAssertNil(b.ingest(sample(0)))
        XCTAssertEqual(b.current?.start, ts(0))
        XCTAssertEqual(b.current?.end, ts(1))
    }
    func testSameActivityExtends() {
        let b = SpanBuilder()
        _ = b.ingest(sample(0)); _ = b.ingest(sample(1)); _ = b.ingest(sample(2))
        XCTAssertEqual(b.current?.end, ts(3))
        XCTAssertEqual(b.current?.duration, 3)
    }
    func testActivityChangeClosesAndOpens() {
        let b = SpanBuilder()
        _ = b.ingest(sample(0)); _ = b.ingest(sample(1))
        let closed = b.ingest(sample(2, app: "com.google.Chrome", name: "Chrome",
                                     title: "GitHub", url: "https://github.com/a/b"))
        XCTAssertEqual(closed?.appBundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(closed?.end, ts(2))
        XCTAssertEqual(b.current?.appBundleID, "com.google.Chrome")
        XCTAssertEqual(b.current?.domain, "github.com")
    }
    func testGapBeyondMaxGapSplits() {
        let b = SpanBuilder()
        _ = b.ingest(sample(0))
        let closed = b.ingest(sample(60))   // 同活动但断档 59s > maxGap 15
        XCTAssertEqual(closed?.end, ts(1))  // 旧 span 在最后已知 end 闭合
        XCTAssertEqual(b.current?.start, ts(60))
    }
    func testCloseBackdatesForIdle() {
        let b = SpanBuilder()
        _ = b.ingest(sample(0)); _ = b.ingest(sample(100))  // 不会发生, 仅构造: 先重置
        let b2 = SpanBuilder()
        for t in 0...200 { _ = b2.ingest(sample(TimeInterval(t))) }
        // 空闲阈值 180s 到达, 最后输入在 t=30 → close(at: ts(30))
        let closed = b2.close(at: ts(30))
        XCTAssertEqual(closed?.end, ts(30))
        XCTAssertNil(b2.current)
        XCTAssertNil(b2.close(at: ts(31)))  // 已无 current
    }
    func testCloseClampsToStart() {
        let b = SpanBuilder()
        _ = b.ingest(sample(100))
        let closed = b.close(at: ts(50))    // close 时间早于 start → 收敛为零长
        XCTAssertEqual(closed?.start, ts(100))
        XCTAssertEqual(closed?.end, ts(100))
    }

    private func feed(_ b: SpanBuilder, _ app: String, _ from: TimeInterval, _ to: TimeInterval) -> [Span] {
        (Int(from)..<Int(to)).compactMap { b.ingest(sample(TimeInterval($0), app: app, name: app, title: nil)) }
    }
    func testFlickerBetweenTheSameActivityIsMergedBackIntoIt() {
        let b = SpanBuilder()
        XCTAssertTrue(feed(b, "A", 0, 10).isEmpty)
        let first = b.ingest(sample(10, app: "x", name: "x", title: nil))   // A closes whole
        XCTAssertEqual(first?.end, ts(10))
        XCTAssertNil(b.ingest(sample(11, app: "A", name: "A", title: nil)))  // x lasted 1 s: A resumes
        XCTAssertEqual(b.current?.start, ts(0))
        XCTAssertEqual(b.current?.end, ts(12))
    }
    func testFlickerBeforeADifferentActivityExtendsThePreviousSpan() {
        let b = SpanBuilder()
        _ = feed(b, "A", 0, 10)
        _ = b.ingest(sample(10, app: "x", name: "x", title: nil))
        _ = b.ingest(sample(11, app: "x", name: "x", title: nil))
        let extended = b.ingest(sample(12, app: "B", name: "B", title: nil))   // x lasted 2 s
        XCTAssertEqual(extended?.appBundleID, "A")
        XCTAssertEqual(extended?.start, ts(0))
        XCTAssertEqual(extended?.end, ts(12))
        XCTAssertEqual(b.current?.appBundleID, "B")
    }
    func testFlickerAfterACloseOrWithoutAPreviousSpanIsKept() {
        let b = SpanBuilder()
        XCTAssertNil(b.ingest(sample(0, app: "x", name: "x", title: nil)))
        XCTAssertEqual(b.ingest(sample(1, app: "A", name: "A", title: nil))?.appBundleID, "x")   // nothing before it
        _ = feed(b, "A", 2, 10)
        _ = b.close(at: ts(10))                                                                 // idle or lock
        _ = b.ingest(sample(11, app: "x", name: "x", title: nil))
        XCTAssertEqual(b.ingest(sample(12, app: "A", name: "A", title: nil))?.appBundleID, "x")
        _ = feed(b, "A", 13, 16)
        XCTAssertEqual(b.ingest(sample(16, app: "x", name: "x", title: nil))?.appBundleID, "A")
        _ = feed(b, "x", 17, 19)
        let slow = b.ingest(sample(19, app: "A", name: "A", title: nil))
        XCTAssertEqual(slow?.appBundleID, "x", "3 s is not a flicker")
        XCTAssertEqual(slow?.duration, 3)
    }
}
