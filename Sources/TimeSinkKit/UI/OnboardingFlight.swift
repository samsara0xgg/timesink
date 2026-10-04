import SwiftUI
import AppKit
import ServiceManagement
import os

private let onboardingLogger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "onboarding")

/// The light trail from the welcome card to the menu bar icon, then one soft
/// ring on the icon. A pure function of `t` (seconds), in the view's own
/// top-left space, so renders can pick any moment.
struct FlightView: View {
    static let flight = 0.8, lag = 0.22, pulse = 0.5
    static var total: Double { flight + pulse }

    var t: Double
    var start: CGPoint
    var end: CGPoint
    var reduceMotion = false

    private static func ease(_ s: Double) -> Double { (1 - cos(.pi * min(1, max(0, s)))) / 2 }

    /// A gentle arc: the control point sits to the side of the straight line, upward.
    private var control: CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        var normal = CGPoint(x: -dy, y: dx)
        if normal.y > 0 { normal = CGPoint(x: -normal.x, y: -normal.y) }
        return CGPoint(x: (start.x + end.x) / 2 + normal.x * 0.22, y: (start.y + end.y) / 2 + normal.y * 0.22)
    }

    private func point(_ s: Double) -> CGPoint {
        let c = control, u = 1 - s
        return CGPoint(x: u * u * start.x + 2 * u * s * c.x + s * s * end.x, y: u * u * start.y + 2 * u * s * c.y + s * s * end.y)
    }

    var body: some View {
        Canvas { context, _ in
            let head = Self.ease(t / Self.flight), tail = Self.ease((t - Self.lag) / Self.flight)
            if !reduceMotion, t < Self.flight + Self.lag, head > tail {
                var path = Path()
                let samples = 40
                for i in 0...samples {
                    let p = point(tail + (head - tail) * Double(i) / Double(samples))
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                let shading = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [Design.accent.opacity(0), Design.accent]), startPoint: point(tail), endPoint: point(head))
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 3))
                    layer.opacity = 0.35
                    layer.stroke(path, with: shading, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                }
                context.stroke(path, with: shading, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            let ring = (t - Self.flight) / Self.pulse
            if ring > 0, ring < 1 {
                let radius = 7 + 11 * (1 - pow(1 - ring, 2))
                context.stroke(Path(ellipseIn: CGRect(x: end.x - radius, y: end.y - radius, width: radius * 2, height: radius * 2)),
                               with: .color(Design.accent.opacity(0.55 * (1 - ring))), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Click-through, never key, free to sit over the menu bar.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

enum OnboardingFlight {
    /// Flies the trail from `start` to the status item (both in screen coordinates),
    /// pulses the icon once, and removes its window. Reduce motion: the pulse alone.
    @MainActor static func run(from start: CGPoint, to target: CGRect) async {
        let end = CGPoint(x: target.midX, y: target.midY)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let bounds = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
            .insetBy(dx: -80, dy: -80)
        let panel = OverlayPanel(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Screen coordinates grow upward; the view's grow downward.
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - bounds.minX, y: bounds.maxY - p.y) }
        let (from, to) = (local(start), local(end))
        let begun = Date(), skipped = reduce ? FlightView.flight : 0
        let host = NSHostingView(rootView: TimelineView(.animation) { context in
            FlightView(t: skipped + context.date.timeIntervalSince(begun), start: from, end: to, reduceMotion: reduce)
        }.frame(width: bounds.width, height: bounds.height))
        panel.contentView = host
        panel.setFrame(bounds, display: false)
        panel.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(FlightView.total - skipped + 0.05))
        panel.orderOut(nil)
    }
}

extension AppModel {
    /// 继续: the login item, the light trail to the menu bar icon, then the
    /// popover opens once with its tour. Without a status button, none of it runs.
    func finishOnboarding(from start: CGPoint?, launchAtLogin: Bool) {
        // Same guard as Settings' toggle: only an installed app can be a login item.
        if launchAtLogin, Bundle.main.bundlePath.hasPrefix("/Applications") {
            do { try SMAppService.mainApp.register() }
            catch { onboardingLogger.error("login item: \(error.localizedDescription)") }
        }
        Task { @MainActor in
            guard let target = statusButtonFrame?(), !target.isEmpty else { return }
            if let start { await OnboardingFlight.run(from: start, to: target) }
            if settings.get("menuTourShown") != "true" { menuTour.armed = true }
            popoverShortcut.action?()
        }
    }
}
