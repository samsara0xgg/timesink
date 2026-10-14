import XCTest
@testable import TimeSinkKit

/// Chrome window `window` with AX title `title`. Hoisted out of the test
/// class for the same reason as `chromeSample` in TrackerEngineTests: the
/// provider is `@Sendable` and runs off the main actor.
private func chromeWindow(_ window: UInt32, title: String = "New Tab") -> @Sendable (Date) -> Sample? {
    { date in
        Sample(timestamp: date, appBundleID: "com.google.Chrome", appName: "Google Chrome",
               windowTitle: title, url: nil, windowID: window)
    }
}

final class ChromeThrottleWindowTests: XCTestCase {
    /// Two windows can share a title ("New Tab"), and only one of them may
    /// be private: another window is read at once.
    func testAnotherWindowIsFetchedEvenWithTheSameTitle() {
        var t = ChromeThrottle(interval: 5)
        t.noteFetched(title: "New Tab", window: 1, at: ts(0))
        XCTAssertFalse(t.shouldFetch(title: "New Tab", window: 1, at: ts(1)))
        XCTAssertTrue(t.shouldFetch(title: "New Tab", window: 2, at: ts(1)))
    }
}

/// Whether a browser window is private is a fact about that window, not
/// about the browser: what one window's read said must never be applied
/// to another, and a read that fails says nothing at all.
@MainActor
final class BrowserWindowPrivacyTests: XCTestCase {
    private func makeEngine() throws -> (TrackerEngine, SpanStore, SettingsStore) {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let settings = SettingsStore(db)
        let engine = TrackerEngine(spanStore: store, settings: settings)
        engine.idleSecondsProvider = { 0 }
        engine.chromeAutomationAuthorizedProvider = { true }
        return (engine, store, settings)
    }

