import SwiftUI

/// The main window: one backdrop, the pages stacked on it, and a glass bar
/// floating over the top (`ShellBar`). There is no sidebar and no window
/// toolbar; pages that used to put buttons and a search field in the toolbar
/// hand them to the bar (`pageBar`, `pageSearchable`).
struct MainWindowView: View {
    let model: AppModel

    /// Keep computed data and activity navigation across page switches.
    @State private var stats = StatsModel()
    @State private var activities = ActivitiesModel()
    @State private var focusError: String?
    /// Pages opened so far. They stay alive behind the visible one, so going
    /// back to a page shows it as it was instead of building it again.
    @State private var openedPages: Set<SidebarItem> = []

    /// First open: 1280x820, or 85% of the screen it opens on when that is
    /// smaller. A size the person sets later is restored by the system.
    static var defaultSize: CGSize {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? CGSize(width: 1280, height: 820)
        return CGSize(width: max(Design.windowMinSize.width, min(1280, visible.width * 0.85)),
                      height: max(Design.windowMinSize.height, min(820, visible.height * 0.85)))
    }

    init(model: AppModel, activities: ActivitiesModel? = nil) {
        self.model = model
        _activities = State(initialValue: activities ?? ActivitiesModel())
    }

    var body: some View {
        ZStack {
            DesignBackground().ignoresSafeArea()
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .softScrollEdges()
                // The bar's height is the pages' top inset: they scroll under
                // the glass, and start below it.
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: Design.barHeight) }
        }
        .overlayPreferenceValue(PageBarKey.self) { items in
            ShellBar(model: model, items: items, startFocus: startFocus)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.shellProvidesBackground, true)
        .environment(\.locale, model.displayLocale)
        .environment(\.calendar, model.displayCalendar)
        .frame(minWidth: Design.windowMinSize.width, minHeight: Design.windowMinSize.height)
        .alert("无法开始专注", isPresented: Binding(get: { focusError != nil }, set: { if !$0 { focusError = nil } })) {
            Button("好") { focusError = nil }
        } message: { Text(focusError ?? "") }
    }

    private func startFocus(_ minutes: Int) {
        do { try model.focus?.start(minutes: minutes) }
        catch { focusError = error.localizedDescription }
    }

    private var detailContent: some View {
        PageStack {
            ForEach(SidebarItem.allCases, id: \.self) { page in
                if openedPages.contains(page) || page == model.sidebarSelection {
                    KeptPage(model: model, page: page) { pageView(page) }
                }
            }
        }
        .onChange(of: model.sidebarSelection, initial: true) { _, page in
            openedPages.insert(page)
            AppWindow.releaseHiddenPageFocus()
        }
    }

    @ViewBuilder
    private func pageView(_ page: SidebarItem) -> some View {
        switch page {
        case .today:
            TodayView(model: model, activities: activities)
        case .focus:
            FocusWorkspaceView(model: model)
        case .organization:
            OrganizationView(model: model)
        case .stats:
            StatsView(model: model, stats: stats)
        case .activities:
            ActivitiesView(model: model, activities: activities)
        }
    }
}

/// Stacks the pages at the size it is given and takes no size from them. A
/// hidden page keeps the size it last had (`KeptPage`), and a plain ZStack
/// would grow to the largest of them: shrink the window after visiting a page
/// in a big one and the whole root stayed that wide, centred and clipped.
private struct PageStack: Layout {
    static let maxContentWidth: CGFloat = 1440

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? Design.windowMinSize.width, height: proposal.height ?? Design.windowMinSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // In full screen the content stops growing and sits centred on the floor.
        let width = min(bounds.width, Self.maxContentWidth)
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: ProposedViewSize(width: width, height: bounds.height))
        }
    }
}

/// A page kept alive while another one is shown. It is transparent and
/// takes no input or focus, and it keeps the size it last had on screen, so
/// resizing the window lays it out once on return rather than while hidden.
///
/// Switching hands over, never overlaps: the page you leave fades out at once
/// and the one coming in slides in just behind it, left or right by where the
/// two sit among the tabs. Reduce Motion keeps the fade and drops the slide.
private struct KeptPage<Content: View>: View {
    let active: Bool
    /// -1 for a page before the selected one, 1 for one after: which way it
    /// waits, and so which way it leaves and arrives from.
    let side: CGFloat
    let content: Content
    @State private var size: CGSize?
    @State private var arrived = false
    @State private var visibility: PageVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, page: SidebarItem, @ViewBuilder content: () -> Content) {
        active = model.sidebarSelection == page
        let order = SidebarItem.allCases
        let mine = order.firstIndex(of: page) ?? 0, selected = order.firstIndex(of: model.sidebarSelection) ?? 0
        side = mine < selected ? -1 : 1
        self.content = content()
        _visibility = State(initialValue: PageVisibility(model: model, page: page))
    }

    var body: some View {
        // A page opened for the first time starts hidden and arrives like any
        // other, instead of appearing whole while the old one is still fading.
        let shown = active && arrived
        content
            .environment(visibility)
            .environment(\.pageActive, shown)
            .frame(width: active ? nil : size?.width, height: active ? nil : size?.height)
            .onGeometryChange(for: CGSize.self, of: \.size) { if active { size = $0 } }
            .task { arrived = true }
            // Opacity 0 already keeps clicks out. `allowsHitTesting(false)`
            // would also detach the page's AppKit views (the Activities list)
            // and reattach them on every return, ~40% of a switch.
            .opacity(shown ? 1 : 0)
            .offset(x: shown || reduceMotion ? 0 : side * 14)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : shown ? Design.pageIn : Design.pageOut, value: shown)
            .accessibilityHidden(!active)
    }
}
