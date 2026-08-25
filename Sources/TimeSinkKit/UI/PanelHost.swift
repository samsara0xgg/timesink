import SwiftUI
import AppKit

/// Hosts one hover drill-down `NSPanel` for the menu-bar popover -- a
/// non-activating, non-key floating panel positioned next to whichever
/// popover row is currently hovered, reused (repositioned/re-armed) across
/// `show` calls rather than recreated each time.
///
/// Deliberately NOT shared with `FocusHUDController` (Task 12) despite the
/// surface similarity (both are "one reused NSPanel, positioned then
/// ordered front") -- the two need different panel params: this one is
/// `.popUpMenu` level with `hidesOnDeactivate = false` (must stay up while
/// the popover itself has focus, and outlive brief focus changes), where
/// `FocusHUDController`'s HUD is `.floating` level with the AppKit default
/// `hidesOnDeactivate`. Conflating them would mean one or the other panel
/// type gets the wrong behavior.
@MainActor
final class PanelHost {
    /// Default `scheduleClose` delay -- spec §10's "移开约 0.25s 后收回".
    static let defaultCloseDelay: TimeInterval = 0.25

    private var panel: NSPanel?
    private var closeTask: Task<Void, Never>?

    /// Shows (or updates, if already visible) `content`, positioned just
    /// outside `anchorFrame` (screen coordinates -- the hovered row's frame,
    /// converted by the caller). Prefers the anchor's left side (the
    /// popover typically sits near the screen's right edge, close to a
    /// menu-bar icon there), falling back to the right side when there's no
    /// room; the whole panel is then clamped inside the anchor's screen's
    /// visible frame.
    ///
    /// Returns `false` -- without showing anything -- when `anchorFrame` is
    /// degenerate (zero width/height, e.g. the caller couldn't resolve the
    /// popover's `NSWindow` to convert a local frame to screen coordinates)
    /// or no screen contains it; the caller falls back to the in-popover
    /// `expandedDrill` degraded path (spec §10's sanctioned alternative --
    /// NSPanel positioning against a `MenuBarExtra`'s private layout is a
    /// known-risk area).
    @discardableResult
    func show<Content: View>(_ content: Content, near anchorFrame: CGRect) -> Bool {
        guard anchorFrame.width > 0, anchorFrame.height > 0,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchorFrame) })
        else { return false }

        cancelScheduledClose()

        // Hovering the panel's own content must keep it open (spec §10:
        // "悬停子窗本体保持显示") -- wrapping here, rather than in every
        // individual drill-down view, keeps `DrillDownViews.swift` pure
        // renderers with no `PanelHost` dependency of their own.
        let wrapped = content.onHover { [weak self] hovering in
            if hovering {
                self?.cancelScheduledClose()
            } else {
                self?.scheduleClose()
            }
        }

        let panel = self.panel ?? Self.makePanel()
        let hosting = NSHostingView(rootView: wrapped)
        panel.contentView = hosting
        hosting.layout()
        panel.setContentSize(hosting.fittingSize)
        position(panel, near: anchorFrame, on: screen)
        panel.orderFrontRegardless()
        self.panel = panel
        return true
    }

    /// Schedules `closeNow()` after `delay` (default 0.25s) -- canceled by a
    /// subsequent `show`/hover (own row or the panel's own content).
    func scheduleClose(after delay: TimeInterval = PanelHost.defaultCloseDelay) {
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.closeNow()
        }
    }

    func cancelScheduledClose() {
        closeTask?.cancel()
        closeTask = nil
    }

    func closeNow() {
        cancelScheduledClose()
        panel?.orderOut(nil)
        // Fold-in 7: drops the last-shown pane's `NSHostingView` (and
        // everything its SwiftUI content closure captured -- the
        // `onHover` wrapper `show` adds, `loadLast7Bars`, etc.) instead of
        // letting it sit retained on `panel` between hovers.
        panel?.contentView = nil
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces]
        return panel
    }

    private func position(_ panel: NSPanel, near anchorFrame: CGRect, on screen: NSScreen) {
        let size = panel.frame.size
        let gap: CGFloat = 8
        let visible = screen.visibleFrame

        var x = anchorFrame.minX - size.width - gap
        if x < visible.minX {
            x = anchorFrame.maxX + gap
        }
        x = min(max(x, visible.minX), visible.maxX - size.width)

        var y = anchorFrame.maxY - size.height
        y = min(max(y, visible.minY), visible.maxY - size.height)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
