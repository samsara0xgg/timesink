import GRDB
import XCTest
import os
@testable import TimeSinkKit

// MARK: - Clock jumps

final class SpanBuilderClockJumpTests: XCTestCase {
    /// The clock set back mid-span: extending would drag `end` before
    /// `start`. The open span closes at its last good end and a new one
    /// opens at the earlier time.
    func testSampleBeforeTheOpenSpanStartsANewSpan() {
        let b = SpanBuilder()
        _ = b.ingest(sample(100)); _ = b.ingest(sample(101))
        let closed = b.ingest(sample(40))
        XCTAssertEqual(closed?.start, ts(100))
        XCTAssertEqual(closed?.end, ts(102))
        XCTAssertEqual(b.current?.start, ts(40))
        XCTAssertEqual(b.current?.end, ts(41))
    }

    /// A repeated or slightly early timestamp (timer jitter) still extends.
    func testSameTimestampStillExtends() {
        let b = SpanBuilder()
        _ = b.ingest(sample(0)); _ = b.ingest(sample(1))
        XCTAssertNil(b.ingest(sample(1)))
        XCTAssertEqual(b.current?.start, ts(0))
        XCTAssertGreaterThanOrEqual(b.current!.end, b.current!.start)
    }
}

// MARK: - Engine: lock backdating, idle trimming, meeting exemption, self-healing

/// Mail's window title changes by itself (unread count) at t=20 and t=40.
private func driftingSample(at date: Date) -> Sample {
    let t = date.timeIntervalSince(ts(0))
    let title = t < 20 ? "Inbox (1)" : (t < 40 ? "Inbox (2)" : "Inbox (3)")
    return Sample(timestamp: date, appBundleID: "com.example.mail", appName: "Mail", windowTitle: title, url: nil)
}

private func editorSample(at date: Date) -> Sample {
    Sample(timestamp: date, appBundleID: "com.example.editor", appName: "Editor", windowTitle: "main.swift", url: nil)
}

private func makeCapture(at t: TimeInterval, app: String = "com.example.editor", spanID: Int64?) -> Capture {
    Capture(at: ts(t), lastSeenAt: ts(t), appBundleID: app, appName: app, windowID: 1,
            title: nil, spanID: spanID, text: "text", imagePath: nil)
}

@MainActor
final class TrackerEngineTrackingFixesTests: XCTestCase {
    private struct Rig {
        let db: DatabaseQueue
        let spans: SpanStore
        let observations: ObservationStore
        let settings: SettingsStore
        let engine: TrackerEngine
    }

    private func makeRig(idleThreshold: TimeInterval? = nil) throws -> Rig {
        let db = try AppDatabase.openInMemory()
        let spans = SpanStore(db)
        let observations = ObservationStore(db)
        let settings = SettingsStore(db)
        if let idleThreshold { settings.setIdleThreshold(idleThreshold) }
        let engine = TrackerEngine(spanStore: spans, settings: settings, observations: observations)
        engine.screenLockedProvider = { false }
        return Rig(db: db, spans: spans, observations: observations, settings: settings, engine: engine)
    }

    private func rows(_ db: DatabaseQueue) throws -> [Span] {
        try db.read { db in try Span.fetchAll(db, sql: "SELECT * FROM span ORDER BY id") }
    }

    private func spanID(ofCaptureAt t: TimeInterval, _ db: DatabaseQueue) throws -> Int64? {
        try db.read { db in try Int64.fetchOne(db, sql: "SELECT spanID FROM capture WHERE at = ?", arguments: [ts(t)]) }
    }

