import XCTest
@testable import TimeSinkKit

final class JevKeySaveTests: XCTestCase {
    private struct Boom: Error {}

    func testTrimsAndSaves() {
        var saved: String?
        XCTAssertEqual(JevSettingsPane.commitKey("  sk-or-1\n") { saved = $0 }, .saved)
        XCTAssertEqual(saved, "sk-or-1")
    }

    func testEmptyInputSavesNothing() {
        var called = false
        XCTAssertEqual(JevSettingsPane.commitKey("  \n") { _ in called = true }, .empty)
        XCTAssertFalse(called)
    }

    func testFailureReportsAndNeverEchoesKey() {
        guard case .failed(let message) = JevSettingsPane.commitKey("sk-secret", set: { _ in throw Boom() }) else { return XCTFail() }
        XCTAssertFalse(message.contains("sk-secret"))
    }
}
