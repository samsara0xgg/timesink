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
        .frame(minWidth: 800, minHeight: 580)
        .alert("无法开始专注", isPresented: Binding(get: { focusError != nil }, set: { if !$0 { focusError = nil } })) {
            Button("好") { focusError = nil }
        } message: { Text(focusError ?? "") }
    }

    private func startFocus(_ minutes: Int) {
        do { try model.focus?.start(minutes: minutes) }
        catch { focusError = error.localizedDescription }
    }

    private var detailContent: some View {
        ZStack {
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
        content
            .environment(visibility)
            .frame(width: active ? nil : size?.width, height: active ? nil : size?.height)
            .onGeometryChange(for: CGSize.self, of: \.size) { if active { size = $0 } }
            // Opacity 0 already keeps clicks out. `allowsHitTesting(false)`
            // would also detach the page's AppKit views (the Activities list)
            // and reattach them on every return, ~40% of a switch.
            .opacity(active ? 1 : 0)
            .offset(x: active || reduceMotion ? 0 : side * 14)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : active ? Design.pageIn : Design.pageOut, value: active)
            .accessibilityHidden(!active)
    }
}
