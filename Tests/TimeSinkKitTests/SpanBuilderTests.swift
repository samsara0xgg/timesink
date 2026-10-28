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
}
