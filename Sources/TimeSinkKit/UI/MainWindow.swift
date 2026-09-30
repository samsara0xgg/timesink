import SwiftUI

struct MainWindowView: View {
    let model: AppModel

    /// Keep computed data and activity navigation across sidebar switches.
    @State private var stats = StatsModel()
    @State private var activities = ActivitiesModel()
    @State private var dayModel = DayOverviewModel()

    @State private var showingCustomRangePopover = false
    @State private var customRangeStart = Date()
    @State private var customRangeEnd = Date()
    @State private var focusError: String?
    /// Pages opened so far. They stay alive behind the visible one, so going
    /// back to a page shows it as it was instead of building it again.
    @State private var openedPages: Set<SidebarItem> = []

    init(model: AppModel, activities: ActivitiesModel? = nil) {
        self.model = model
        _activities = State(initialValue: activities ?? ActivitiesModel())
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 212, max: 250)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(WindowTitles(model: model, activities: activities))
                .toolbar {
                    if model.sidebarSelection == .stats || model.sidebarSelection == .activities { rangeToolbar }
                    if model.sidebarSelection == .today {
                        ToolbarItem {
                            Menu {
                                ForEach(FocusPresets.minutes, id: \.self) { minutes in
                                    Button("\(minutes) 分钟") {
                                        do { try model.focus?.start(minutes: minutes) }
                                        catch { focusError = error.localizedDescription }
                                    }.disabled(model.focus == nil || model.focus?.running != nil)
                                }
                                Divider()
                                Button("自定义…") { model.sidebarSelection = .focus }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "scope")
                                    Text("开始专注")
                                }
                            }.fixedSize()
                        }
                        ToolbarItem {
                            Button { model.openActivities(category: nil, range: .today()) } label: { Image(systemName: "magnifyingglass") }
                                .help("搜索活动")
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.locale, model.displayLocale)
        .environment(\.calendar, model.displayCalendar)
        .frame(minWidth: 800, minHeight: 580)
        .alert("无法开始专注", isPresented: Binding(get: { focusError != nil }, set: { if !$0 { focusError = nil } })) {
            Button("好") { focusError = nil }
        } message: { Text(focusError ?? "") }
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
            TodayView(model: model, dayModel: dayModel, activities: activities)
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

    @ToolbarContentBuilder
    private var rangeToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.range.shift(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .keyboardShortcut("[", modifiers: .command)
            .help("上一个时段")
            .accessibilityLabel("上一个时段")
            Button {
                model.range.shift(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(nextRange.interval == model.range.interval)
            .keyboardShortcut("]", modifiers: .command)
            .help("下一个时段")
            .accessibilityLabel("下一个时段")
            Menu(rangeLabel) {
                ForEach(DateRangeSelection.Kind.allCases.filter { $0 != .custom }, id: \.self) { kind in
                    Button(label(for: kind)) {
                        model.range = DateRangeSelection(kind: kind, anchor: Date())
                    }
                }
                Button(label(for: .custom)) { showingCustomRangePopover = true }
            }
            .popover(isPresented: $showingCustomRangePopover) {
                customRangePopover
            }
        }
    }

    private var nextRange: DateRangeSelection {
        var next = model.range
        next.shift(1)
        return next
    }

    private var rangeLabel: String { model.range.toolbarLabel }

    private var customRangePopover: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(DateRangeSelection.Kind.allCases.filter { $0 != .custom }, id: \.self) { kind in
                    Button(label(for: kind)) {
                        let range = DateRangeSelection(kind: kind, anchor: Date())
                        customRangeStart = range.interval.start
                        customRangeEnd = range.interval.end.addingTimeInterval(-1)
                    }.buttonStyle(.plain).frame(width: 75, height: 28, alignment: .leading)
                }
                Button("昨天") {
                    let date = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
                    customRangeStart = date; customRangeEnd = date
                }.buttonStyle(.plain).frame(width: 75, height: 28, alignment: .leading)
            }.font(.system(size: 12))
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("选择起止日期").font(.system(size: 13, weight: .semibold))
                DatePicker("开始", selection: $customRangeStart, in: ...min(customRangeEnd, Date()), displayedComponents: .date)
                DatePicker("结束", selection: $customRangeEnd, in: customRangeStart...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden()
                HStack {
                    Text("\(Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: customRangeStart), to: Calendar.current.startOfDay(for: customRangeEnd)).day! + 1) 天").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("应用此范围") {
                        model.range = DateRangeSelection(kind: .custom, anchor: customRangeEnd, customStart: customRangeStart, customEnd: customRangeEnd)
                        showingCustomRangePopover = false
                    }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(18).fixedSize()
        .onAppear { customRangeStart = model.range.interval.start; customRangeEnd = min(Date(), model.range.interval.end.addingTimeInterval(-1)) }
    }

    private func label(for kind: DateRangeSelection.Kind) -> String {
        switch kind {
        case .day: return String(localized: "今天")
        case .week: return String(localized: "本周")
        case .month: return String(localized: "本月")
        case .last7: return String(localized: "近 7 天")
        case .last30: return String(localized: "近 30 天")
        case .custom: return String(localized: "自定义…")
        }
    }
}

/// A page kept alive while another one is shown. It is transparent and
/// takes no input or focus, and it keeps the size it last had on screen, so
/// resizing the window lays it out once on return rather than while hidden.
private struct KeptPage<Content: View>: View {
    let active: Bool
    let content: Content
    @State private var size: CGSize?
    @State private var visibility: PageVisibility

