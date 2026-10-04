import SwiftUI
import AppKit

/// The popover's first-run tour: up to three light spotlights, each with one
/// line, run once after onboarding. Steps whose target is not on screen are
/// dropped; a click outside the bubble, Esc or 跳过 ends it.
@MainActor @Observable final class MenuTour {
    enum Target: CaseIterable, Hashable { case status, row, open }

    /// Set when onboarding ends; the popover starts the tour the next time it appears.
    var armed = false
    private(set) var steps: [Target] = []
    private(set) var index = 0
    var current: Target? { steps.indices.contains(index) ? steps[index] : nil }
    @ObservationIgnored private var monitor: Any?

    func start(available: Set<Target>) {
        armed = false
        steps = Target.allCases.filter(available.contains)
        index = 0
        // One spotlight alone is not a tour.
        guard steps.count > 1 else { end(); return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self?.end() }
            return nil
        }
    }

    func next() {
        if index + 1 < steps.count { index += 1 } else { end() }
    }

    func end() {
        armed = false
        steps = []
        index = 0
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func caption(_ target: Target) -> String {
        switch target {
        case .status: String(localized: "这里是你此刻在做的事")
        case .row: String(localized: "把鼠标停在一行上，旁边会展开细节")
        case .open: String(localized: "点一下，进入完整的一天")
        }
    }
}

struct TourTargets: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [MenuTour.Target: Anchor<CGRect>] = [:]
    static func reduce(value: inout [MenuTour.Target: Anchor<CGRect>], nextValue: () -> [MenuTour.Target: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks the view a tour step can point at.
    func tourTarget(_ target: MenuTour.Target, if enabled: Bool = true) -> some View {
        anchorPreference(key: TourTargets.self, value: .bounds) { enabled ? [target: $0] : [:] }
    }
}

/// Runs the tour over the popover's content: starts it when armed, moves on
/// when the hover pane really opens (`drillOpen`), ends it with the popover.
struct MenuTourModifier: ViewModifier {
    let model: AppModel
    let drillOpen: Bool
    @State private var available: Set<MenuTour.Target> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let tour = model.menuTour
        content
            .onPreferenceChange(TourTargets.self) { available = Set($0.keys) }
            .overlayPreferenceValue(TourTargets.self) { anchors in
                GeometryReader { proxy in
                    if let current = tour.current, let anchor = anchors[current] {
                        TourOverlay(tour: tour, target: proxy[anchor], size: proxy.size, reduceMotion: reduceMotion)
                    }
                }
            }
            .task {
                guard tour.armed else { return }
                // Let the popover lay out and the day load first.
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, tour.armed else { return }
                model.settings.set("menuTourShown", "true")
                tour.start(available: available)
            }
            .onChange(of: drillOpen) { _, open in
                if open, tour.current == .row { tour.next() }
            }
            .onChange(of: available) { _, now in
                if let current = tour.current, !now.contains(current) { tour.next() }
            }
            .onDisappear { tour.end() }
    }
}

/// A light dim with a rounded window around the target, and a one-line bubble.
private struct TourOverlay: View {
    let tour: MenuTour
    let target: CGRect
    let size: CGSize
    let reduceMotion: Bool
    @State private var bubble = CGSize(width: 264, height: 84)

    private var cutout: CGRect { target.insetBy(dx: -4, dy: -4) }

    var body: some View {
        let shape = CutoutShape(cutout: cutout, radius: Design.Radius.card)
        ZStack(alignment: .topLeading) {
            shape.fill(Color.black.opacity(0.16), style: FillStyle(eoFill: true))
                .contentShape(shape, eoFill: true)
                .onTapGesture { tour.end() }
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .strokeBorder(Design.accent.opacity(0.55), lineWidth: 1.5)
                .frame(width: cutout.width, height: cutout.height)
                .offset(x: cutout.minX, y: cutout.minY)
                .allowsHitTesting(false)
            bubbleView
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: tour.index)
    }

    private var below: Bool { cutout.maxY + 10 + bubble.height <= size.height - 6 }

    private var bubbleView: some View {
        let x = min(max(8, cutout.midX - bubble.width / 2), size.width - bubble.width - 8)
        let y = below ? cutout.maxY + 10 : cutout.minY - 10 - bubble.height
        let tip = min(max(cutout.midX, x + 20), x + bubble.width - 20) - x
        let last = tour.index == tour.steps.count - 1
        return VStack(alignment: .leading, spacing: 10) {
            Text(tour.current.map(MenuTour.caption) ?? "").font(.body).foregroundStyle(Design.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(tour.steps.indices, id: \.self) { i in
                    Circle().fill(i == tour.index ? Design.accent : Design.line).frame(width: 6, height: 6)
                }
                Spacer(minLength: 8)
                if !last {
                    Button("跳过") { tour.end() }.buttonStyle(.plain).font(.note).foregroundStyle(Design.ink2)
                }
                Button(last ? "完成" : "下一步") { tour.next() }.buttonStyle(AccentButtonStyle(height: 24))
            }
        }
        .padding(Design.Space.md)
        .frame(width: 264)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Design.surface)
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).strokeBorder(Design.line, lineWidth: 0.5)
                // The tip points back at the target.
                Rectangle().fill(Design.surface).frame(width: 10, height: 10).rotationEffect(.degrees(45))
                    .position(x: tip, y: below ? 0 : bubble.height)
            }
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { bubble = $0 }
        .offset(x: x, y: y)
        .accessibilityElement(children: .contain)
    }
}

/// The page with a rounded hole, even-odd filled. The hole is animatable, so
/// the spotlight glides from one step to the next.
private struct CutoutShape: Shape {
    var cutout: CGRect
    var radius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(cutout.minX, cutout.minY), .init(cutout.width, cutout.height)) }
        set { cutout = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: cutout, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return path
    }
}
