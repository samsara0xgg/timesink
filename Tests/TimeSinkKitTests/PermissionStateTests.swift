import XCTest
@testable import TimeSinkKit

final class PermissionStateTests: XCTestCase {
    func testChromeStateMapping() {
        XCTAssertEqual(Permissions.chromeState(from: 0), .granted)          // noErr
        XCTAssertEqual(Permissions.chromeState(from: -600),
                       .unavailable("Chrome 未运行"))                        // procNotFound
        XCTAssertEqual(Permissions.chromeState(from: -1743), .denied)       // errAEEventNotPermitted
        XCTAssertEqual(Permissions.chromeState(from: -1744), .notDetermined) // errAEEventWouldRequireUserConsent
    }
}
