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

    // MARK: - Fix round 1 (C1 + I2/I3/I5/I6 rulings): negative-test bundle

    /// C1: nothing previously pinned `intercept`'s terminal `return false`
    /// for an ordinary, unblocked sample -- mutating it to `return true`
    /// (which would silently stop ALL tracking for the rest of the session)
    /// left every prior test green.
    func testInterceptOfOrdinarySampleReturnsFalse() throws {
        let (c, _, _) = try makeController()
        try c.start(minutes: 25)
        let s = Sample(timestamp: ts(0), appBundleID: "com.apple.Terminal", appName: "Terminal",
                       windowTitle: "zsh", url: nil)
        XCTAssertFalse(c.intercept(sample: s, at: ts(0)))
    }

    /// Kills the appBlocks/siteBlocks column-swap mutation: 1 app block + 2
    /// site blocks must land as 1/2, not 2/1, in the persisted row.
    func testFinishPersistsAppAndSiteBlockCountsInCorrectColumns() throws {
        let (c, store, settings) = try makeController()
        settings.setFocusBlockedApps(["com.hnc.Discord"])
        settings.setFocusBlockedCategories(["entertainment"])
        c.categoryForDomain = { domain, _ in domain == "bilibili.com" ? "entertainment" : "misc" }
        c.redirectChrome = { _ in true }
        try c.start(minutes: 25)

        let appSample = Sample(timestamp: ts(0), appBundleID: "com.hnc.Discord", appName: "Discord",
                               windowTitle: nil, url: nil)
        _ = c.intercept(sample: appSample, at: ts(0))

        let siteSample1 = Sample(timestamp: ts(1), appBundleID: "com.google.Chrome", appName: "Chrome",
                                 windowTitle: "B 站", url: "https://bilibili.com/a")
        _ = c.intercept(sample: siteSample1, at: ts(1))
        // >= 10s cooldown later so the second redirect isn't itself gated.
        let siteSample2 = Sample(timestamp: ts(20), appBundleID: "com.google.Chrome", appName: "Chrome",
                                 windowTitle: "B 站 2", url: "https://bilibili.com/b")
        _ = c.intercept(sample: siteSample2, at: ts(20))

        c.finish(completed: false)
        let row = try store.sessions(overlapping: .init(start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(3600)))[0]
        XCTAssertEqual(row.appBlocks, 1)
        XCTAssertEqual(row.siteBlocks, 2)
    }

    /// A single `keepFocusTapped` call must NOT allow -- only a genuine
    /// double-tap within the 0.4s window does.
    func testSingleKeepFocusTapDoesNotAllow() throws {
        let (c, _, settings) = try makeController()
        settings.setFocusBlockedApps(["a"])
        try c.start(minutes: 25)
        c.keepFocusTapped(appKey: "a", at: ts(0))
        var hidden = 0
        c.hideApp = { _ in hidden += 1 }
        let s = Sample(timestamp: ts(1), appBundleID: "a", appName: "A", windowTitle: nil, url: nil)
        _ = c.intercept(sample: s, at: ts(1))
        XCTAssertEqual(hidden, 1)   // NOT allowed
    }

    /// Two taps 3s apart (well outside the 0.4s double-tap window) must NOT
    /// allow either.
    func testKeepFocusTapsThreeSecondsApartDoNotAllow() throws {
        let (c, _, settings) = try makeController()
        settings.setFocusBlockedApps(["a"])
        try c.start(minutes: 25)
        c.keepFocusTapped(appKey: "a", at: ts(0))
        c.keepFocusTapped(appKey: "a", at: ts(3))
        var hidden = 0
        c.hideApp = { _ in hidden += 1 }
        let s = Sample(timestamp: ts(4), appBundleID: "a", appName: "A", windowTitle: nil, url: nil)
        _ = c.intercept(sample: s, at: ts(4))
        XCTAssertEqual(hidden, 1)   // NOT allowed
    }

    /// R-T12c: the block-page check runs before the `running` guard -- a
    /// block-page sample is intercepted even with NO session running (e.g.
    /// the session just ended while the block page was still frontmost).
    func testBlockPageSampleInterceptedEvenWithNoRunningSession() throws {
        let (c, _, _) = try makeController()
        // Deliberately no `start()` call -- `running` is nil.
        let s = Sample(timestamp: ts(0), appBundleID: "com.google.Chrome", appName: "Chrome",
                       windowTitle: FocusBlockPage.pageMarkerTitle, url: nil)
        XCTAssertTrue(c.intercept(sample: s, at: ts(0)))
    }

    /// R-T12e: decision 5's degraded notice must not fire on the default
    /// config (site-block enabled, nothing actually chosen to block yet) --
    /// otherwise it announces a hide that never happened.
    func testDegradedNoticeSuppressedWhenNoBlockedCategories() throws {
        let (c, _, _) = try makeController()
        // focusSiteBlockEnabled defaults true; blockedCategories left empty.
        var hudCalls = 0
        c.showHUD = { _, _ in hudCalls += 1 }
        try c.start(minutes: 25)
        let s = Sample(timestamp: ts(0), appBundleID: "com.apple.Safari", appName: "Safari", windowTitle: nil, url: nil)
        XCTAssertFalse(c.intercept(sample: s, at: ts(0)))
        XCTAssertEqual(hudCalls, 0)
    }

    // MARK: - I3/R-T12b: decision 4 cooldown gate against stale replay

    /// Simulates the stale-`chromeTabState`-replay scenario the reviewer
    /// probed: the SAME blocked-domain sample delivered on consecutive
    /// ticks (as a throttled/backoff-skipped Chrome fetch would replay)
    /// must redirect at most once per cooldown window, not once per tick.
    func testSiteBlockRedirectGatedAgainstStaleReplay() throws {
        let (c, _, settings) = try makeController()
        settings.setFocusBlockedCategories(["entertainment"])
        c.categoryForDomain = { domain, _ in domain == "bilibili.com" ? "entertainment" : "misc" }
        var redirected: [String] = []
        c.redirectChrome = { redirected.append($0); return true }
        try c.start(minutes: 25)
        let s = Sample(timestamp: ts(0), appBundleID: "com.google.Chrome", appName: "Chrome",
                       windowTitle: "B 站", url: "https://bilibili.com/video/x")
        _ = c.intercept(sample: s, at: ts(0))
        _ = c.intercept(sample: s, at: ts(1))
        _ = c.intercept(sample: s, at: ts(2))
        XCTAssertEqual(redirected.count, 1)
        XCTAssertEqual(c.siteBlocks, 1)
    }

    // MARK: - S3: tick(now:) coverage

    func testTickCountdownDecrements() throws {
        let (c, _, _) = try makeController()
        try c.start(minutes: 25)
        let start = c.running!.start
        c.tick(now: start.addingTimeInterval(100))
        XCTAssertEqual(c.remaining, 1400, accuracy: 0.001)
    }

    /// The 30s heartbeat actually writes the store row's `end`.
    func testTick30sHeartbeatWritesStoreRow() throws {
        let (c, store, _) = try makeController()
        try c.start(minutes: 25)
        let start = c.running!.start
        c.tick(now: start.addingTimeInterval(30))
        let rows = try store.sessions(overlapping: .init(start: start.addingTimeInterval(-60), end: start.addingTimeInterval(60)))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].end.timeIntervalSince(start), 30, accuracy: 0.5)
    }

    /// I6/R-T12d pin: ticking far past expiry (simulating a missed-tick gap
    /// -- e.g. the lid closing mid-session) must clamp the persisted
    /// duration to exactly `plannedSeconds`, not the huge wall-clock jump
    /// `now` reports on the first post-wake tick.
    func testTickAutoFinishClampsDurationToPlannedSeconds() throws {
        let (c, store, _) = try makeController()
        try c.start(minutes: 25)
        let start = c.running!.start
        c.tick(now: start.addingTimeInterval(10_000))
        XCTAssertNil(c.running)
        let rows = try store.sessions(overlapping: .init(start: start.addingTimeInterval(-60), end: start.addingTimeInterval(20_000)))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].end.timeIntervalSince(rows[0].start), 1500, accuracy: 0.5)
        XCTAssertTrue(rows[0].completed)
    }

    /// A `tick` after `finish` (session already ended) is a no-op -- no
    /// crash, `remaining`/`running` unchanged.
    func testTickAfterFinishIsNoOp() throws {
        let (c, _, _) = try makeController()
        try c.start(minutes: 25)
        c.finish(completed: false)
        XCTAssertNil(c.running)
        c.tick(now: Date().addingTimeInterval(100))
        XCTAssertNil(c.running)
        XCTAssertEqual(c.remaining, 0)
    }

    // MARK: - Fold-in 7: double-start doesn't orphan the first row

    func testDoubleStartDoesNotOrphanFirstRow() throws {
        let (c, store, _) = try makeController()
        try c.start(minutes: 25)
        let firstID = c.running!.id
        try c.start(minutes: 45)   // no-op -- a session is already running
        XCTAssertEqual(c.running!.id, firstID)
        XCTAssertEqual(c.running!.plannedSeconds, 1500)   // still the first session's plan
        let rows = try store.sessions(overlapping: .init(start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(60)))
        XCTAssertEqual(rows.count, 1)
    }
}
