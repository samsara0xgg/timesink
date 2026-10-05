import XCTest
@testable import TimeSinkKit

final class ColorSystemTests: XCTestCase {
    private typealias Pair = ColorSystem.Pair
    private let schemes: [(name: String, categories: [String: Pair], projects: [Pair])] = [
        ("A", ColorSystem.categoriesA, ColorSystem.projectsA),
        ("B", ColorSystem.categoriesB, ColorSystem.projectsB),
        ("C", ColorSystem.categoriesA, ColorSystem.projectsC)
    ]

    /// The label on a category or project fill (white, or the dark ink where white fails) reaches 4.5:1, light and dark.
    func testLabelContrast() {
        for scheme in schemes {
            let fills = scheme.categories.map { ($0.key, $0.value) } + scheme.projects.enumerated().map { ("project\($0.offset)", $0.element) }
            for (name, pair) in fills {
                for (mode, fill) in [("light", pair.light), ("dark", pair.dark)] {
                    let ink = ColorSystem.labelInk(on: fill)
                    XCTAssertGreaterThanOrEqual(ColorSystem.contrast(ink, fill), 4.5, "\(scheme.name) \(mode) \(name)")
                }
            }
        }
    }

    /// Every category and every project has a colour of its own, and no project repeats a category's.
    func testTokensAreDistinct() {
        for scheme in schemes {
            let categories = scheme.categories.values
            XCTAssertEqual(Set(categories.map(\.light)).count, categories.count, scheme.name)
            XCTAssertEqual(Set(categories.map(\.dark)).count, categories.count, scheme.name)
            XCTAssertEqual(Set(scheme.projects.map(\.light)).count, scheme.projects.count, scheme.name)
            XCTAssertEqual(Set(scheme.projects.map(\.dark)).count, scheme.projects.count, scheme.name)
            XCTAssertTrue(Set(scheme.projects.map(\.light)).isDisjoint(with: categories.map(\.light)), scheme.name)
        }
        XCTAssertEqual(Set(ColorSystem.radarLight).count, ColorSystem.radarLight.count)
        XCTAssertEqual(Set(ColorSystem.radarDark).count, ColorSystem.radarDark.count)
    }

    /// Every shipped category has a colour in both schemes.
    func testEveryShippedCategoryIsCovered() {
        for scheme in schemes {
            for category in Taxonomy.categories {
                XCTAssertNotNil(scheme.categories[category.id], "\(scheme.name) \(category.id)")
            }
        }
    }

    /// The indigo ramp steps from little to much: lighter to darker on light, darker to lighter on dark.
    func testRampIsMonotonic() {
        let light = ColorSystem.rampLight.map(ColorSystem.luminance), dark = ColorSystem.rampDark.map(ColorSystem.luminance)
        XCTAssertEqual(light, light.sorted(by: >))
        XCTAssertEqual(dark, dark.sorted(by: <))
    }

    func testHexParsing() {
        XCTAssertEqual(ColorSystem.hexValue("#3C73C5"), 0x3C73C5)
        XCTAssertEqual(ColorSystem.contrast(0xFFFFFF, 0x000000), 21, accuracy: 0.001)
    }
}
