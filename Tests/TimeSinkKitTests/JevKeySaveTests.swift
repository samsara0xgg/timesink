import XCTest
@testable import TimeSinkKit

final class JevKeySaveTests: XCTestCase {
    private struct Boom: Error {}

    func testTrimsAndSaves() {
        var saved: String?
        XCTAssertEqual(JevSettingsPane.commitKey("  sk-or-1\n") { saved = $0 }, .saved)
        XCTAssertEqual(saved, "sk-or-1")
    }

    func testNonOpenRouterKeyIsRejectedWithoutSaving() {
        var called = false
        XCTAssertEqual(JevSettingsPane.commitKey("sk-abc") { _ in called = true }, .invalid)
        XCTAssertFalse(called)
    }

    func testSpendLine() {
        XCTAssertTrue(JevSettingsPane.spendLine(spend: 0.1, cap: 1).hasSuffix("$0.10 / $1"))
    }

    func testEmptyInputSavesNothing() {
        var called = false
        XCTAssertEqual(JevSettingsPane.commitKey("  \n") { _ in called = true }, .empty)
        XCTAssertFalse(called)
    }

    func testFailureReportsAndNeverEchoesKey() {
        guard case .failed(let message) = JevSettingsPane.commitKey("sk-or-secret", set: { _ in throw Boom() }) else { return XCTFail() }
        XCTAssertFalse(message.contains("sk-or-secret"))
    }
}
