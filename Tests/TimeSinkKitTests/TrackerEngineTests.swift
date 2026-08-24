import XCTest
@testable import TimeSinkKit

final class ChromeThrottleTests: XCTestCase {
    func testFetchOnTitleChangeOrTimeout() {
        var t = ChromeThrottle(interval: 5)
        XCTAssertTrue(t.shouldFetch(title: "A", at: ts(0)))
        t.noteFetched(title: "A", at: ts(0))
        XCTAssertFalse(t.shouldFetch(title: "A", at: ts(2)))   // 同标题未超时
        XCTAssertTrue(t.shouldFetch(title: "B", at: ts(2)))    // 标题变了
        XCTAssertTrue(t.shouldFetch(title: "A", at: ts(6)))    // 超时
    }
}
