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

    // MARK: - Fix round 1, IMPORTANT 1 (uppercase reserved path) + FOLD-IN 9
    // (extended reservedGitHubPaths)

    func testGitHubReservedPathIsCaseInsensitive() {
        XCTAssertNil(EntityParser.entity(urlString: "https://github.com/SETTINGS/emails", domain: "github.com"))
    }

    func testGitHubTrendingIsReserved() {
        XCTAssertNil(EntityParser.entity(urlString: "https://github.com/trending/swift", domain: "github.com"))
    }

    // MARK: - Fix round 1, FOLD-IN 5 (lowercase entity keys, original-case labels)

    func testGitHubEntityKeyIsLowercasedForDedupButLabelKeepsCase() {
        let upper = EntityParser.entity(urlString: "https://github.com/Owner/Repo", domain: "github.com")
        let lower = EntityParser.entity(urlString: "https://github.com/owner/repo", domain: "github.com")
        XCTAssertEqual(upper?.key, lower?.key)
        XCTAssertEqual(upper?.key, "github.com/owner/repo")
        XCTAssertEqual(upper?.label, "github.com / Owner / Repo")
    }

    // MARK: - Fix round 1, FOLD-IN 7 (percent-encoded path segmentation +
    // decode-for-label + non-empty @handle)

    func testGitHubPercentEncodedSlashDoesNotFakeTwoSegments() {
        XCTAssertNil(EntityParser.entity(urlString: "https://github.com/owner%2Frepo", domain: "github.com"))
    }

    func testGitHubPercentDecodesSegmentsForLabel() {
        let e = EntityParser.entity(urlString: "https://github.com/my%20org/repo", domain: "github.com")
        XCTAssertEqual(e?.key, "github.com/my org/repo")
        XCTAssertEqual(e?.label, "github.com / my org / repo")
    }

    func testYouTubeBareAtSignIsNil() {
        XCTAssertNil(EntityParser.entity(urlString: "https://youtube.com/@", domain: "youtube.com"))
    }

    // MARK: - Fix round 1, FOLD-IN 8 (suffix-aware youtube domain match)

    func testYouTubeSubdomainIsSuffixAware() {
        let e = EntityParser.entity(urlString: "https://m.youtube.com/@3blue1brown", domain: "m.youtube.com")
        XCTAssertEqual(e?.key, "m.youtube.com/@3blue1brown")
    }

    // MARK: - Fix round 1, FOLD-IN 6 (merge /c/ and /user/, keep /channel/ distinct)

    func testYouTubeChannelIDStaysInItsOwnNamespace() {
        let e = EntityParser.entity(urlString: "https://youtube.com/channel/UCabc123", domain: "youtube.com")
        XCTAssertEqual(e?.key, "youtube.com/channel/ucabc123")
    }

    func testYouTubeCAndUserPrefixesShareOneKeyNamespace() {
        let viaC = EntityParser.entity(urlString: "https://youtube.com/c/veritasium", domain: "youtube.com")
        let viaUser = EntityParser.entity(urlString: "https://youtube.com/user/veritasium", domain: "youtube.com")
        XCTAssertEqual(viaC?.key, viaUser?.key)
        XCTAssertEqual(viaC?.key, "youtube.com/c/veritasium")
    }

    // MARK: - Fix round 1, IMPORTANT 3 / R-T9b (gitlab-specific branch)

    func testGitLabSubgroupProjectsStayDistinct() {
        let a = EntityParser.entity(urlString: "https://gitlab.com/group/subgroup/projA", domain: "gitlab.com")
        let b = EntityParser.entity(urlString: "https://gitlab.com/group/subgroup/projB", domain: "gitlab.com")
        XCTAssertEqual(a?.key, "gitlab.com/group/subgroup/proja")
        XCTAssertEqual(b?.key, "gitlab.com/group/subgroup/projb")
        XCTAssertNotEqual(a?.key, b?.key)
    }

    func testGitLabStripsAtDashSegment() {
        let e = EntityParser.entity(urlString: "https://gitlab.com/group/subgroup/proj/-/issues/12", domain: "gitlab.com")
        XCTAssertEqual(e?.key, "gitlab.com/group/subgroup/proj")
        XCTAssertEqual(e?.label, "gitlab.com / group / subgroup / proj")
    }

    func testGitLabReservedPathsAreNil() {
        XCTAssertNil(EntityParser.entity(urlString: "https://gitlab.com/dashboard/issues", domain: "gitlab.com"))
        XCTAssertNil(EntityParser.entity(urlString: "https://gitlab.com/users/sign_in", domain: "gitlab.com"))
    }

    func testGitLabBareDashSegmentIsNil() {
        XCTAssertNil(EntityParser.entity(urlString: "https://gitlab.com/-/profile", domain: "gitlab.com"))
    }
}
