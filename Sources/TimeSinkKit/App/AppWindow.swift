import AppKit
import SwiftUI

/// Bringing one of TimeSink's windows forward from the menu bar or a
/// notification. The app runs as an accessory, so SwiftUI's `openWindow` /
/// `openSettings` open a window without making the app active and it lands
/// behind the frontmost app's windows. Every such route opens its window and
/// then calls `bringForward()`.
@MainActor
enum AppWindow {
    case main, settings

    fileprivate static weak var mainWindow: NSWindow?
    fileprivate static weak var settingsWindow: NSWindow?

    /// Runs one turn later: SwiftUI orders the window front asynchronously,
    /// and the menu bar popover gives up key status as it closes. The window
    /// is put in front even if macOS declines the activation; the activation
    /// then gives it the keyboard. It is frontmost, not floating: the next
    /// click on another app covers it as usual.
    func bringForward() {
        DispatchQueue.main.async {
            let window = self == .main ? Self.mainWindow : Self.settingsWindow
            window?.orderFrontRegardless()
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
    }
}

extension AppWindow {
    /// Main-window pages stay alive while hidden, so a list or field on the
    /// page just left could keep the keyboard. Hands it back to the window,
    /// as removing the page used to; focus in the sidebar stays put.
    static func releaseHiddenPageFocus() {
        guard let window = mainWindow, let responder = window.firstResponder as? NSView else { return }
        // The outermost split view is the sidebar/detail split.
        var split: NSSplitView?
        var view: NSView? = responder
        while let current = view {
            if let found = current as? NSSplitView { split = found }
            view = current.superview
        }
        guard let sidebar = split?.arrangedSubviews.first, !responder.isDescendant(of: sidebar) else { return }
        window.makeFirstResponder(nil)
    }
}

extension View {
    /// Registers the hosting window for `AppWindow.bringForward()` and makes
    /// it come to the Space the user is on, rather than taking the user to
    /// the Space where it was left open.
    func appWindow(_ role: AppWindow) -> some View {
        background(AppWindowProbe(role: role))
    }
}

private struct AppWindowProbe: NSViewRepresentable {
    let role: AppWindow

    func makeNSView(context: Context) -> NSView { Probe(role: role) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let role: AppWindow

        init(role: AppWindow) {
            self.role = role
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.collectionBehavior.insert(.moveToActiveSpace)
            switch role {
            case .main: AppWindow.mainWindow = window
            case .settings: AppWindow.settingsWindow = window
            }
        }
    }
}
