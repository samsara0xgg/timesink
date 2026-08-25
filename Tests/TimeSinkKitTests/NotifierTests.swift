import XCTest
@testable import TimeSinkKit

@MainActor
final class SpyNotifier: Notifying {
    var authorized = true
    var posted: [(id: String, title: String, body: String, route: NotificationRoute?)] = []
    func requestAuthorization() async -> Bool { authorized }
    func authorizationState() async -> PermissionState { authorized ? .granted : .denied }
    func post(id: String, title: String, body: String, route: NotificationRoute?) {
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
}
