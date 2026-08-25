import XCTest
@testable import TimeSinkKit

@MainActor
final class SpyNotifier: Notifying {
    var authorized = true
    var posted: [(id: String, title: String, body: String, route: NotificationRoute?)] = []
    /// Invoked synchronously inside `post`, BEFORE the call is appended to
    /// `posted` -- lets a test observe intermediate state (e.g. a store read)
    /// at the exact moment a post happens, to pin a caller's post-then-stamp
    /// ordering (Task 11 fix round, I4). `nil` by default: existing callers
    /// that never set it see no change in behavior.
    var onPost: (() -> Void)?
    func requestAuthorization() async -> Bool { authorized }
    func authorizationState() async -> PermissionState { authorized ? .granted : .denied }
    func post(id: String, title: String, body: String, route: NotificationRoute?) {
        onPost?()
        posted.append((id, title, body, route))
    }
}

final class NotifierTests: XCTestCase {
    @MainActor func testNoopNeverAuthorizes() async {
        let n = NoopNotifier()
        let ok = await n.requestAuthorization()
        XCTAssertFalse(ok)
        let state = await n.authorizationState()
        XCTAssertEqual(state, .denied)
        n.post(id: "x", title: "t", body: "b", route: nil)  // 不崩即通过
    }
    @MainActor func testFactoryReturnsNoopWithoutBundle() {
        // swift test 无 bundle id，必须拿到 Noop——这是整条崩溃门的回归测试
        XCTAssertTrue(NotifierFactory.make() is NoopNotifier)
    }

    // Fix for review Finding 2: a notification tap decoded before `onRoute`
    // is assigned (e.g. a cold launch from Notification Center) must not be
    // silently dropped -- it's buffered in `pendingRoute` and flushed once
    // `onRoute` is set. Exercises `TimeSinkAppDelegate.route(_:)` directly,
    // never touching `UNUserNotificationCenter`.
    @MainActor func testRouteBuffersWhenOnRouteUnsetThenFlushesOnAssign() {
        let delegate = TimeSinkAppDelegate()
        delegate.route(.settingsBudget)
        XCTAssertEqual(delegate.pendingRoute, .settingsBudget)

        var received: [NotificationRoute] = []
        delegate.onRoute = { received.append($0) }

        XCTAssertEqual(received, [.settingsBudget])
        XCTAssertNil(delegate.pendingRoute)
    }

    @MainActor func testRouteDeliversImmediatelyWhenOnRouteAlreadySet() {
        let delegate = TimeSinkAppDelegate()
        var received: [NotificationRoute] = []
        delegate.onRoute = { received.append($0) }

        delegate.route(.activitiesToday)

        XCTAssertEqual(received, [.activitiesToday])
        XCTAssertNil(delegate.pendingRoute)
    }
}
