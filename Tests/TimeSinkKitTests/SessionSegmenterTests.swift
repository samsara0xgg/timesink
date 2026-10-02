import XCTest
@testable import TimeSinkKit

final class SessionSegmenterTests: XCTestCase {
    /// Spans laid end to end from t=0: (app, category, minutes, document).
    /// A `nil` app is time away.
    private func day(_ parts: [(String?, String, Double, String?)]) -> [CategorizedSpan] {
        var cursor = 0.0
        var items: [CategorizedSpan] = []
        for (app, category, minutes, document) in parts {
            defer { cursor += minutes * 60 }
            guard let app else { continue }
            items.append(CategorizedSpan(span: Span(start: ts(cursor), end: ts(cursor + minutes * 60), appBundleID: app,
                                                    appName: app, title: "\(app) window", url: nil, domain: nil,
                                                    document: document.map { "file://\(DocumentIdentity.homePath)/Projects/\($0)/" }),
                                         categoryID: category))
        }
        return items
    }

    private func span(url: String? = nil, domain: String? = nil, document: String? = nil) -> Span {
        Span(start: ts(0), end: ts(60), appBundleID: "a", appName: "a", title: nil, url: url, domain: domain, document: document)
    }

    func testABareSiteIsNotAProject() {
        XCTAssertNil(SessionSegmenter.projectKey(span(url: "https://www.nytimes.com/", domain: "nytimes.com")))
    }

    func testARepoOnASiteIsAProject() {
        XCTAssertEqual(SessionSegmenter.projectKey(span(url: "https://github.com/owner/repo", domain: "github.com"))?.key, "repo")
    }

    func testAFolderUnderHomeIsAProjectButAFileDirectlyUnderHomeIsNot() {
        let home = DocumentIdentity.homePath
        XCTAssertEqual(SessionSegmenter.projectKey(span(document: "file://\(home)/Projects/x/file.swift"))?.key, "x")
        XCTAssertNil(SessionSegmenter.projectKey(span(document: "file://\(home)/notes.md")))
    }

    private func starts(_ parts: [(String?, String, Double, String?)], splits: [Date] = []) -> [Double] {
        SessionSegmenter.sessions(day(parts), splits: splits).map { $0.start.timeIntervalSince(ts(0)) / 60 }
    }

    func testAwayForTenMinutesStartsANewSession() {
        XCTAssertEqual(starts([("xcode", "softwareDev", 30, nil), (nil, "", 10, nil), ("xcode", "softwareDev", 30, nil)]), [0, 40])
    }

    func testAJoinedCutAndAJoinedAbsenceStayInside() {
        let change: [(String?, String, Double, String?)] = [("xcode", "softwareDev", 30, nil), ("mail", "business", 10, nil)]
        XCTAssertEqual(SessionSegmenter.sessions(day(change), joins: [ts(30 * 60)]).count, 1)
        let away: [(String?, String, Double, String?)] = [("xcode", "softwareDev", 30, nil), (nil, "", 10, nil), ("xcode", "softwareDev", 30, nil)]
        XCTAssertEqual(SessionSegmenter.sessions(day(away), joins: [ts(40 * 60)]).count, 1)
        XCTAssertEqual(SessionSegmenter.sessions(day(away)).count, 2)
    }

    func testAwayForLessThanTenMinutesStaysInside() {
        XCTAssertEqual(starts([("xcode", "softwareDev", 30, nil), (nil, "", 9, nil), ("xcode", "softwareDev", 30, nil)]), [0])
    }

    func testACategoryChangeThatLastsTenMinutesStartsANewSession() {
        XCTAssertEqual(starts([("xcode", "softwareDev", 30, nil), ("mail", "business", 10, nil)]), [0, 30])
    }

    func testAnExcursionUnderTenMinutesStaysInside() {
        XCTAssertEqual(starts([("xcode", "softwareDev", 30, nil), ("mail", "business", 9, nil), ("xcode", "softwareDev", 30, nil)]), [0])
    }

    func testGlancesDoNotBreakAChangeThatStays() {
        // Six minutes of mail, a half-minute back in Xcode, six more of mail:
        // the change lasted twelve minutes.
        XCTAssertEqual(starts([("xcode", "softwareDev", 30, nil), ("mail", "business", 6, nil),
                               ("xcode", "softwareDev", 0.5, nil), ("mail", "business", 6, nil)]), [0, 30])
    }

    func testBackAndForthBetweenAppsOfOneTaskIsOneSession() {
        var parts: [(String?, String, Double, String?)] = []
        for _ in 0..<9 { parts += [("xcode", "softwareDev", 6, "timesink"), ("chatgpt", "aiTools", 4, nil)] }
        XCTAssertEqual(starts(parts), [0])
    }

    func testAProjectChangeInTheSameCategoryStartsANewSession() {
        XCTAssertEqual(starts([("xcode", "softwareDev", 30, "timesink"), ("xcode", "softwareDev", 20, "jarvis")]), [0, 30])
    }

    func testTheSameProjectAcrossAppsIsOneSession() {
        let items = day([("xcode", "softwareDev", 20, "timesink"), ("ghostty", "softwareDev", 20, "timesink")])
        let sessions = SessionSegmenter.sessions(items)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.project, "timesink")
    }

    func testAShortLeadInJoinsTheSessionItLedInto() {
        XCTAssertEqual(starts([("mail", "business", 3, nil), ("xcode", "softwareDev", 40, nil)]), [0])
    }

    func testAUserSplitIsKept() {
        XCTAssertEqual(starts([("xcode", "softwareDev", 60, nil)], splits: [ts(25 * 60)]), [0, 25])
    }

    func testTheThresholdIsAdjustable() {
        let items = day([("xcode", "softwareDev", 30, nil), (nil, "", 6, nil), ("xcode", "softwareDev", 30, nil)])
        XCTAssertEqual(SessionSegmenter.sessions(items, threshold: 300).count, 2)
        XCTAssertEqual(SessionSegmenter.sessions(items, threshold: 600).count, 1)
    }

    func testCompositionIgnoresGrowth() {
        let short = SessionSegmenter.sessions(day([("xcode", "softwareDev", 20, "timesink"), ("ghostty", "softwareDev", 5, "timesink")]))[0]
        let longer = SessionSegmenter.sessions(day([("xcode", "softwareDev", 30, "timesink"), ("ghostty", "softwareDev", 8, "timesink")]))[0]
        XCTAssertEqual(short.nameKey, longer.nameKey)
    }
}
