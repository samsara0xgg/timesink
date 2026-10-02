import XCTest
@testable import TimeSinkKit

final class InterruptionClassifierTests: XCTestCase {
    private let productivity = ["softwareDev": 2, "business": 1, "communication": 0, "socialMedia": -2,
                                "misc": 0, "uncategorized": 0, "news": -1]
    private let distracting: Set<String> = ["communication", "socialMedia", "entertainment", "news"]

    /// Spans laid end to end from t=0: (app, category, seconds, keySeconds).
    /// A `nil` app is away time of that many seconds.
    private func day(_ parts: [(String?, String, Double, Int)]) -> [CategorizedSpan] {
        var cursor = 0.0
        var items: [CategorizedSpan] = []
        for (app, category, seconds, keys) in parts {
            defer { cursor += seconds }
            guard let app else { continue }
            items.append(CategorizedSpan(span: Span(start: ts(cursor), end: ts(cursor + seconds), appBundleID: app,
                                                    appName: app, title: app, url: nil, domain: nil, keySeconds: keys),
                                         categoryID: category))
        }
        return items
    }

    private func kinds(_ parts: [(String?, String, Double, Int)], rule: InterruptionRule = InterruptionRule()) -> [SwitchEpisode.Kind] {
        InterruptionClassifier.episodes(day(parts), productivity: productivity, distracting: distracting, rule: rule).map(\.kind)
    }

    func testAPassThroughUnderThreeSecondsIsAPass() {
        XCTAssertEqual(kinds([("xcode", "softwareDev", 60, 0), ("wechat", "communication", 2, 0), ("xcode", "softwareDev", 60, 0)]), [.pass])
    }

    func testAShortLookWithoutTypingIsAPeek() {
        XCTAssertEqual(kinds([("xcode", "softwareDev", 60, 0), ("wechat", "communication", 10, 1), ("xcode", "softwareDev", 60, 0)]), [.peek])
    }

    func testTwoKeySecondsMakeAnInterruptionHoweverShort() {
        let episodes = InterruptionClassifier.episodes(
            day([("xcode", "softwareDev", 60, 0), ("wechat", "communication", 5, 2), ("xcode", "softwareDev", 60, 0)]),
            productivity: productivity, distracting: distracting)
        XCTAssertEqual(episodes.map(\.kind), [.interruption])
        XCTAssertEqual(episodes.first?.reason, .typed)
    }

    func testStayingPastTheThresholdIsAnInterruption() {
        let parts: [(String?, String, Double, Int)] = [("xcode", "softwareDev", 60, 0), ("x", "socialMedia", 20, 0), ("xcode", "softwareDev", 60, 0)]
        XCTAssertEqual(kinds(parts), [.interruption])
        XCTAssertEqual(kinds(parts, rule: InterruptionRule(dwell: 30)), [.peek])
    }

    func testTypingCanBeTurnedOff() {
        let parts: [(String?, String, Double, Int)] = [("xcode", "softwareDev", 60, 0), ("wechat", "communication", 10, 6), ("xcode", "softwareDev", 60, 0)]
        XCTAssertEqual(kinds(parts, rule: InterruptionRule(countsTyping: false)), [.peek])
    }

    func testConsecutiveDistractingWindowsAddUp() {
        let episodes = InterruptionClassifier.episodes(
            day([("xcode", "softwareDev", 60, 0), ("wechat", "communication", 8, 0), ("x", "socialMedia", 9, 0), ("xcode", "softwareDev", 60, 0)]),
            productivity: productivity, distracting: distracting)
        XCTAssertEqual(episodes.map(\.kind), [.interruption])
        XCTAssertEqual(episodes.first?.dwell, 17)
        XCTAssertEqual(episodes.first?.destination.hasPrefix("x"), true, "the window holding the most dwell")
    }

