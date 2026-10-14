import XCTest
import GRDB
@testable import TimeSinkKit

/// A cloud whose push answers with a set error (or acks everything) and
/// whose pull returns one fixed page, counting the calls.
actor ScriptedCloud: SpanCloud {
    private var pushError: CloudError?
    private let rows: [SpanStore.RemoteSpan]
    private(set) var pulls = 0

    init(pushError: CloudError?, rows: [SpanStore.RemoteSpan]) {
        self.pushError = pushError
        self.rows = rows
    }

    func setPushError(_ error: CloudError?) { pushError = error }

    func push(deviceID: String, spans: [Span]) async throws -> [SpanAck] {
        if let pushError { throw pushError }
        var acks: [SpanAck] = []
        for span in spans {
            if let id = span.id { acks.append(SpanAck(originID: id, seq: "seq-\(id)")) }
        }
        return acks
    }

    func pull(since: String?, after: String?, excludingDevice: String) async throws -> PullPage {
        pulls += 1
        return PullPage(spans: rows, cursor: "cursor-1", more: false)
    }

    func deleteAccount() async throws {}
}

/// Audit findings 18, 20 and 22 on the client side: 429 backoff, pull pages
/// read row by row, and a pull that runs even when the push fails.
@MainActor
final class CloudFixesTests: XCTestCase {
    private func span(_ minute: Int) -> Span {
        let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(minute) * 60)
        return Span(start: start, end: start.addingTimeInterval(50), appBundleID: "com.test", appName: "T",
                    title: "t\(minute)", url: nil, domain: nil, document: nil)
    }

    func testWireCutsEachFieldToItsOwnCap() {
        var long = span(0)
        long.id = 3
        long.title = String(repeating: "標", count: 3000)
        long.document = String(repeating: "d", count: 2048)
        long.domain = String(repeating: "x", count: 300)
        let wire = HTTPCloud.wire(long)!
        XCTAssertEqual(wire.title?.unicodeScalars.count, HTTPCloud.FieldLimits.title)
        XCTAssertEqual(wire.document?.unicodeScalars.count, 2048)  // at the cap: untouched
        XCTAssertEqual(wire.domain?.unicodeScalars.count, HTTPCloud.FieldLimits.domain)
        XCTAssertEqual(wire.start, "2023-11-14T22:13:20.000Z")
    }

    /// One bad row used to fail its whole page, and the same page came back
    /// on every pass.
    func testPullPageSkipsUnreadableRowsAndKeepsItsCursor() throws {
        let json = """
            {"spans": [
              {"originId": 1, "deviceId": "dev-a", "seq": "s1", "start": "2026-09-22T10:00:00.000Z",
               "end": "2026-09-22T10:01:00.000Z", "appBundleID": "com.a", "appName": "A"},
              {"originId": 2, "deviceId": "dev-a", "seq": "s2", "start": "2026-09-22T10:00:00.000Z",
               "end": "2026-09-22T10:01:00.000Z", "appBundleID": "com.a"},
              {"originId": 3, "deviceId": "dev-a", "seq": "s3", "start": "yesterday",
               "end": "2026-09-22T10:01:00.000Z", "appBundleID": "com.a", "appName": "A"},
              {"originId": 4, "deviceId": "dev-a", "seq": "s4", "start": "2026-09-22T10:05:00.000Z",
               "end": "2026-09-22T10:01:00.000Z", "appBundleID": "com.a", "appName": "A"},
              {"originId": 5, "deviceId": "dev-a", "seq": "s5", "start": "2026-09-22T10:00:00Z",
               "end": "2026-09-22T10:01:00Z", "appBundleID": "com.a", "appName": "A", "title": "t"}
            ], "cursor": "s5", "more": true}
            """
        let page = try HTTPCloud.page(from: Data(json.utf8))
        XCTAssertEqual(page.spans.map(\.originID), [1, 5])
        XCTAssertEqual(page.skipped, 3)
        XCTAssertEqual(page.cursor, "s5")
        XCTAssertTrue(page.more)
        XCTAssertEqual(page.spans[0].span.duration, 60)
        XCTAssertEqual(page.spans[1].span.title, "t")
        XCTAssertEqual(page.spans[1].deviceID, "dev-a")
    }

    func testRetryAfterHeader() {
        XCTAssertEqual(HTTPCloud.retryAfter("30"), 30)
        XCTAssertEqual(HTTPCloud.retryAfter(" 7 "), 7)
        XCTAssertEqual(HTTPCloud.retryAfter(nil), 0)
        XCTAssertEqual(HTTPCloud.retryAfter("Wed, 21 Oct 2026 07:28:00 GMT"), 0)
        XCTAssertEqual(HTTPCloud.retryAfter("-5"), 0)
    }

    func testBackoffHonoursRetryAfterAndDoubles() {
        XCTAssertEqual(SyncEngine.backoff(retryAfter: 30, streak: 1, jitter: 0), 30)
        XCTAssertEqual(SyncEngine.backoff(retryAfter: 0, streak: 1, jitter: 0), 15)
        XCTAssertEqual(SyncEngine.backoff(retryAfter: 0, streak: 3, jitter: 0), 60)
        XCTAssertEqual(SyncEngine.backoff(retryAfter: 10, streak: 3, jitter: 0), 60)
        XCTAssertEqual(SyncEngine.backoff(retryAfter: 0, streak: 40, jitter: 0), 3600)
        XCTAssertEqual(SyncEngine.backoff(retryAfter: 86_400, streak: 1, jitter: 0), 3600)
        XCTAssertEqual(SyncEngine.backoff(retryAfter: 30, streak: 1, jitter: 1), 36, accuracy: 1e-9)
    }

    func testPullStillRunsWhenPushFails() async throws {
        let db = try AppDatabase.openInMemory()
        let spans = SpanStore(db)
        let settings = SettingsStore(db)
        try spans.insert(span(0))
        let remote = SpanStore.RemoteSpan(span: span(5), deviceID: "other-device", originID: 1, seq: "s1")
        let cloud = ScriptedCloud(pushError: .http(500, "boom"), rows: [remote])
        var pulledCallbacks = 0
        let engine = SyncEngine(spanStore: spans, settings: settings, cloud: cloud, openRowID: { nil },
                                onPulled: { pulledCallbacks += 1 })

        let result = await engine.syncNow()
        XCTAssertNil(result)
        let pulls = await cloud.pulls
        XCTAssertEqual(pulls, 1)
        XCTAssertEqual(engine.passPulled, 1)
        XCTAssertEqual(pulledCallbacks, 1)
        XCTAssertEqual(settings.cloudPullCursor, "cursor-1")
        XCTAssertNotNil(engine.lastError)
        XCTAssertNil(engine.retryAt)
        XCTAssertEqual(try spans.unsyncedCount(), 1)  // still waiting to go up
    }

    func testRateLimitBacksOffWithoutPullingThenClears() async throws {
        let db = try AppDatabase.openInMemory()
        let spans = SpanStore(db)
        let settings = SettingsStore(db)
        try spans.insert(span(0))
        let cloud = ScriptedCloud(pushError: .rateLimited(retryAfter: 30), rows: [])
        let engine = SyncEngine(spanStore: spans, settings: settings, cloud: cloud, openRowID: { nil }, onPulled: {})

        let before = Date()
        let first = await engine.syncNow()
        XCTAssertNil(first)
        let pullsAfterFirst = await cloud.pulls
        XCTAssertEqual(pullsAfterFirst, 0)
        let wait = try XCTUnwrap(engine.retryAt).timeIntervalSince(before)
        XCTAssertGreaterThanOrEqual(wait, 30)
        XCTAssertLessThanOrEqual(wait, 37)
        XCTAssertNotNil(engine.lastError)

        await cloud.setPushError(nil)
        let second = await engine.syncNow()
        XCTAssertEqual(second?.pushed, 1)
        XCTAssertNil(engine.retryAt)
        XCTAssertNil(engine.lastError)
    }
}
