import XCTest
@testable import TimeSinkKit

final class DomainParserTests: XCTestCase {
    func testStripsSchemeAndWWW() {
        XCTAssertEqual(DomainParser.domain(from: "https://www.YouTube.com/watch?v=x"), "youtube.com")
    }
    func testKeepsSubdomain() {
        XCTAssertEqual(DomainParser.domain(from: "https://mail.google.com/mail/u/0"), "mail.google.com")
    }
    func testNonWebURL() {
        XCTAssertNil(DomainParser.domain(from: "chrome://newtab"))
        XCTAssertNil(DomainParser.domain(from: "not a url"))
    }
}
