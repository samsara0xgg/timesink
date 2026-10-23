import XCTest
@testable import TimeSinkKit

private func streak(failures: Int, lastSuccess: Date = ts(0), screenshotsOK: Bool = true) -> OCRStreak {
    var s = OCRStreak(since: lastSuccess)
    for _ in 0..<failures { _ = s.noteFailure() }
    s.noteScreenshot(ok: screenshotsOK)
    return s
}

/// The relaunch decision: four conditions, then the once-only guard.
final class SelfHealDecisionTests: XCTestCase {
    let now = ts(SelfHeal.minSilence + 1)

    func testAllConditionsMetRelaunches() {
        XCTAssertEqual(SelfHeal.decide(streak: streak(failures: SelfHeal.minFailures), now: now,
                                       focusRunning: false, lastRelaunch: nil), .relaunch)
    }

    func testTooFewFailuresDoesNothing() {
        XCTAssertEqual(SelfHeal.decide(streak: streak(failures: SelfHeal.minFailures - 1), now: now,
                                       focusRunning: false, lastRelaunch: nil), .none)
    }

    func testRecentSuccessDoesNothing() {
        XCTAssertEqual(SelfHeal.decide(streak: streak(failures: 500), now: ts(SelfHeal.minSilence - 1),
                                       focusRunning: false, lastRelaunch: nil), .none)
        XCTAssertEqual(SelfHeal.decide(streak: streak(failures: 500), now: ts(SelfHeal.minSilence),
                                       focusRunning: false, lastRelaunch: nil), .relaunch)
    }

    func testFailingScreenshotsDoNothing() {
        XCTAssertEqual(SelfHeal.decide(streak: streak(failures: 500, screenshotsOK: false), now: now,
                                       focusRunning: false, lastRelaunch: nil), .none)
    }

    func testFocusSessionDoesNothing() {
        XCTAssertEqual(SelfHeal.decide(streak: streak(failures: 500), now: now,
                                       focusRunning: true, lastRelaunch: nil), .none)
        // Not even the notification while a session runs.
        XCTAssertEqual(SelfHeal.decide(streak: streak(failures: 500), now: now,
                                       focusRunning: true, lastRelaunch: now.addingTimeInterval(-60)), .none)
    }

    func testRecentRelaunchNotifiesInsteadOfRelaunching() {
        XCTAssertEqual(SelfHeal.decide(streak: streak(failures: 500), now: now, focusRunning: false,
                                       lastRelaunch: now.addingTimeInterval(-SelfHeal.relaunchGuard + 1)), .notify)
    }

    func testOldRelaunchAllowsAnother() {
        XCTAssertEqual(SelfHeal.decide(streak: streak(failures: 500), now: now, focusRunning: false,
                                       lastRelaunch: now.addingTimeInterval(-SelfHeal.relaunchGuard)), .relaunch)
    }

    func testSuccessEndsTheStreak() {
        var s = OCRStreak(since: ts(0))
        XCTAssertTrue(s.noteFailure())
        XCTAssertFalse(s.noteFailure())
        XCTAssertEqual(s.noteSuccess(at: ts(50)), 2)
        XCTAssertNil(s.noteSuccess(at: ts(60)))
        XCTAssertEqual(s.failures, 0)
        XCTAssertEqual(s.lastSuccess, ts(60))
        XCTAssertTrue(s.noteFailure(), "a new streak logs again")
    }
}

/// The monitor acts on the decision; the real quit-and-reopen is a closure.
@MainActor
final class SelfHealMonitorTests: XCTestCase {
    private func make(focus: @escaping () -> Bool = { false }) throws
        -> (SelfHealMonitor, SettingsStore, SpyNotifier, Counter) {
        let settings = SettingsStore(try AppDatabase.openInMemory())
        let notifier = SpyNotifier()
        let counter = Counter()
        let monitor = SelfHealMonitor(settings: settings, notifier: notifier, isFocusRunning: focus,
                                      relaunch: { counter.relaunches += 1 }, now: { ts(SelfHeal.minSilence + 1) },
                                      delay: .milliseconds(5))
        return (monitor, settings, notifier, counter)
    }

