import XCTest
import AppKit
import SwiftUI
@testable import TimeSinkKit

/// The main window must never ask for more room than it has. The bug this
/// guards: pages kept alive behind the visible one held the size they last
/// had, so after a big window was shrunk the root stayed that wide and was
/// centred and clipped (bar gone, headline cut, content past both edges).
@MainActor
final class WindowLayoutTests: XCTestCase {
    func testRootNeverWiderThanWindowAfterShrinking() async throws {
        let model = try RefinedPreview.fixture()
        for lang in ["zh_CN", "en"] {
            model.sidebarSelection = .today
            let root = MainWindowView(model: model).environment(\.locale, Locale(identifier: lang)).environment(\.colorScheme, .dark)
            let controller = NSHostingController(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                                  styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 1280, height: 860))
            func settle() async { try? await Task.sleep(for: .milliseconds(350)); controller.view.layoutSubtreeIfNeeded() }
            await settle()
            // Visit every page in the big window, so each is kept at that size.
            for page in SidebarItem.allCases + [.today] { model.sidebarSelection = page; await settle() }
            for size in [NSSize(width: 1280, height: 860), NSSize(width: 1000, height: 700), NSSize(width: 915, height: 650), Design.windowMinSize] {
                window.setContentSize(size)
                for page in SidebarItem.allCases {
                    model.sidebarSelection = page
                    await settle()
                    let fit = controller.view.fittingSize
                    XCTAssertLessThanOrEqual(fit.width, max(size.width, Design.windowMinSize.width), "\(lang) \(page) at \(size)")
                }
            }
            window.close()
        }
    }

    func testMainWindowCanEnterFullScreen() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Color.clear.appWindow(.main))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertGreaterThan(window.maxSize.width, 1e30)
        window.close()
    }
}
