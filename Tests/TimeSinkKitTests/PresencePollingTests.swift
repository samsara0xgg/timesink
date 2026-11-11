import XCTest
import CoreAudio
@testable import TimeSinkKit

final class PresencePollingTests: XCTestCase {
    typealias M = PresenceMonitor
    private let date = Date(timeIntervalSince1970: 1_000)
    private let apps = [
        M.App(pid: 10, bundleID: "us.zoom.xos", name: "Zoom", regular: true),
        M.App(pid: 20, bundleID: "com.google.Chrome", name: "Chrome", regular: true),
        M.App(pid: 30, bundleID: "org.python.jarvis", name: "Jarvis", regular: false)
    ]

    func testFilteredReadsPreserveCallVideoAndHelperAssertions() {
        let identities: [UInt32: (Int32, String)] = [
            1: (11, "us.zoom.CptHost"), 2: (21, "com.google.Chrome.helper"), 3: (30, "org.python.jarvis")
        ]
        for call in [false, true] {
            for video in [false, true] {
                for assertions: [pid_t] in [[], [10], [20], [21], [30]] {
                    var reader = M.AudioReader()
                    let full = identities.keys.sorted().map { object in
                        let identity = identities[object]!
                        return M.AudioProcess(pid: identity.0, bundleID: identity.1,
                                              input: object == 1 ? call : object == 3,
                                              output: object == 2 && video)
                    }
                    let actual = reader.read(objects: identities.keys.sorted(), apps: apps,
                                             displayAssertionPIDs: assertions, now: date,
                                             pid: { identities[$0]?.0 }, bundle: { identities[$0]?.1 },
                                             running: { object, selector in
                        let process = full[Int(object) - 1]
                        return selector == kAudioProcessPropertyIsRunningInput ? process.input : process.output
                    })
                    XCTAssertEqual(M.decide(audio: actual, displayAssertionPIDs: assertions, apps: apps, ownPID: 999),
                                   M.decide(audio: full, displayAssertionPIDs: assertions, apps: apps, ownPID: 999))
                }
            }
        }
    }

    func testStableIdentitiesAreCachedButLiveStateIsNot() {
        var reader = M.AudioReader(), bundleReads = 0, stateReads = 0
        var input = true
        func read(_ seconds: Double) -> [M.AudioProcess] {
            reader.read(objects: [1, 2], apps: apps, displayAssertionPIDs: [], now: date.addingTimeInterval(seconds),
                        pid: { Int32($0) }, bundle: { object in
                bundleReads += 1
                return object == 1 ? "us.zoom.CptHost" : "org.python.jarvis"
            }, running: { object, selector in
                stateReads += 1
                XCTAssertEqual(object, 1)
                return selector == kAudioProcessPropertyIsRunningInput ? input : false
            })
        }
        XCTAssertEqual(read(0).first?.input, true)
        input = false
        XCTAssertEqual(read(5).first?.input, false)
        XCTAssertEqual(bundleReads, 2, "one bundle read per process, not per poll")
        XCTAssertEqual(stateReads, 4, "only the call app's input and output; nothing for the assistant without display assertions")
        _ = read(60)
        XCTAssertEqual(bundleReads, 4, "bounded identity cache")
    }

    func testReusedRemovedAndFailedProcessIDsInvalidateIdentity() {
        var reader = M.AudioReader(), bundleReads = 0
        var processID: pid_t? = 10
        var bundle = "us.zoom.xos"
        func read(_ objects: [UInt32]) -> [M.AudioProcess] {
            reader.read(objects: objects, apps: apps, displayAssertionPIDs: [], now: date,
                        pid: { _ in processID }, bundle: { _ in bundleReads += 1; return bundle }, running: { _, _ in false })
        }
        XCTAssertEqual(read([1]).first?.bundleID, "us.zoom.xos")
        processID = 20; bundle = "com.google.Chrome"
        XCTAssertEqual(read([1]).first?.bundleID, bundle)
        XCTAssertEqual(bundleReads, 2)
        _ = read([]); _ = read([1])
        XCTAssertEqual(bundleReads, 3)
        processID = nil
        XCTAssertTrue(read([1]).isEmpty)
        processID = 20; _ = read([1])
        XCTAssertEqual(bundleReads, 4)
    }

    func testBackgroundReadDoesNotBlockTicksOrQueueDuplicateRefreshes() {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let count = Counter()
        let presence = Presence(kind: .call, bundleID: "us.zoom.xos", appName: "Zoom", onScreen: false)
        let monitor = M(readPresence: {
            count.increment(); started.signal(); release.wait()
            return presence
        })
        XCTAssertNil(monitor.cachedCurrent(now: date))
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        // The worker is blocked here. These calls must still return, and must not queue more work.
        for _ in 0..<20 { XCTAssertNil(monitor.cachedCurrent(now: date.addingTimeInterval(10))) }
        XCTAssertEqual(count.value, 1)
        release.signal()
        let stamped = Presence(kind: .call, bundleID: "us.zoom.xos", appName: "Zoom", onScreen: false, sampledAt: date)
        XCTAssertEqual(monitor.current(now: date.addingTimeInterval(1)), stamped)
        XCTAssertEqual(monitor.cachedCurrent(now: date.addingTimeInterval(1)), stamped)
        XCTAssertEqual(count.value, 1)
    }

    func testFiveSecondCadenceAndClockRollback() {
        let count = Counter()
        let monitor = M(readPresence: { count.increment(); return nil })
        _ = monitor.current(now: date)
        _ = monitor.current(now: date.addingTimeInterval(4))
        XCTAssertEqual(count.value, 1)
        _ = monitor.current(now: date.addingTimeInterval(5))
        XCTAssertEqual(count.value, 2)
        _ = monitor.current(now: date.addingTimeInterval(-1))
        XCTAssertEqual(count.value, 3)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        func increment() { lock.lock(); defer { lock.unlock() }; storage += 1 }
        var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    }
}