    /// #5: the screen locked 90 s after the last input (display sleep, then
    /// "require password"): the span ends at the last input, not at the lock.
    func testLockAfterUnattendedStretchBackdatesToLastInput() async throws {
        let rig = try makeRig()
        var now: TimeInterval = 0
        rig.engine.idleSecondsProvider = { max(0, now - 30) }   // last input at t=30
        rig.engine.windowSampleProvider = { editorSample(at: $0) }
        for t in 0...119 {
            now = TimeInterval(t)
            await rig.engine.tickAsync(now: ts(now))
        }
        now = 120
        rig.engine.suspend(at: ts(120))

        let written = try rows(rig.db)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written[0].start, ts(0))
        XCTAssertEqual(written[0].end, ts(30))
        let events = try rig.observations.stateEvents(in: DateInterval(start: ts(-1), end: ts(1000)))
        XCTAssertEqual(events.map(\.kind), ["lock"])
        XCTAssertEqual(events[0].at, ts(30))
    }

    /// A lock right after input (the user pressed ⌃⌘Q) is not backdated.
    func testLockRightAfterInputClosesAtTheLock() async throws {
        let rig = try makeRig()
        rig.engine.idleSecondsProvider = { 2 }
        rig.engine.windowSampleProvider = { editorSample(at: $0) }
        for t in 0...40 { await rig.engine.tickAsync(now: ts(TimeInterval(t))) }
        rig.engine.suspend(at: ts(41))
        XCTAssertEqual(try rows(rig.db).map(\.end), [ts(41)])
    }

    /// #6: spans written after the last input (the title changed by itself
    /// while the user was away) are trimmed too, re-marked for sync, and
    /// their captures from the idle tail are unfiled.
    func testBecomingIdleTrimsSpansWrittenSinceTheLastInput() async throws {
        let rig = try makeRig(idleThreshold: 60)
        var now: TimeInterval = 0
        rig.engine.idleSecondsProvider = { max(0, now - 10) }   // last input at t=10
        rig.engine.windowSampleProvider = { driftingSample(at: $0) }
        for t in 0...45 {
            now = TimeInterval(t)
            await rig.engine.tickAsync(now: ts(now))
        }
        let before = try rows(rig.db)
        XCTAssertEqual(before.map(\.title), ["Inbox (1)", "Inbox (2)"])
        XCTAssertEqual(before.map(\.end), [ts(20), ts(40)])
        let first = try XCTUnwrap(before[0].id), second = try XCTUnwrap(before[1].id)
        try rig.spans.markSynced([(id: first, seq: "seq-1")])
        try rig.observations.insert(makeCapture(at: 5, app: "com.example.mail", spanID: first))
        try rig.observations.insert(makeCapture(at: 15, app: "com.example.mail", spanID: first))
        try rig.observations.insert(makeCapture(at: 25, app: "com.example.mail", spanID: second))

        for t in 46...70 {
            now = TimeInterval(t)
            await rig.engine.tickAsync(now: ts(now))   // idle from t=70, backdated to t=10
        }

        let after = try rows(rig.db)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[0].start, ts(0))
        XCTAssertEqual(after[0].end, ts(10))
        XCTAssertEqual(after[1].start, ts(20))
        XCTAssertEqual(after[1].end, ts(20))   // all of it was idle
        // Pushed again: the cloud copy still has the idle tail.
        let unsynced = try rig.spans.unsynced(excluding: nil, limit: 10).compactMap(\.id)
        XCTAssertTrue(unsynced.contains(first))
        XCTAssertEqual(try spanID(ofCaptureAt: 5, rig.db), first)
        XCTAssertNil(try spanID(ofCaptureAt: 15, rig.db))
        XCTAssertNil(try spanID(ofCaptureAt: 25, rig.db))
    }

    /// #7: a calendar meeting keeps an active span from going idle, but it
    /// never wakes an idle state -- left before the meeting, still away.
    func testMeetingDoesNotWakeAnAlreadyIdleState() async throws {
        let rig = try makeRig(idleThreshold: 60)
        var idle: TimeInterval = 0
        var inMeeting = false
        rig.engine.idleSecondsProvider = { idle }
        rig.engine.isInMeetingProvider = { inMeeting }
        rig.engine.windowSampleProvider = { editorSample(at: $0) }

        await rig.engine.tickAsync(now: ts(0))
        idle = 100
        await rig.engine.tickAsync(now: ts(100))
        XCTAssertTrue(rig.engine.isSuspended)
        inMeeting = true
        idle = 101
        await rig.engine.tickAsync(now: ts(101))
        XCTAssertTrue(rig.engine.isSuspended)       // the meeting did not bring it back
        idle = 0
        await rig.engine.tickAsync(now: ts(102))
        XCTAssertFalse(rig.engine.isSuspended)      // input did
        idle = 200
        await rig.engine.tickAsync(now: ts(103))
        XCTAssertFalse(rig.engine.isSuspended)      // and the meeting now keeps it active
    }

    /// #8: a missed `screenIsUnlocked` heals on the next lock re-check.
    func testMissedUnlockHealsOnRecheck() async throws {
        let rig = try makeRig()
        var locked = true
        rig.engine.screenLockedProvider = { locked }
        rig.engine.idleSecondsProvider = { 0 }
        rig.engine.windowSampleProvider = { editorSample(at: $0) }

        rig.engine.suspend(at: ts(0))
        await rig.engine.tickAsync(now: ts(11))
        XCTAssertTrue(rig.engine.isSuspended)       // still locked
        locked = false
        await rig.engine.tickAsync(now: ts(15))
        XCTAssertTrue(rig.engine.isSuspended)       // next re-check not due yet
        await rig.engine.tickAsync(now: ts(21))
        XCTAssertFalse(rig.engine.isSuspended)
        XCTAssertEqual(rig.engine.latestSample?.timestamp, ts(21))
    }

    /// The first re-check waits a full interval after the suspension: a
    /// `willSleep` arrives while the screen still reads unlocked.
    func testNoRecheckRightAfterSuspending() async throws {
        let rig = try makeRig()
        rig.engine.idleSecondsProvider = { 0 }
        rig.engine.windowSampleProvider = { editorSample(at: $0) }
        rig.engine.suspend(at: ts(0), source: .sleep)
        await rig.engine.tickAsync(now: ts(2))
        XCTAssertTrue(rig.engine.isSuspended)
    }

    func testWakeTrustsOnlyAnUnlockedScreen() throws {
        let rig = try makeRig()
        var locked = true
        rig.engine.screenLockedProvider = { locked }
        rig.engine.idleSecondsProvider = { 0 }
        rig.engine.suspend(at: ts(0), source: .sleep)
        rig.engine.resume(source: .wake)
        XCTAssertTrue(rig.engine.isSuspended)
        locked = false
        rig.engine.resume(source: .wake)
        XCTAssertFalse(rig.engine.isSuspended)
    }

    /// #25: captures taken before the span's first write are filed under it
    /// when it is inserted, and late ones when it closes; captures outside
    /// the span (idle, another app) stay unfiled.
    func testCapturesBeforeTheFirstWriteAreFiledUnderTheSpan() async throws {
        let rig = try makeRig()
        rig.engine.idleSecondsProvider = { 0 }
        rig.engine.windowSampleProvider = { editorSample(at: $0) }
        try rig.observations.insert(makeCapture(at: -10, spanID: nil))
        try rig.observations.insert(makeCapture(at: 5, spanID: nil))
        try rig.observations.insert(makeCapture(at: 6, app: "com.example.other", spanID: nil))

        for t in 0...30 { await rig.engine.tickAsync(now: ts(TimeInterval(t))) }
        let row = try XCTUnwrap(rig.engine.currentRowID)
        XCTAssertEqual(try spanID(ofCaptureAt: 5, rig.db), row)
        XCTAssertNil(try spanID(ofCaptureAt: -10, rig.db))
        XCTAssertNil(try spanID(ofCaptureAt: 6, rig.db))

        // An OCR still running at the insert lands afterwards with no span.
        try rig.observations.insert(makeCapture(at: 12, spanID: nil))
        try rig.observations.insert(makeCapture(at: 50, spanID: nil))   // after the span
        for t in 31...35 { await rig.engine.tickAsync(now: ts(TimeInterval(t))) }
        rig.engine.stop()
        XCTAssertEqual(try spanID(ofCaptureAt: 12, rig.db), row)
        XCTAssertNil(try spanID(ofCaptureAt: 50, rig.db))
    }
}