    init(model: AppModel, page: SidebarItem, @ViewBuilder content: () -> Content) {
        active = model.sidebarSelection == page
        self.content = content()
        _visibility = State(initialValue: PageVisibility(model: model, page: page))
    }

    var body: some View {
        content
            .environment(visibility)
            .frame(width: active ? nil : size?.width, height: active ? nil : size?.height)
            .onGeometryChange(for: CGSize.self, of: \.size) { if active { size = $0 } }
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}

/// The window title and subtitle. Kept in their own view so the data they
/// read (every tracker write) refreshes only them, not the pages.
private struct WindowTitles: ViewModifier {
    let model: AppModel
    let activities: ActivitiesModel
    @State private var focusToday: (count: Int, seconds: TimeInterval) = (0, 0)
    private struct FocusKey: Equatable { let page: SidebarItem; let version: Int }

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .task(id: FocusKey(page: model.sidebarSelection, version: model.dataVersion)) {
                guard model.sidebarSelection == .focus else { return }
                let sessions = (try? model.focusStore?.sessions(overlapping: DateRangeSelection.today().interval)) ?? []
                focusToday = (sessions.count, sessions.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) })
            }
    }

    private var subtitle: String {
        switch model.sidebarSelection {
        case .today: return Date().formatted(.dateTime.month().day().weekday(.wide))
        case .activities:
            guard let count = activities.rangeCount else { return rangeLabel }
            return String(localized: "\(rangeLabel) · \(Format.duration(activities.rangeSeconds)) · \(count) 条记录")
        case .stats: return String(localized: "\(rangeLabel) · 与前一时段比较")
        case .focus:
            return String(localized: "今天 \(focusToday.count) 次专注 · \(Format.duration(focusToday.seconds))")
        case .organization: return String(localized: "\(model.pendingClassificationCount) 项待分类")
        }
    }

    private var title: String {
        switch model.sidebarSelection {
        case .today: return String(localized: "今天")
        case .activities: return String(localized: "活动")
        case .stats: return String(localized: "趋势")
        case .focus: return String(localized: "专注与限额")
        case .organization: return String(localized: "分类与规则")
        }
    }

    private var rangeLabel: String { model.range.toolbarLabel }
}

private extension DateRangeSelection {
    /// The range's name; a single day also shows its date.
    var toolbarLabel: String {
        kind == .day ? "\(label) · \(interval.start.formatted(.dateTime.month().day()))" : label
    }
}
