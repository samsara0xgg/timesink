import XCTest
@testable import TimeSinkKit

final class FocusBlockPolicyTests: XCTestCase {
    func testCooldownGates() {
        var p = FocusBlockPolicy()
        XCTAssertTrue(p.shouldHide("a", at: ts(0)))
        XCTAssertFalse(p.shouldHide("a", at: ts(5)))    // 冷却内
        XCTAssertTrue(p.shouldHide("a", at: ts(11)))
        XCTAssertTrue(p.shouldHide("b", at: ts(5)))     // 键独立
    }
    func testAllowanceSuppressesAndExpires() {
        var p = FocusBlockPolicy()
        p.allow("a", at: ts(0))
        XCTAssertTrue(p.isAllowed("a", at: ts(299)))
        XCTAssertFalse(p.isAllowed("a", at: ts(301)))
        XCTAssertFalse(p.shouldHide("a", at: ts(100)))  // 放行期内不隐藏
    }
}
@MainActor
final class FocusSessionControllerTests: XCTestCase {
    func makeController() throws -> (FocusSessionController, FocusSessionStore, SettingsStore) {
        let db = try AppDatabase.openInMemory()
        let store = FocusSessionStore(db)
        let settings = SettingsStore(db)
        let controller = FocusSessionController(store: store, settings: settings)
        return (controller, store, settings)
    }
    func testStartPersistsAndCountsDown() throws {
        let (c, store, settings) = try makeController()
        settings.setFocusBlockedApps(["com.hnc.Discord"])
        try c.start(minutes: 25)
        XCTAssertNotNil(c.running)
        XCTAssertEqual(c.running!.plannedSeconds, 1500)
        XCTAssertEqual(try store.sessions(overlapping: .init(start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(60))).count, 1)
        XCTAssertEqual(FocusSessionController.remainingSeconds(start: ts(0), planned: 1500, now: ts(100)), 1400)
    }
    func testInterceptSkipsBlockPageSample() throws {
        let (c, _, _) = try makeController()
        try c.start(minutes: 25)
        let s = Sample(timestamp: ts(0), appBundleID: "com.google.Chrome", appName: "Chrome",
                       windowTitle: FocusBlockPage.pageMarkerTitle, url: nil)
        XCTAssertTrue(c.intercept(sample: s, at: ts(0)))
    }
    func testInterceptHidesBlockedAppWithCooldown() throws {
        let (c, _, settings) = try makeController()
        settings.setFocusBlockedApps(["com.hnc.Discord"])
        var hidden: [String] = []
        c.hideApp = { hidden.append($0) }
        c.showHUD = { _, _ in }
        try c.start(minutes: 25)
        let s = Sample(timestamp: ts(0), appBundleID: "com.hnc.Discord", appName: "Discord", windowTitle: nil, url: nil)
        XCTAssertFalse(c.intercept(sample: s, at: ts(0)))   // 记录照常
        XCTAssertEqual(hidden, ["com.hnc.Discord"])
        _ = c.intercept(sample: s, at: ts(3))
        XCTAssertEqual(hidden.count, 1)                      // 冷却内不再 hide
        XCTAssertEqual(c.appBlocks, 1)
    }
    func testInterceptRedirectsBlockedCategoryDomain() throws {
        let (c, _, settings) = try makeController()
        settings.setFocusBlockedCategories(["entertainment"])
        c.categoryForDomain = { domain, _ in domain == "bilibili.com" ? "entertainment" : "misc" }
        var redirected: [String] = []
        c.redirectChrome = { redirected.append($0); return true }
        try c.start(minutes: 25)
        let s = Sample(timestamp: ts(0), appBundleID: "com.google.Chrome", appName: "Chrome",
                       windowTitle: "B 站", url: "https://bilibili.com/video/x")
        XCTAssertFalse(c.intercept(sample: s, at: ts(0)))
        XCTAssertEqual(redirected.count, 1)
        XCTAssertEqual(c.siteBlocks, 1)
        c.allowDomain("bilibili.com")
        _ = c.intercept(sample: s, at: ts(10))
        XCTAssertEqual(redirected.count, 1)                  // 放行期内不再重定向
    }
    func testDoubleTapKeepFocusAllows() throws {
        let (c, _, settings) = try makeController()
        settings.setFocusBlockedApps(["a"])
        try c.start(minutes: 25)
        c.keepFocusTapped(appKey: "a", at: ts(0))
        c.keepFocusTapped(appKey: "a", at: ts(0.3))          // 0.4s 内二连
        var hidden = 0
        c.hideApp = { _ in hidden += 1 }
        let s = Sample(timestamp: ts(1), appBundleID: "a", appName: "A", windowTitle: nil, url: nil)
        _ = c.intercept(sample: s, at: ts(1))
        XCTAssertEqual(hidden, 0)                             // 已放行
    }
    func testFinishIsIdempotentAndReportsCounts() throws {
        let (c, store, _) = try makeController()
        var finishes: [(Bool, Int, Int)] = []
        c.onFinish = { finishes.append(($0, $1, $2)) }
        try c.start(minutes: 25)
        c.finish(completed: true)
        c.finish(completed: true)
        XCTAssertEqual(finishes.count, 1)
        XCTAssertNil(c.running)
        let row = try store.sessions(overlapping: .init(start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(60)))[0]
        XCTAssertTrue(row.completed)
    }
}
