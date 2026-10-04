import SwiftUI

/// The main window: one floor, the pages stacked on it, and a flat bar at
/// the top (`ShellBar`) that is the same on every page. There is no sidebar
/// and no window toolbar; a page that can be searched binds the bar's field
/// (`pageSearchable`), and its other controls sit in its own header.
struct MainWindowView: View {
    let model: AppModel

    /// Keep computed data and activity navigation across page switches.
    @State private var stats = StatsModel()
    @State private var activities = ActivitiesModel()
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
                // The bar's height is the pages' top inset: they start below
                // it and scroll under it.
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: Design.barHeight) }
        }
        .overlayPreferenceValue(PageBarKey.self) { items in
            ShellBar(model: model, items: items)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.shellProvidesBackground, true)
        .environment(\.locale, model.displayLocale)
        .environment(\.calendar, model.displayCalendar)
        .frame(minWidth: Design.windowMinSize.width, minHeight: Design.windowMinSize.height)
        // Trends is opened on its default range with its numbers already
        // worked out: ready a moment after the window, then kept fresh while
        // it is open, all at low priority and off the main actor.
        .task(priority: .utility) {
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            while !Task.isCancelled {
                await stats.recompute(model: model, range: DateRangeSelection(kind: .last7, anchor: Date()))
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
        .onChange(of: model.dataEditVersion) { _, _ in
            Task(priority: .utility) { await stats.recompute(model: model, range: DateRangeSelection(kind: .last7, anchor: Date())) }
        }
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
/// A switch is a short cross-fade in place: nothing slides or grows, and
/// what the pages share (the header, the first row of cards) stays put.
private struct KeptPage<Content: View>: View {
    let active: Bool
    let content: Content
    @State private var size: CGSize?
    @State private var arrived = false
    @State private var visibility: PageVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, page: SidebarItem, @ViewBuilder content: () -> Content) {
        active = model.sidebarSelection == page
        self.content = content()
        _visibility = State(initialValue: PageVisibility(model: model, page: page))
    }

    var body: some View {
        // A page opened for the first time starts hidden and fades in like
        // any other, instead of appearing whole over the one fading out.
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
            // The page left goes at once; the page arriving fades in over
            // the bare floor, never through a double exposure of the two.
            .animation(shown ? Design.motion(Design.page, reduced: reduceMotion) : nil, value: shown)
            .accessibilityHidden(!active)
    }
}