    /// A private window opened next to a normal one, with the same title and
    /// inside the 5 s throttle, used to wear the normal window's page. It is
    /// now read on its own and left out.
    func testPrivateWindowWithTheSameTitleIsReadOnItsOwn() async throws {
        let (engine, _, _) = try makeEngine()
        engine.windowSampleProvider = chromeWindow(1)
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "chrome://newtab/", title: "New Tab", isIncognito: false)
        }
        await engine.tickAsync(now: ts(0))
        XCTAssertEqual(engine.latestSample?.url, "chrome://newtab/")

        engine.windowSampleProvider = chromeWindow(2)
        engine.chromeTabProvider = { ChromeSampler.TabInfo(url: nil, title: nil, isIncognito: true) }
        await engine.tickAsync(now: ts(1))
        XCTAssertNil(engine.latestSample)
    }

    /// A slow or backed-off read is not evidence that a window is normal: a
    /// window no read has vouched for keeps neither title nor URL, while one
    /// a read did find normal keeps its AX title.
    func testFailedReadKeepsTheTitleOnlyForAWindowFoundNotPrivate() async throws {
        let (engine, _, _) = try makeEngine()
        engine.windowSampleProvider = chromeWindow(1, title: "Docs")
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "https://docs.example.com", title: "Docs", isIncognito: false)
        }
        await engine.tickAsync(now: ts(0))

        engine.chromeTabProvider = { nil }
        engine.windowSampleProvider = chromeWindow(2, title: "Secret")
        await engine.tickAsync(now: ts(1))
        XCTAssertEqual(engine.latestSample?.appBundleID, "com.google.Chrome")
        XCTAssertNil(engine.latestSample?.windowTitle)
        XCTAssertNil(engine.latestSample?.url)

        engine.windowSampleProvider = chromeWindow(1, title: "Docs")
        await engine.tickAsync(now: ts(2))
        XCTAssertEqual(engine.latestSample?.windowTitle, "Docs")
        XCTAssertNil(engine.latestSample?.url)
    }

    /// A window once found private stays out when a later read of it fails,
    /// even with another window read in between.
    func testWindowFoundPrivateStaysOutWhenAReadFails() async throws {
        let (engine, _, _) = try makeEngine()
        engine.windowSampleProvider = chromeWindow(2, title: "Private")
        engine.chromeTabProvider = { ChromeSampler.TabInfo(url: nil, title: nil, isIncognito: true) }
        await engine.tickAsync(now: ts(0))

        engine.windowSampleProvider = chromeWindow(1, title: "Docs")
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "https://docs.example.com", title: "Docs", isIncognito: false)
        }
        await engine.tickAsync(now: ts(1))
        XCTAssertEqual(engine.latestSample?.url, "https://docs.example.com")

        engine.windowSampleProvider = chromeWindow(2, title: "Private")
        engine.chromeTabProvider = { nil }
        await engine.tickAsync(now: ts(2))
        XCTAssertNil(engine.latestSample)
    }

    /// A read can race the user switching windows. A "not private" answer
    /// filed under a window already found private records that read, but
    /// does not clear the private answer for when a later read fails.
    func testPrivateAnswerIsNotOverwritten() async throws {
        let (engine, _, _) = try makeEngine()
        engine.windowSampleProvider = chromeWindow(2, title: "Private")
        engine.chromeTabProvider = { ChromeSampler.TabInfo(url: nil, title: nil, isIncognito: true) }
        await engine.tickAsync(now: ts(0))

        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "https://docs.example.com", title: "Docs", isIncognito: false)
        }
        await engine.tickAsync(now: ts(6))
        XCTAssertEqual(engine.latestSample?.url, "https://docs.example.com")

        engine.chromeTabProvider = { nil }
        await engine.tickAsync(now: ts(12))
        XCTAssertNil(engine.latestSample)
    }

    /// "按网站记录浏览器" off: browsers record app time only, even for a
    /// window a read found normal before the switch was turned off.
    func testBrowserTrackingOffKeepsNoTitle() async throws {
        let (engine, _, settings) = try makeEngine()
        engine.windowSampleProvider = chromeWindow(1, title: "Docs")
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "https://docs.example.com", title: "Docs", isIncognito: false)
        }
        await engine.tickAsync(now: ts(0))

        settings.set("chromeTrackingEnabled", "false")
        await engine.tickAsync(now: ts(1))
        XCTAssertEqual(engine.latestSample?.appBundleID, "com.google.Chrome")
        XCTAssertNil(engine.latestSample?.windowTitle)
        XCTAssertNil(engine.latestSample?.url)
    }

    // MARK: - Focus blocking on ticks that are not recorded

    /// Focus blocking sees a private window's tick (an app it blocks is
    /// hidden there too), but gets no address unless it asked for one.
    func testFocusSeesPrivateTicksWithoutTheirAddress() async throws {
        let (engine, _, _) = try makeEngine()
        engine.windowSampleProvider = chromeWindow(2, title: "Private")
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "https://bilibili.com/video/x", title: nil, isIncognito: true)
        }
        var seen: [Sample] = []
        engine.focusInterceptor = { sample, _ in seen.append(sample); return false }
        await engine.tickAsync(now: ts(0))
        XCTAssertEqual(seen.count, 1)
        XCTAssertNil(seen.first?.url)
        XCTAssertNil(seen.first?.windowTitle)
        XCTAssertNil(engine.latestSample)
    }

    /// While a focus session blocks sites, a private Chrome tab on a blocked
    /// site is turned away like any other, and still nothing of it is
    /// recorded.
    func testFocusRedirectsABlockedSiteInAPrivateWindow() async throws {
        let db = try AppDatabase.openInMemory()
        let spanStore = SpanStore(db)
        let settings = SettingsStore(db)
        let engine = TrackerEngine(spanStore: spanStore, settings: settings)
        engine.idleSecondsProvider = { 0 }
        engine.chromeAutomationAuthorizedProvider = { true }
        engine.windowSampleProvider = chromeWindow(2, title: "Private")
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "https://bilibili.com/video/x", title: nil, isIncognito: true)
        }

        settings.setFocusBlockedCategories(["entertainment"])
        let controller = FocusSessionController(store: FocusSessionStore(db), settings: settings)
        controller.screenLocked = { false }
        controller.categoryForDomain = { domain, _ in domain == "bilibili.com" ? "entertainment" : "misc" }
        var redirected: [String] = []
        controller.redirectChrome = { redirected.append($0); return true }
        try controller.start(minutes: 25)
        engine.focusInterceptor = { sample, now in controller.intercept(sample: sample, at: now) }
        engine.focusNeedsPrivateTab = { controller.blocksSites(in: $0) }

        await engine.tickAsync(now: ts(0))
        XCTAssertEqual(redirected.count, 1)
        XCTAssertEqual(controller.siteBlocks, 1)
        XCTAssertNil(engine.latestSample)
        XCTAssertEqual(try spanStore.spans(overlapping: DateInterval(start: ts(-1), end: ts(100))).count, 0)
    }

    /// The address of a private tab is asked for only while a session
    /// blocks sites, and only in the browser it can redirect.
    func testPrivateAddressIsWantedOnlyWhileSitesAreBlocked() throws {
        let db = try AppDatabase.openInMemory()
        let settings = SettingsStore(db)
        settings.setFocusBlockedCategories(["entertainment"])
        let controller = FocusSessionController(store: FocusSessionStore(db), settings: settings)
        controller.screenLocked = { false }
        XCTAssertFalse(controller.blocksSites(in: "com.google.Chrome"))
        try controller.start(minutes: 25)
        XCTAssertTrue(controller.blocksSites(in: "com.google.Chrome"))
        XCTAssertFalse(controller.blocksSites(in: "company.thebrowser.Browser"))
        settings.setFocusSiteBlockEnabled(false)
        XCTAssertFalse(controller.blocksSites(in: "com.google.Chrome"))
    }

    /// An app left out of the record, or time away from the keyboard, is no
    /// way around a focus session either.
    func testFocusSeesExcludedAndIdleTicks() async throws {
        let (engine, _, settings) = try makeEngine()
        settings.setExcludedApps(["com.hnc.Discord"])
        engine.windowSampleProvider = { date in
            Sample(timestamp: date, appBundleID: "com.hnc.Discord", appName: "Discord", windowTitle: nil, url: nil)
        }
        var seen = 0
        engine.focusInterceptor = { _, _ in seen += 1; return false }
        await engine.tickAsync(now: ts(0))
        XCTAssertEqual(seen, 1)
        XCTAssertNil(engine.latestSample)

        settings.setExcludedApps([])
        engine.idleSecondsProvider = { 3600 }
        await engine.tickAsync(now: ts(1))
        XCTAssertEqual(seen, 2)
        XCTAssertNil(engine.latestSample)
    }
}