// MARK: - Lock signals

@MainActor
final class SystemMonitorLockSignalTests: XCTestCase {
    /// Only a true duplicate is dropped: a lock right after a fast unlock is
    /// a real lock.
    func testLockUnlockLockWithinASecondAreAllDelivered() {
        let monitor = SystemMonitor()
        var events: [String] = []
        monitor.onSuspend = { _, _ in events.append("lock") }
        monitor.onResume = { _, _ in events.append("unlock") }
        let t = Date()
        monitor.debouncedLock(suspend: true, at: t)
        monitor.debouncedLock(suspend: false, at: t.addingTimeInterval(0.3))
        monitor.debouncedLock(suspend: true, at: t.addingTimeInterval(0.6))
        monitor.debouncedLock(suspend: true, at: t.addingTimeInterval(0.9))   // duplicate, dropped
        XCTAssertEqual(events, ["lock", "unlock", "lock"])
    }
}

final class IdleMonitorTests: XCTestCase {
    /// Exercises the any-input event type (a force-unwrapped raw value).
    func testIdleReadingIsANumber() {
        XCTAssertFalse(IdleMonitor().idleSeconds().isNaN)
    }
}

// MARK: - Calendar availability

final class CalendarAvailabilityTests: XCTestCase {
    private func event(isFree: Bool) -> CalendarEvent {
        CalendarEvent(id: "e", title: "All-hands lunch talk", start: ts(0), end: ts(3600), isAllDay: false,
                      attendeeCount: 30, isDeclined: false, calendarTitle: "Work", colorHex: "#000000",
                      isFree: isFree)
    }