    final class Counter { var relaunches = 0 }

    func testRelaunchesOnceThenNotifiesWhenItHappensAgain() async throws {
        let (monitor, settings, notifier, counter) = try make()
        let bad = streak(failures: SelfHeal.minFailures)
        monitor.ocrStreakChanged(bad)
        monitor.ocrStreakChanged(bad)                     // same streak, still waiting: one relaunch only
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(counter.relaunches, 1)
        XCTAssertEqual(settings.get(SelfHeal.relaunchKey).flatMap(TimeInterval.init), ts(SelfHeal.minSilence + 1).timeIntervalSince1970)
        XCTAssertTrue(notifier.posted.isEmpty)

        // The new process starts, the streak comes back.
        monitor.ocrStreakChanged(bad)
        monitor.ocrStreakChanged(bad)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(counter.relaunches, 1, "no second relaunch")
        XCTAssertEqual(notifier.posted.count, 1, "one notification, not one per failure")
        XCTAssertEqual(notifier.posted.first?.id, "selfheal.ocr")
    }

    func testFocusSessionStartingDuringTheDelayCancelsTheRelaunch() async throws {
        var focus = false
        let (monitor, settings, _, counter) = try make(focus: { focus })
        monitor.ocrStreakChanged(streak(failures: SelfHeal.minFailures))
        focus = true
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(counter.relaunches, 0)
        XCTAssertNil(settings.get(SelfHeal.relaunchKey))
    }

    func testBelowThresholdNeverActs() async throws {
        let (monitor, _, notifier, counter) = try make()
        monitor.ocrStreakChanged(streak(failures: SelfHeal.minFailures - 1))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(counter.relaunches, 0)
        XCTAssertTrue(notifier.posted.isEmpty)
    }
}

/// OCR errors reach the log once per streak, and the collector tells the
/// monitor about every failure.
final class ScreenCollectorOCRFailureTests: XCTestCase {
    struct VisionDown: Error {}
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var logs: [String] = []
        var failuresSeen: [Int] = []
        var failing = true
    }

    func testErrorIsLoggedOncePerStreak() async throws {
        let store = ObservationStore(try AppDatabase.openInMemory())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let collector = ScreenCollector(store: store, imagesRoot: root, paused: false,
                                        policy: ScreenCapturePolicy(settleSeconds: 3, checkInterval: 10), refreshInterval: 5)
        let box = Box()
        let frame = ScreenCollectorDedupeTests.frame(lit: 0)
        await collector.install { _ in (image: frame, text: nil) }
        await collector.install(recognizer: { _ in
            if box.failing { throw VisionDown() }
            return "text"
        }, logOCRError: { message in box.lock.withLock { box.logs.append(message) } })
        await collector.setOnOCRFailure { streak in box.lock.withLock { box.failuresSeen.append(streak.failures) } }

        func run(_ seconds: ClosedRange<Int>) async {
            for t in seconds {
                let sample = Sample(timestamp: ts(TimeInterval(t)), appBundleID: "app.a", appName: "A",
                                    windowTitle: nil, url: nil, windowID: 1)
                await collector.tick(now: ts(TimeInterval(t)), sample: sample, spanID: nil)
            }
        }
        await run(0...33)                         // checks at 3, 13, 23, 33: four failures
        XCTAssertEqual(box.logs.count, 1)
        XCTAssertTrue(box.logs[0].contains("VisionDown"), "the real error, not a bare failure: \(box.logs[0])")
        XCTAssertEqual(box.failuresSeen, [1, 2, 3, 4])

        box.failing = false
        await run(34...43)                        // check at 43 reads text: streak over
        let afterSuccess = await collector.ocrStreak
        XCTAssertEqual(afterSuccess.failures, 0)

        box.failing = true
        await run(44...63)                        // checks at 53, 63 (the saved row's text is the same, so OCR runs again)
        XCTAssertEqual(box.logs.count, 2, "a second streak logs again")
        let health = await collector.health
        XCTAssertEqual(health.ocrFailed, 6)
    }
}
