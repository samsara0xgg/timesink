import XCTest
import SwiftUI
@testable import TimeSinkKit

final class ColorHexTests: XCTestCase {
    /// Direct, deterministic test of the clamp math `toHex()` relies on
    /// (the reviewed regression: `%02X` is a minimum width, not a maximum,
    /// so an unclamped 279 would format as "117" and an unclamped -12 as
    /// "FFFFFFF4"). Exercised against the extracted `clamp255` helper
    /// itself rather than round-tripped through `NSColor`, since on this
    /// OS/toolchain `NSColor.usingColorSpace(.sRGB)` happens to pre-clamp
    /// every wide-gamut input tried (Display P3, extended sRGB, device
    /// RGB) — that pre-clamping isn't a documented guarantee, so this test
    /// pins the defensive clamp's own behavior independent of it.
    func testClamp255ClampsOutOfRangeComponents() {
        XCTAssertEqual(Color.clamp255(279), 255)
        XCTAssertEqual(Color.clamp255(-12), 0)
        XCTAssertEqual(Color.clamp255(128.4), 128)
        XCTAssertEqual(Color.clamp255(0), 0)
        XCTAssertEqual(Color.clamp255(255), 255)
        XCTAssertEqual(Color.clamp255(254.6), 255)
    }

    /// Integration-level check: even a wide-gamut pick must still produce a
    /// well-formed 6-digit RRGGBB string end to end through `toHex()`.
    func testToHexClampsWideGamutComponents() {
        let color = Color(.displayP3, red: 1.6, green: -0.6, blue: 0.5)
        let hex = color.toHex()

        XCTAssertEqual(hex.count, 6, "expected a 6-digit RRGGBB hex string, got \(hex)")
        for pairStart in stride(from: 0, to: 6, by: 2) {
            let start = hex.index(hex.startIndex, offsetBy: pairStart)
            let end = hex.index(start, offsetBy: 2)
            let byte = Int(hex[start..<end], radix: 16)
            XCTAssertNotNil(byte, "component \(hex[start..<end]) is not a valid hex byte")
            XCTAssertTrue((0...255).contains(byte ?? -1), "component \(hex[start..<end]) out of 00...FF range")
        }
    }

    func testToHexRoundtripsAnInGamutColor() {
        XCTAssertEqual(Color(hex: "3478F6").toHex(), "3478F6")
    }
}