    func testFreeEventIsNotAMeeting() {
        XCTAssertFalse(event(isFree: true).isMeeting)
        XCTAssertTrue(event(isFree: false).isMeeting)
        XCTAssertFalse(MeetingTagger.inMeeting(at: ts(60), events: [event(isFree: true)]))
    }
}

// MARK: - Capture retention

final class CaptureRetentionTextTests: XCTestCase {
    /// #17: expiry takes the OCR text with the row, by when it was last seen.
    func testForgetCapturesDeletesRowsLastSeenBeforeTheCutoff() throws {
        let store = ObservationStore(try AppDatabase.openInMemory())
        try store.insert(Capture(at: ts(0), lastSeenAt: ts(10), appBundleID: "x", appName: "X", windowID: 1,
                                 title: nil, spanID: nil, text: "old secret", imagePath: nil))
        try store.insert(Capture(at: ts(0), lastSeenAt: ts(100), appBundleID: "x", appName: "X", windowID: 1,
                                 title: nil, spanID: nil, text: "still on screen", imagePath: nil))
        XCTAssertEqual(try store.forgetCaptures(before: ts(50)), 1)
        let left = try store.captures(overlapping: DateInterval(start: ts(-1), end: ts(1000)))
        XCTAssertEqual(left.map(\.text), ["still on screen"])
    }

    func testPasswordManagersAreNeverCaptured() {
        for id in ["com.agilebits.onepassword7", "org.keepassx.keepassxc", "com.dashlane.Dashlane", "in.sinew.Enpass-Desktop"] {
            XCTAssertTrue(ScreenCollector.excludedBundleIDs.contains(id), id)
        }
    }
}

// MARK: - Focus sessions

@MainActor
final class FocusSessionFixesTests: XCTestCase {
    private func make(_ db: DatabaseQueue) -> (FocusSessionController, FocusSessionStore, SettingsStore) {
        let store = FocusSessionStore(db)
        let settings = SettingsStore(db)
        let controller = FocusSessionController(store: store, settings: settings)
        controller.screenLocked = { false }
        return (controller, store, settings)
    }

    private func onlyRow(_ store: FocusSessionStore, around start: Date) throws -> FocusSession {
        let rows = try store.sessions(overlapping: .init(start: start.addingTimeInterval(-60), end: start.addingTimeInterval(20_000)))
        XCTAssertEqual(rows.count, 1)
        return try XCTUnwrap(rows.first)
    }

    /// #26b: the planned end passed while the screen was locked: not
    /// completed, and it ends when the lock was first seen.
    func testSessionLockedThroughItsEndIsNotCompleted() throws {
        let (c, store, _) = make(try AppDatabase.openInMemory())
        var locked = false
        c.screenLocked = { locked }
        var outcomes: [Bool] = []
        c.onFinish = { completed, _, _ in outcomes.append(completed) }
        try c.start(minutes: 1)
        let start = c.running!.start
        c.tick(now: start.addingTimeInterval(10))
        locked = true
        for t in stride(from: 20.0, through: 60, by: 10) { c.tick(now: start.addingTimeInterval(t)) }
        XCTAssertNil(c.running)
        XCTAssertEqual(outcomes, [false])
        let row = try onlyRow(store, around: start)
        XCTAssertFalse(row.completed)
        XCTAssertEqual(row.end.timeIntervalSince(row.start), 20, accuracy: 0.5)
    }

