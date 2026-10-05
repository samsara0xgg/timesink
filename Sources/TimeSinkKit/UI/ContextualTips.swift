import SwiftUI
import TipKit

/// Posted when the user changes a category on purpose, wherever they do it.
extension Notification.Name {
    static let userRecategorized = Notification.Name("TimeSinkUserRecategorized")
}

// Three tips, each shown once, where the thing they teach is in front of the
// person. TipKit holds the rules, the events and the "once"; the popover
// draws the bubble itself (a popover inside the menu bar popover is not
// something to rely on) and shows one at a time, never during the tour.

/// The first time the popover has category rows to hover.
struct HoverTip: Tip {
    @Parameter(.transient) static var rowsShown: Bool = false
    /// Donated when the tour starts: the tip is for after it.
    static let tourRan = Tips.Event(id: "menuTourRan")
    var title: Text { Text("把鼠标停在一行上，旁边会展开细节") }
    var rules: [Rule] {
        [#Rule(Self.$rowsShown) { $0 == true }, #Rule(Self.tourRan) { $0.donations.count > 0 }]
    }
}

/// The first time something uncategorized, or one of Jev's unsure picks, is on screen.
struct RecategorizeTip: Tip {
    @Parameter(.transient) static var itemShown: Bool = false
    var title: Text { Text("分错了？点一下改，以后会记住") }
    var rules: [Rule] { [#Rule(Self.$itemShown) { $0 == true }] }
}

/// The day after the first day with a couple of hours recorded.
struct ReviewTip: Tip {
    @Parameter(.transient) static var due: Bool = false
    var title: Text { Text("昨天的完整记录在这里") }
    var rules: [Rule] { [#Rule(Self.$due) { $0 == true }] }
}

@MainActor @Observable final class ContextualTips {
    enum Kind: CaseIterable, Hashable { case hover, recategorize, review }

    /// What TipKit says may show now.
    private(set) var eligible: Set<Kind> = []
    @ObservationIgnored private var observer: NSObjectProtocol?
    private static let longDay: TimeInterval = 2 * 3600

    init() {
        observer = NotificationCenter.default.addObserver(forName: .userRecategorized, object: nil, queue: .main) { _ in
            RecategorizeTip().invalidate(reason: .actionPerformed)
        }
    }

    static func tip(_ kind: Kind) -> any Tip {
        switch kind {
        case .hover: HoverTip()
        case .recategorize: RecategorizeTip()
        case .review: ReviewTip()
        }
    }

    static func caption(_ kind: Kind) -> String {
        switch kind {
        case .hover: String(localized: "把鼠标停在一行上，旁边会展开细节")
        case .recategorize: String(localized: "分错了？点一下改，以后会记住")
        case .review: String(localized: "昨天的完整记录在这里")
        }
    }

    /// Follows TipKit's verdict for one tip for as long as the caller lives.
    func watch(_ kind: Kind) async {
        eligible.remove(kind)
        for await shouldDisplay in Self.tip(kind).shouldDisplayUpdates {
            if shouldDisplay { eligible.insert(kind) } else { eligible.remove(kind) }
        }
    }

    func watchAll() async {
        async let hover: Void = watch(.hover), recategorize: Void = watch(.recategorize), review: Void = watch(.review)
        _ = await (hover, recategorize, review)
    }

    func close(_ kind: Kind) { Self.tip(kind).invalidate(reason: .tipClosed) }
    func done(_ kind: Kind) { Self.tip(kind).invalidate(reason: .actionPerformed) }
    /// Opening the main window answers the review tip, but only once it was due and
    /// not as the tour's own last step: onboarding opens the window on day one, and
    /// the tour sends the person there.
    func mainWindowOpened(tourBusy: Bool) { if ReviewTip.due, !tourBusy { done(.review) } }
    /// A hover pane opened: the hover tip has nothing left to teach, unless it was the tour's hover.
    func drillOpened(quiet: Bool) { if !quiet { done(.hover) } }

    /// The first day with two hours on it is remembered; from the day after,
    /// yesterday's record is worth pointing to.
    func noteDay(total: TimeInterval, settings: SettingsStore, now: Date = Date()) {
        let today = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        var first = settings.get("firstLongDay").flatMap(Double.init)
        if first == nil, total >= Self.longDay { first = today; settings.set("firstLongDay", String(today)) }
        ReviewTip.due = first.map { $0 < today } ?? false
    }

    #if DEBUG
    /// What the popover last reported, for the demo's terminal line and the flow check.
    @ObservationIgnored var traced: (present: Set<Kind>, quiet: Bool) = ([], false)
    func debugLine() -> String {
        func status(_ kind: Kind) -> String { "\(kind)=\(Self.tip(kind).status)" }
        return "tips: eligible=\(eligible.map(String.init(describing:)).sorted()) present=\(traced.present.map(String.init(describing:)).sorted()) quiet=\(traced.quiet) "
            + "current=\(String(describing: current(present: traced.present, quiet: traced.quiet))) " + Kind.allCases.map(status).joined(separator: " ")
    }
    #endif

    /// The one tip to show: the first eligible whose target is on screen.
    func current(present: Set<Kind>, quiet: Bool) -> Kind? {
        quiet ? nil : Kind.allCases.first { eligible.contains($0) && present.contains($0) }
    }
}

extension AppModel {
    /// The main window opened: the review tip is answered unless the tour is the one opening it.
    func noteMainWindowOpened() { tips.mainWindowOpened(tourBusy: menuTour.armed || menuTour.current != nil) }
}

struct TipTargets: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [ContextualTips.Kind: Anchor<CGRect>] = [:]
    static func reduce(value: inout [ContextualTips.Kind: Anchor<CGRect>], nextValue: () -> [ContextualTips.Kind: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks the view a tip can point at.
    func tipTarget(_ kind: ContextualTips.Kind, if enabled: Bool = true) -> some View {
        // Adds to what is already there: two targets on one view must both count.
        transformAnchorPreference(key: TipTargets.self, value: .bounds) { if enabled { $0[kind] = $1 } }
    }
}

/// Draws the popover's current tip next to its target, over the content.
struct ContextualTipsModifier: ViewModifier {
    let model: AppModel
    let drillOpen: Bool
    @State private var present: Set<ContextualTips.Kind> = []
    /// The tour ran in this appearance: the tips wait for the next one.
    @State private var toured = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let tips = model.tips, tour = model.menuTour
        let quiet = toured || tour.armed || tour.current != nil
        content
            .onPreferenceChange(TipTargets.self) { present = Set($0.keys) }
            .overlayPreferenceValue(TipTargets.self) { anchors in
                GeometryReader { proxy in
                    if let kind = tips.current(present: Set(anchors.keys), quiet: quiet), let anchor = anchors[kind] {
                        TipBubble(kind: kind, target: proxy[anchor], size: proxy.size, tips: tips)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: tips.current(present: Set(anchors.keys), quiet: quiet))
            }
            .task(id: present) {
                HoverTip.rowsShown = present.contains(.hover)
                RecategorizeTip.itemShown = present.contains(.recategorize)
                #if DEBUG
                tips.traced.present = present
                #endif
            }
            #if DEBUG
            .onChange(of: quiet, initial: true) { _, now in tips.traced.quiet = now }
            #endif
            .task(id: model.dashboard.total >= 7200) { tips.noteDay(total: model.dashboard.total, settings: model.settings) }
            .task { await tips.watchAll() }
            .onChange(of: tour.current != nil || tour.armed) { _, busy in if busy { toured = true } }
            .onChange(of: drillOpen) { _, open in if open { tips.drillOpened(quiet: quiet) } }
            .onAppear { toured = tour.armed }
    }
}

/// One line and a way to close it, in the tour's bubble.
private struct TipBubble: View {
    let kind: ContextualTips.Kind
    let target: CGRect
    let size: CGSize
    let tips: ContextualTips
    @State private var bubble = CGSize(width: 264, height: 40)

    /// Over the target when it can be: a bubble under a row would cover the rows to hover.
    private var below: Bool {
        let fitsBelow = target.maxY + 8 + bubble.height <= size.height - 6, fitsAbove = target.minY - 8 - bubble.height >= 6
        return kind == .recategorize ? fitsBelow || !fitsAbove : !fitsAbove
    }

    var body: some View {
        let width = min(300, size.width - 16)
        let x = min(max(8, target.midX - width / 2), size.width - width - 8)
        let y = below ? target.maxY + 8 : target.minY - 8 - bubble.height
        let tip = min(max(target.midX, x + 20), x + width - 20) - x
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.sm) {
            Text(ContextualTips.caption(kind)).font(.body).foregroundStyle(Design.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { tips.close(kind) } label: { Image(systemName: "xmark").font(.note.weight(.semibold)) }
                .buttonStyle(.plain).foregroundStyle(Design.ink2).help("关闭")
                .accessibilityLabel("关闭")
        }
        .padding(.horizontal, Design.Space.md).padding(.vertical, 10)
        .frame(width: width)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Design.surface)
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).strokeBorder(Design.line, lineWidth: 0.5)
                Rectangle().fill(Design.surface).frame(width: 10, height: 10).rotationEffect(.degrees(45))
                    .position(x: tip, y: below ? 0 : bubble.height)
            }
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { bubble = $0 }
        .offset(x: x, y: y)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

/// The 待确认 card's version: a line under the heading, in the card itself.
struct RecategorizeCallout: View {
    let model: AppModel
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.sm) {
            Image(systemName: "lightbulb").font(.note).foregroundStyle(Design.accent)
            Text(ContextualTips.caption(.recategorize)).font(.body).foregroundStyle(Design.ink)
            Spacer(minLength: 0)
            Button { model.tips.close(.recategorize) } label: { Image(systemName: "xmark").font(.note.weight(.semibold)) }
                .buttonStyle(.plain).foregroundStyle(Design.ink2).accessibilityLabel("关闭")
        }
        .padding(.horizontal, Design.Space.md).padding(.vertical, 8)
        .background(Design.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
    }
}
