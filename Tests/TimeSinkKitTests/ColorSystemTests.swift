import XCTest
@testable import TimeSinkKit

final class ColorSystemTests: XCTestCase {
    private typealias Pair = ColorSystem.Pair
    private var schemes: [(name: String, categories: [String: Pair], projects: [Pair])] {
        ColorSystem.Scheme.allCases.map { ($0.rawValue, ColorSystem.categories(of: $0), ColorSystem.projects(of: $0)) }
    }
    /// Original is the look before the colour system: it keeps its old label rule (dark ink on light fills,
    /// white elsewhere), which does not reach 4.5:1 everywhere, so the label gate does not apply to it.
    private func gated(_ name: String) -> Bool { name != ColorSystem.Scheme.original.rawValue }

    override func tearDown() {
        ColorSystem.use(.standard)
        super.tearDown()
    }

    func testFiveSchemesEachWithEightProjectColoursAndASlate() {
        XCTAssertEqual(ColorSystem.Scheme.allCases.count, 5)
        for scheme in schemes {
            XCTAssertEqual(scheme.projects.count, ProjectPalette.slots + 1, scheme.name)
            XCTAssertEqual(scheme.categories.count, 13, scheme.name)
        }
    }

    func testTheDefaultIsCCoolAndSwitchingChangesThePalette() {
        XCTAssertEqual(ColorSystem.Scheme.standard, .cool)
        ColorSystem.use(.cool)
        XCTAssertEqual(ColorSystem.palette.projects.first?.light, ColorSystem.projectsD.first?.light)
        ColorSystem.use(.original)
        XCTAssertEqual(ColorSystem.palette.scheme, .original)
        XCTAssertEqual(ColorSystem.palette.projects.first?.light, ColorSystem.projectsOriginal.first?.light)
        XCTAssertTrue(ColorSystem.isOriginal)
        ColorSystem.use(.harmonised)
        XCTAssertEqual(ColorSystem.categories["softwareDev"]?.light, ColorSystem.categoriesB["softwareDev"]?.light)
        // A project keeps its slot across schemes: only the tone differs.
        XCTAssertEqual(ColorSystem.projects.count, ColorSystem.projects(of: .cool).count)
    }

    @MainActor func testChoosingASchemeStoresItAndBumpsTheRevision() {
        let settings = ColorSettings.shared, before = settings.revision
        settings.scheme = .vivid
        XCTAssertEqual(ColorSystem.scheme, .vivid)
        XCTAssertEqual(UserDefaults.standard.string(forKey: ColorSystem.defaultsKey), "c")
        XCTAssertEqual(settings.revision, before + 1)
        settings.scheme = .cool
        UserDefaults.standard.removeObject(forKey: ColorSystem.defaultsKey)
        XCTAssertEqual(ColorSystem.Scheme(rawValue: "ccool"), .cool)
    }

    func testEnvironmentNamesMapToSchemes() {
        XCTAssertEqual(ColorSystem.Scheme(environment: "D"), .cool)
        XCTAssertEqual(ColorSystem.Scheme(environment: "o"), .original)
        XCTAssertEqual(ColorSystem.Scheme(environment: "B"), .harmonised)
        XCTAssertNil(ColorSystem.Scheme(environment: "zz"))
    }

    /// The label on a category or project fill (white, or the dark ink where white fails) reaches 4.5:1, light and dark.
    func testLabelContrast() {
        for scheme in schemes where gated(scheme.name) {
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
        for (light, dark) in [(ColorSystem.rampLight, ColorSystem.rampDark), (ColorSystem.rampOriginalLight, ColorSystem.rampOriginalDark)] {
            let l = light.map(ColorSystem.luminance), d = dark.map(ColorSystem.luminance)
            XCTAssertEqual(l, l.sorted(by: >))
            XCTAssertEqual(d, d.sorted(by: <))
        }
    }

    func testHexParsing() {
        XCTAssertEqual(ColorSystem.hexValue("#3C73C5"), 0x3C73C5)
        XCTAssertEqual(ColorSystem.contrast(0xFFFFFF, 0x000000), 21, accuracy: 0.001)
    }
}
