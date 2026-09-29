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
    private var bridgeOrigin: CGPoint?
    private var bridgeStarted = Date.distantPast
    private var anchor: CGRect = .zero

    /// Protect a diagonal move from its source row to the existing flyout.
    func shouldDeferSwitch() -> Bool {
        guard let panel, panel.isVisible, let origin = bridgeOrigin,
              Date().timeIntervalSince(bridgeStarted) < 0.65 else { return false }
        let point = NSEvent.mouseLocation
        if panel.frame.insetBy(dx: -2, dy: -2).contains(point) { return true }
        let edge = panel.frame.midX < anchor.midX ? panel.frame.maxX : panel.frame.minX
        return Self.contains(point, triangle: (origin, CGPoint(x: edge, y: panel.frame.minY - 8), CGPoint(x: edge, y: panel.frame.maxY + 8)))
    }

    nonisolated static func contains(_ p: CGPoint, triangle: (CGPoint, CGPoint, CGPoint)) -> Bool {
        func sign(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (a.x - c.x) * (b.y - c.y) - (b.x - c.x) * (a.y - c.y)
        }
        let (a, b, c) = triangle
        guard abs(sign(a, b, c)) > 0.001 else { return false }
        let d = [sign(p, a, b), sign(p, b, c), sign(p, c, a)]
        return !(d.contains { $0 < 0 } && d.contains { $0 > 0 })
    }

    /// Creates the `NSPanel` before the first hover needs it, so that show
    /// pays only content layout instead of also paying window creation (a
    /// window-server round trip plus shadow setup for a transparent panel).
    /// Idempotent. Call it off the popover's first-frame path, not inside it.
    ///
    /// Deliberately panel-only: an earlier version also pre-built and reused
    /// a shared `NSHostingView` across shows, which drifted off spec §10 and
    /// is not re-applied here -- `show` still builds a fresh hosting view per
    /// hover and `closeNow` still drops it.
    func prewarm() {
        if panel == nil { panel = Self.makePanel() }
    }

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
        bridgeOrigin = nil
        anchor = anchorFrame

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
        let wasVisible = panel.isVisible
        position(panel, near: anchorFrame, on: screen)
        let finalFrame = panel.frame
        if !wasVisible {
            panel.alphaValue = 0
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.setFrameOrigin(NSPoint(x: finalFrame.minX + (finalFrame.midX < anchorFrame.midX ? 6 : -6), y: finalFrame.minY))
            }
        }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0.16
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
        self.panel = panel
        return true
    }

    /// Schedules `closeNow()` after `delay` (default 0.25s) -- canceled by a
    /// subsequent `show`/hover (own row or the panel's own content).
    func scheduleClose(after delay: TimeInterval = PanelHost.defaultCloseDelay) {
        closeTask?.cancel()
        if bridgeOrigin == nil { bridgeOrigin = NSEvent.mouseLocation; bridgeStarted = Date() }
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.shouldDeferSwitch() { self.scheduleClose(after: 0.15) }
            else { self.closeNow() }
        }
    }

    func cancelScheduledClose() {
        closeTask?.cancel()
        closeTask = nil
    }

    func closeNow() {
        cancelScheduledClose()
        bridgeOrigin = nil
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