    /// A lock that is over before the planned end changes nothing.
    func testShortLockMidSessionStillCompletes() throws {
        let (c, store, _) = make(try AppDatabase.openInMemory())
        var locked = false
        c.screenLocked = { locked }
        try c.start(minutes: 1)
        let start = c.running!.start
        locked = true
        c.tick(now: start.addingTimeInterval(10))
        locked = false
        for t in stride(from: 20.0, through: 60, by: 10) { c.tick(now: start.addingTimeInterval(t)) }
        XCTAssertTrue(try onlyRow(store, around: start).completed)
    }

    /// #26a + #26c: the session the process died in comes back on the next
    /// launch, with the blocks its heartbeat saved; once finished it does not.
    func testUnfinishedSessionIsRestoredWithItsBlocks() throws {
        let db = try AppDatabase.openInMemory()
        let (first, _, settings) = make(db)
        settings.setFocusBlockedApps(["com.hnc.Discord"])
        first.hideApp = { _ in }
        first.showHUD = { _, _ in }
        try first.start(minutes: 25)
        let id = first.running!.id, start = first.running!.start
        let discord = Sample(timestamp: ts(0), appBundleID: "com.hnc.Discord", appName: "Discord", windowTitle: nil, url: nil)
        _ = first.intercept(sample: discord, at: ts(0))
        first.tick(now: start.addingTimeInterval(30))   // heartbeat: end and block counts
        // The process dies here: no finish.

        let (second, _, _) = make(db)
        XCTAssertTrue(second.restoreUnfinished(now: start.addingTimeInterval(60)))
        XCTAssertEqual(second.running?.id, id)
        XCTAssertEqual(second.remaining, 1440, accuracy: 0.001)
        XCTAssertEqual(second.appBlocks, 1)
        second.finish(completed: false)

        let (third, _, _) = make(db)
        XCTAssertFalse(third.restoreUnfinished(now: start.addingTimeInterval(90)))
        XCTAssertNil(third.running)
    }

    /// Relaunched after the planned end: nothing resumes, the row keeps its
    /// last heartbeat and stays not completed.
    func testExpiredUnfinishedSessionIsNotRestored() throws {
        let db = try AppDatabase.openInMemory()
        let (first, store, _) = make(db)
        try first.start(minutes: 25)
        let start = first.running!.start
        first.tick(now: start.addingTimeInterval(30))

        let (second, _, _) = make(db)
        XCTAssertFalse(second.restoreUnfinished(now: start.addingTimeInterval(4000)))
        XCTAssertNil(second.running)
        let row = try onlyRow(store, around: start)
        XCTAssertFalse(row.completed)
        XCTAssertEqual(row.end.timeIntervalSince(start), 30, accuracy: 0.5)
        XCTAssertFalse(make(db).0.restoreUnfinished(now: start.addingTimeInterval(60)))   // marker gone
    }

    /// Callers take `.last` as the latest session.
    func testSessionsComeBackInStartOrder() throws {
        let store = FocusSessionStore(try AppDatabase.openInMemory())
        let later = try store.start(at: ts(100), plannedSeconds: 60)
        let earlier = try store.start(at: ts(0), plannedSeconds: 60)
        try store.heartbeat(id: later.id!, end: ts(160))
        try store.heartbeat(id: earlier.id!, end: ts(60))
        let starts = try store.sessions(overlapping: DateInterval(start: ts(-1), end: ts(1000))).map(\.start)
        XCTAssertEqual(starts, [ts(0), ts(100)])
    }

    /// #24: the off-actor redirect counts the block once it comes back.
    func testOffActorRedirectCountsTheBlockWhenItReturns() async throws {
        let (c, _, settings) = make(try AppDatabase.openInMemory())
        settings.setFocusBlockedCategories(["entertainment"])
        c.categoryForDomain = { domain, _ in domain == "bilibili.com" ? "entertainment" : "misc" }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        c.redirectChromeOffActor = { _ in
            calls.withLock { $0 += 1 }
            return true
        }
        try c.start(minutes: 25)
        let s = Sample(timestamp: ts(0), appBundleID: "com.google.Chrome", appName: "Chrome",
                       windowTitle: "B 站", url: "https://bilibili.com/video/x")
        XCTAssertFalse(c.intercept(sample: s, at: ts(0)))
        var waited = 0
        while c.siteBlocks == 0, waited < 200 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        XCTAssertEqual(c.siteBlocks, 1)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        c.finish(completed: false)
    }
}
