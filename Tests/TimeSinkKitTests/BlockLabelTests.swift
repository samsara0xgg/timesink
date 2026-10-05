import XCTest
@testable import TimeSinkKit

final class BlockLabelTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    /// One point per character: easy to force each step.
    private let chars: (String) -> CGFloat = { CGFloat($0.count) }

    private func text(_ minutes: Double, _ available: CGFloat, from threshold: Int? = 30) -> String? {
        BlockLabel.text(minutes * 60, threshold: threshold, available: available, locale: en, width: chars)
    }

    private func threshold(_ pointsPerMinute: CGFloat) -> Int? {
        BlockLabel.minutes(pointsPerSecond: pointsPerMinute / 60, locale: en, width: chars)
    }

    func testUnderThirtyMinutesNeverShowsAndThirtyAlwaysDoes() {
        for minutes in [0.0, 5, 29, 29.9] { XCTAssertNil(text(minutes, 1000), "\(minutes)") }
        XCTAssertEqual(text(30, 1000), "30m")
        XCTAssertEqual(text(47, 3), "47m")
        XCTAssertEqual(text(59, 3), "59m")
        XCTAssertNil(text(47, 2))
    }

    func testFormsDegradeInOrder() {
        XCTAssertEqual(BlockLabel.forms(77 * 60, locale: en), ["1h 17m", "1h17", "77m", "1h"])
        XCTAssertEqual(BlockLabel.forms(125 * 60, locale: en), ["2h 5m", "2h05", "125m", "2h"])
        XCTAssertEqual(text(77, 6), "1h 17m")
        XCTAssertEqual(text(77, 5), "1h17")
        XCTAssertEqual(text(77, 4), "1h17")
        XCTAssertEqual(text(77, 3), "77m")
        XCTAssertEqual(text(77, 2), "1h")
        XCTAssertNil(text(77, 1))
        XCTAssertEqual(text(125, 5), "2h 5m")
        XCTAssertEqual(text(125, 4), "2h05")
        XCTAssertEqual(text(125, 3), "2h")
        XCTAssertEqual(text(125, 2), "2h")
    }

    /// Hours are floored: 60...119 minutes read "1h".
    func testHoursOnlyFormIsFloored() {
        XCTAssertEqual(BlockLabel.forms(119 * 60, locale: en).last, "1h")
        XCTAssertEqual(BlockLabel.forms(60 * 60, locale: en), ["1h"])
        XCTAssertEqual(BlockLabel.forms(59 * 60, locale: en), ["59m"])
    }

    private func blend(_ fill: UInt32) -> UInt32 {
        let c = [16, 8, 0].map { Double((fill >> UInt32($0)) & 0xFF) }.map { UInt32(($0 * 0.8 + 255 * 0.2).rounded()) }
        return c[0] << 16 | c[1] << 8 | c[2]
    }

    func testPaddingIsFourEachSide() {
        XCTAssertEqual(BlockLabel.padding, 4)
    }

    /// With one point per character: "30m" needs 11 pt of block (3 + 2 x 4 padding) plus the 2 pt seam.
    func testThresholdFollowsTheScale() {
        XCTAssertEqual(threshold(0.5), 30)
        XCTAssertEqual(threshold(0.35), 45)
        XCTAssertEqual(threshold(0.25), 60)
        XCTAssertEqual(threshold(0.15), 90)
        XCTAssertEqual(threshold(0.11), 120)
        XCTAssertNil(threshold(0.05))
    }

    func testBlocksAtOrAboveTheThresholdShowAndOthersNever() {
        XCTAssertEqual(text(44, 100, from: 45), nil)
        XCTAssertEqual(text(45, 100, from: 45), "45m")
        XCTAssertEqual(text(89, 100, from: 90), nil)
        XCTAssertEqual(text(95, 2, from: 90), "1h")
        XCTAssertNil(text(500, 100, from: nil))
    }

    /// With real font metrics, at every scale: every block of N minutes or more (as wide as the axis makes it)
    /// has a number, every shorter one has none, and nothing under 30 minutes ever has one.
    func testEveryScaleIsConsistent() async {
        await MainActor.run {
            let width: (String) -> CGFloat = { BlockLabel.noteWidth($0) }
            var seen = Set<Int?>()
            for ppm in stride(from: 0.05, through: 3, by: 0.01) {
                let n = BlockLabel.minutes(pointsPerSecond: CGFloat(ppm) / 60, width: width)
                seen.insert(n)
                for minutes in 1...600 {
                    let blockWidth = CGFloat(minutes) * CGFloat(ppm) - BlockLabel.seam
                    let label = BlockLabel.text(Double(minutes) * 60, threshold: n, available: blockWidth - 2 * BlockLabel.padding, width: width)
                    if let n, minutes >= n { XCTAssertNotNil(label, "\(minutes)m at \(ppm) pt/min, N=\(n)") } else { XCTAssertNil(label, "\(minutes)m at \(ppm), N=\(String(describing: n))") }
                    if minutes < 30 { XCTAssertNil(label) }
                }
            }
            XCTAssertEqual(seen, [30, 45, 60, 90, 120, nil])
        }
    }

    /// Why a guessed block draws its label on a flat patch: the stripes (20% white) lower the contrast of the
    /// best ink below 4.5:1 for some fills, in every scheme; on the patch it is the fill's own, which `ColorSystemTests` gates.
    func testStripesWouldBreakContrastSoLabelsSitOnAFlatPatch() {
        var broken = 0
        for scheme in ColorSystem.Scheme.allCases where scheme != .original {
            let fills = ColorSystem.categories(of: scheme).values.flatMap { [$0.light, $0.dark] }
                + ColorSystem.projects(of: scheme).flatMap { [$0.light, $0.dark] }
            for fill in fills {
                let ink = ColorSystem.labelInk(on: fill)
                XCTAssertGreaterThanOrEqual(ColorSystem.contrast(ink, fill), 4.5, scheme.rawValue)
                if ColorSystem.contrast(ink, blend(fill)) < 4.5 { broken += 1 }
            }
        }
        XCTAssertGreaterThan(broken, 0)
    }
}
