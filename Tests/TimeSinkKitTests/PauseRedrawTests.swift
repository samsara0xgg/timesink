import XCTest
import SwiftUI
@testable import TimeSinkKit

/// Clicking pause hung the app: the status item sizes itself to the menu
/// bar label in whole points, and the paused countdown measured 60.5pt, so
/// the item went 60.5, 60, 60.5, ... forever. The label now rounds up.
@MainActor
final class PauseRedrawTests: XCTestCase {
    func testWholePointSizeRoundsAFractionalLabelUp() {
        let host = NSHostingController(rootView: Color.clear.frame(width: 60.5, height: 15.25).modifier(WholePointSize()))
        XCTAssertEqual(host.sizeThatFits(in: NSSize(width: 1000, height: 100)), NSSize(width: 61, height: 16))
    }

    func testFractionalLabelIsMeasuredFractionalWithoutIt() {
        // Guards the test above: it must see the fraction it rounds away.
        let host = NSHostingController(rootView: Color.clear.frame(width: 60.5, height: 15.25))
        XCTAssertEqual(host.sizeThatFits(in: NSSize(width: 1000, height: 100)).width, 60.5)
    }
}
