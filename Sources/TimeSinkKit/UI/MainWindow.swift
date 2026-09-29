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
                .navigationTitle(windowTitle)
                .toolbar {
                    if model.sidebarSelection == .stats || model.sidebarSelection == .activities { rangeToolbar }
                    if model.sidebarSelection == .today {
                        ToolbarItem {
                            Menu {
                                ForEach([25, 45, 60, 90], id: \.self) { minutes in
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
                .navigationSubtitle(windowSubtitle)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.locale, model.displayLocale)
        .environment(\.calendar, model.displayCalendar)
        .frame(minWidth: 800, minHeight: 580)
        .alert("无法开始专注", isPresented: Binding(get: { focusError != nil }, set: { if !$0 { focusError = nil } })) {
            Button("好") { focusError = nil }
        } message: { Text(focusError ?? "") }
    }

    private var windowSubtitle: String {
        switch model.sidebarSelection {
        case .today: return Date().formatted(.dateTime.month().day().weekday(.wide))
        case .activities:
            let items = model.rangedSpans()
            return String(localized: "\(rangeLabel) · \(Format.duration(items.reduce(0) { $0 + $1.span.duration })) · \(items.count) 段")
        case .stats: return String(localized: "\(rangeLabel) · 与前一时段比较")
        case .focus:
            let sessions = (try? model.focusStore?.sessions(overlapping: DateRangeSelection.today().interval)) ?? []
            return String(localized: "今天 \(sessions.count) 次专注 · \(Format.duration(sessions.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }))")
        case .organization: return String(localized: "\(model.pendingClassificationCount) 项待分类")
        }
    }

    private var windowTitle: String {
        switch model.sidebarSelection {
        case .today: return String(localized: "今天")
        case .activities: return String(localized: "活动")
        case .stats: return String(localized: "趋势")
        case .focus: return String(localized: "专注与限额")
        case .organization: return String(localized: "分类与规则")
        }
    }

    private func openPiece(_ piece: DayOverview.Piece) {
        guard let item = piece.item else { return }
        model.activitySearch = ""
        model.openActivities(category: nil, range: .today())
        activities.recompute(model: model, events: [])
        activities.select(ActivitiesModel.selection(for: item), start: piece.start)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.sidebarSelection {
        case .today:
            TodayView(model: model, dayModel: dayModel, onSelect: openPiece)
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

    private var rangeLabel: String {
        if model.range.kind == .day {
            return "\(model.range.label) · \(model.range.interval.start.formatted(.dateTime.month().day()))"
        }
        return model.range.label
    }

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
                    Button("应用") {
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
