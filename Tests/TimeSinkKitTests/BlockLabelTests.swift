import XCTest
@testable import TimeSinkKit

final class BlockLabelTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    /// One point per character: easy to force each step.
    private let chars: (String) -> CGFloat = { CGFloat($0.count) }

    private func text(_ minutes: Double, _ available: CGFloat) -> String? {
        BlockLabel.text(minutes * 60, available: available, locale: en, width: chars)
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

    /// One block that cannot show its shortest form turns every label off; without it the others show.
    func testOneBlockTooNarrowHidesAll() async {
        await MainActor.run {
            let width: (String) -> CGFloat = { BlockLabel.noteWidth($0) }
            let need = width("34m") + 2 * BlockLabel.padding
            let roomy: [(recorded: TimeInterval, width: CGFloat)] = [(34 * 60, need), (80 * 60, 200), (10 * 60, 3)]
            XCTAssertTrue(BlockLabel.fitsAll(roomy, width: width))
            XCTAssertFalse(BlockLabel.fitsAll(roomy + [(31 * 60, need - 1)], width: width))
            // A short block is never the reason.
            XCTAssertTrue(BlockLabel.fitsAll(roomy + [(29 * 60, 3)], width: width))
        }
    }

    /// With real font metrics: a block that holds "NNm" always has some number, whatever its length.
    func testAnyBlockThatFitsTheMinuteFormHasANumber() async {
        await MainActor.run {
            let width: (String) -> CGFloat = { BlockLabel.noteWidth($0) }
            let room = width("59m")
            for minutes in 30...900 { XCTAssertNotNil(BlockLabel.text(Double(minutes) * 60, available: room, width: width), "\(minutes)") }
        }
    }

    private func blend(_ fill: UInt32) -> UInt32 {
        let c = [16, 8, 0].map { Double((fill >> UInt32($0)) & 0xFF) }.map { UInt32(($0 * 0.8 + 255 * 0.2).rounded()) }
        return c[0] << 16 | c[1] << 8 | c[2]
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