    func testUncategorizedAndMiscNeverCount() {
        XCTAssertEqual(kinds([("xcode", "softwareDev", 60, 0), ("site", "uncategorized", 120, 10), ("xcode", "softwareDev", 60, 0),
                              ("finder", "misc", 90, 5), ("xcode", "softwareDev", 60, 0)]), [])
        // ...and they do not add to a distracting window's dwell either.
        XCTAssertEqual(kinds([("xcode", "softwareDev", 60, 0), ("wechat", "communication", 10, 0), ("site", "uncategorized", 60, 0),
                              ("xcode", "softwareDev", 60, 0)]), [.peek])
    }

    func testMovingBetweenProductiveWindowsIsNotAnEpisode() {
        XCTAssertEqual(kinds([("xcode", "softwareDev", 60, 0), ("linear", "business", 90, 30), ("xcode", "softwareDev", 60, 0)]), [])
    }

    func testAwayTimeNeverCountsAsDwellAndForgetsTheOrigin() {
        // 5 s in the chat, then away for ten minutes: a peek cut short, and
        // coming back to the chat afterwards is not an interruption of work.
        XCTAssertEqual(kinds([("xcode", "softwareDev", 60, 0), ("wechat", "communication", 5, 0), (nil, "", 600, 0),
                              ("wechat", "communication", 40, 9), ("xcode", "softwareDev", 60, 0)]), [.peek])
    }

    func testWithoutAProductiveOriginNothingCounts() {
        XCTAssertEqual(kinds([("wechat", "communication", 300, 40), ("x", "socialMedia", 300, 0)]), [])
    }

    func testRepeatReturnsWithinAMinuteCountOnce() {
        let episodes = InterruptionClassifier.episodes(
            day([("xcode", "softwareDev", 60, 0), ("wechat", "communication", 20, 0), ("xcode", "softwareDev", 30, 0),
                 ("wechat", "communication", 20, 0), ("xcode", "softwareDev", 30, 0), ("wechat", "communication", 20, 0),
                 ("xcode", "softwareDev", 90, 0), ("wechat", "communication", 20, 0), ("xcode", "softwareDev", 10, 0)]),
            productivity: productivity, distracting: distracting)
        XCTAssertEqual(episodes.map(\.kind), [.interruption, .interruption])
        XCTAssertEqual(episodes.map(\.visits), [3, 1])
    }

    func testAPeekThenATypedReturnMergeIntoOneInterruption() {
        let episodes = InterruptionClassifier.episodes(
            day([("xcode", "softwareDev", 60, 0), ("wechat", "communication", 6, 0), ("xcode", "softwareDev", 20, 0),
                 ("wechat", "communication", 6, 3), ("xcode", "softwareDev", 60, 0)]),
            productivity: productivity, distracting: distracting)
        XCTAssertEqual(episodes.map(\.kind), [.interruption])
        XCTAssertEqual(episodes.first?.reason, .typed)
    }

    func testAnEpisodeStillOpenAtTheEndIsKept() {
        let episodes = InterruptionClassifier.episodes(
            day([("xcode", "softwareDev", 60, 0), ("x", "socialMedia", 40, 0)]), productivity: productivity, distracting: distracting)
        XCTAssertEqual(episodes.map(\.kind), [.interruption])
        XCTAssertEqual(episodes.first?.returned, false)
    }

    func testSourcesCountInterruptionsAndTheirPeeks() {
        let result = DayInterruptions(episodes: InterruptionClassifier.episodes(
            day([("xcode", "softwareDev", 60, 0), ("wechat", "communication", 20, 0), ("xcode", "softwareDev", 120, 0),
                 ("wechat", "communication", 20, 3), ("xcode", "softwareDev", 120, 0), ("wechat", "communication", 5, 0),
                 ("xcode", "softwareDev", 120, 0)]),
            productivity: productivity, distracting: distracting))
        XCTAssertEqual(result.interruptions.count, 2)
        XCTAssertEqual(result.sources.first?.count, 2)
        XCTAssertEqual(result.sources.first?.typed, 1)
        XCTAssertEqual(result.sources.first?.peeks, 1)
    }
}
