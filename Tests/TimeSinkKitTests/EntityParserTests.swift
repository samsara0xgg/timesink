import XCTest
@testable import TimeSinkKit

final class EntityParserTests: XCTestCase {
    func testGitHubOwnerRepo() {
        let e = EntityParser.entity(urlString: "https://github.com/alllllenshi/timesink/pull/42?diff=split",
                                    domain: "github.com")
        XCTAssertEqual(e?.key, "github.com/alllllenshi/timesink")
        XCTAssertEqual(e?.label, "github.com / alllllenshi / timesink")
    }
    func testGitHubReservedAndBareOwner() {
        XCTAssertNil(EntityParser.entity(urlString: "https://github.com/settings/emails", domain: "github.com"))
        XCTAssertNil(EntityParser.entity(urlString: "https://github.com/login/oauth/authorize?state=xyz", domain: "github.com"))
        XCTAssertNil(EntityParser.entity(urlString: "https://github.com/samsara0xgg", domain: "github.com"))
    }
    func testYouTubeChannelOnlyExplicitPaths() {
        XCTAssertEqual(EntityParser.entity(urlString: "https://youtube.com/@3blue1brown/videos",
                                           domain: "youtube.com")?.key, "youtube.com/@3blue1brown")
        XCTAssertNil(EntityParser.entity(urlString: "https://youtube.com/watch?v=abc", domain: "youtube.com"))
    }
    func testOtherDomainsNil() {
        XCTAssertNil(EntityParser.entity(urlString: "https://arxiv.org/abs/1234.5678", domain: "arxiv.org"))
    }
}
