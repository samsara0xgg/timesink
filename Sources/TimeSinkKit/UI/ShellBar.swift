import AppKit
import SwiftUI

// The main window's top bar: glass controls floating over the page, with the
// five tabs in a capsule at the centre. Pages add to it through the page-bar
// preferences below instead of owning a window toolbar.

/// How much the bar can afford to say at the window's width. The window can
/// shrink to 800 pt: labels fold into icons before anything collides.
enum BarDensity {
    case full, medium, compact

    init(width: CGFloat) {
        self = width >= 1200 ? .full : width >= 1000 ? .medium : .compact
    }
    /// Every tab names itself, not just the selected one.
    var tabLabels: Bool { self == .full }
    var actionLabels: Bool { self != .compact }
    var longDate: Bool { self != .compact }
}

// MARK: - What pages put in the bar

struct ShellSearch {
    var text: Binding<String>
    var prompt: LocalizedStringKey
}

struct PageBarItems {
    /// Buttons of the page itself, left of search.
    var actions: AnyView?
    var search: ShellSearch?
}

struct PageBarKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue = PageBarItems()
    static func reduce(value: inout PageBarItems, nextValue: () -> PageBarItems) {
        let next = nextValue()
        if let actions = next.actions { value.actions = actions }
        if let search = next.search { value.search = search }
    }
}

// MARK: - Layout

/// Leading, centre and trailing: the centre sits in the middle of the bar,
/// and gives way only when a side would run into it.
private struct BarLayout: Layout {
    var gap: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 800, height: proposal.height ?? Design.barHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let center = subviews[1].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .init(leading))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .init(trailing))
        let low = bounds.minX + leading.width + gap, high = bounds.maxX - trailing.width - gap - center.width
        let wanted = bounds.midX - center.width / 2
        let x = high >= low ? min(max(wanted, low), high) : low
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .init(center))
    }
}

// MARK: - The bar

struct ShellBar: View {
    let model: AppModel
    let items: PageBarItems
    let startFocus: (Int) -> Void
    @State private var density = BarDensity.full

    private var page: SidebarItem { model.sidebarSelection }

    var body: some View {
        GlassGroup(spacing: 14) {
            BarLayout {
                HStack(spacing: 18) {
                    Color.clear.frame(width: 72, height: 1)
                    leading
                }
                NavCapsule(model: model, density: density)
                HStack(spacing: 10) {
                    if let actions = items.actions { actions }
                    if page == .today { FocusStartButton(model: model, density: density, start: startFocus) }
                    SearchCapsule(model: model, provided: items.search)
                    RecordingCapsule(model: model, density: density)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: Design.barHeight)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { density = BarDensity(width: $0) }
        .background { WindowDragArea() }
        .background { TrafficLightInset(height: Design.barHeight - 18) }
    }

    @ViewBuilder private var leading: some View {
        switch page {
        case .today: DayStepper(model: model, density: density)
        case .activities, .stats: RangeControls(model: model, density: density)
        case .focus: AddLimitMenu(model: model)
        case .organization: EmptyView()
        }
    }
}

// MARK: - Tabs

/// The five tabs in one capsule: a divider between where you look (今天,
/// 活动, 趋势) and where you plan (专注, 分类), and a bead under the
/// selected one that flows to the next like a drop of water.
private struct NavCapsule: View {
    let model: AppModel
    let density: BarDensity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: SidebarItem?

    private struct TabFramesKey: PreferenceKey {
        nonisolated(unsafe) static var defaultValue: [SidebarItem: Anchor<CGRect>] = [:]
        static func reduce(value: inout [SidebarItem: Anchor<CGRect>], nextValue: () -> [SidebarItem: Anchor<CGRect>]) {
            value.merge(nextValue()) { $1 }
        }
    }

    private var selection: SidebarItem { model.sidebarSelection }

    var body: some View {
        HStack(spacing: 2) {
            tab(.today); tab(.activities); tab(.stats)
            Rectangle().fill(Design.line).frame(width: 1).padding(.vertical, 9).padding(.horizontal, 4)
            tab(.focus); tab(.organization)
        }
        .backgroundPreferenceValue(TabFramesKey.self) { [reduce = reduceMotion] frames in
            GeometryReader { proxy in
                if let anchor = frames[selection] {
                    let rect = proxy[anchor]
                    BeadBackground()
                        .frame(width: rect.width, height: rect.height)
                        .keyframeAnimator(initialValue: 1.0, trigger: selection) { content, stretch in
                            // The droplet leans into the move, then settles.
                            content.scaleEffect(x: reduce ? 1 : stretch, y: reduce ? 1 : 1 - (stretch - 1) * 0.5)
                        } keyframes: { _ in
                            KeyframeTrack {
                                CubicKeyframe(1.14, duration: 0.14)
                                SpringKeyframe(1.0, duration: 0.42, spring: Spring(response: 0.3, dampingRatio: 0.55))
                            }
                        }
                        .offset(x: rect.minX, y: rect.minY)
                        .animation(reduce ? nil : Design.bead, value: selection)
                        .animation(reduce ? nil : Design.bead, value: density)
                }
            }
        }
        .animation(reduceMotion ? nil : Design.bead, value: selection)
        .animation(reduceMotion ? nil : Design.bead, value: density)
        .padding(4)
        .frame(height: Design.navHeight)
        .navWell()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主导航")
    }

    private func info(_ page: SidebarItem) -> (title: LocalizedStringKey, symbol: String) {
        switch page {
        case .today: return ("今天", "sun.max")
        case .activities: return ("活动", "list.bullet.rectangle")
        case .stats: return ("趋势", "chart.bar.xaxis")
        case .focus: return ("专注", "scope")
        case .organization: return ("分类", "tag")
        }
    }

    private func go(_ page: SidebarItem) {
        guard page != selection else { return }
        switch page {
        case .today: model.openToday()
        case .stats: model.openStats(range: DateRangeSelection(kind: .last7, anchor: Date()))
        default: model.sidebarSelection = page
        }
    }

    private func tab(_ page: SidebarItem) -> some View {
        let selected = page == selection
        let showsLabel = selected || density.tabLabels
        let (title, symbol) = info(page)
        return Button { go(page) } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Design.accent : Design.iconInk)
                    .frame(width: 18)
                if showsLabel {
                    Text(title).font(.system(size: 13, weight: selected ? .bold : .regular))
                        .foregroundStyle(selected ? Design.accentInk : Design.ink)
                        .fixedSize()
                }
            }
            .padding(.leading, 11).padding(.trailing, showsLabel ? 14 : 11)
            .frame(height: 36)
            .background {
                Capsule().fill(Design.rowHover.opacity(hovered == page && !selected ? 0.9 : 0))
                    .animation(reduceMotion ? nil : Design.hover, value: hovered)
            }
            .overlay(alignment: .topTrailing) {
                if page == .organization, model.pendingClassificationCount > 0 {
                    Text("\(model.pendingClassificationCount)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white).padding(.horizontal, 4.5).frame(minWidth: 16, minHeight: 16)
                        .background(Design.accent, in: Capsule()).offset(x: -3, y: 1)
                        .accessibilityLabel("\(model.pendingClassificationCount) 项待分类")
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(NavTabStyle())
        .anchorPreference(key: TabFramesKey.self, value: .bounds) { [page: $0] }
        .onHover { hovered = $0 ? page : (hovered == page ? nil : hovered) }
        .help(showsLabel ? Text(verbatim: "") : Text(title))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct NavTabStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : Design.press, value: configuration.isPressed)
    }
}

// MARK: - Left: where in time

/// Previous day, the day, next day; and a way back to today.
private struct DayStepper: View {
    let model: AppModel
    let density: BarDensity
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var offset: Int { model.todayDayOffset }
    private var date: Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private var title: String {
        let full = date.formatted(.dateTime.month().day().weekday(.abbreviated).locale(locale))
        let short = date.formatted(.dateTime.month().day().locale(locale))
        switch offset {
        case 0: return density.longDate ? String(localized: "今天 \(full)") : String(localized: "今天")
        case -1: return density.longDate ? String(localized: "昨天 \(full)") : String(localized: "昨天")
        default: return density.longDate ? full : short
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                StepperButton(symbol: "chevron.left", label: "前一天") { step(-1) }
                    .disabled(offset <= TodayModel.farthestBack)
                    .keyboardShortcut("[", modifiers: .command)
                Text(title).font(.num(13, .bold)).foregroundStyle(Design.ink).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6)
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                StepperButton(symbol: "chevron.right", label: "后一天") { step(1) }
                    .disabled(offset >= 0)
                    .keyboardShortcut("]", modifiers: .command)
            }
            .padding(.horizontal, 4).frame(height: Design.controlHeight)
            .glassControl()
            if offset != 0 {
                Button { withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) { model.todayDayOffset = 0 } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.forward").font(.system(size: 12, weight: .semibold))
                        if density.actionLabels { Text("回到今天").font(.system(size: 12, weight: .semibold)) }
                    }
                    .foregroundStyle(Design.accentInk).padding(.horizontal, 12).frame(height: Design.controlHeight)
                    .glassControl(interactive: true)
                }
                .buttonStyle(.plain).help("回到今天")
                .transition(reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Design.settle, value: offset)
    }

    private func step(_ days: Int) {
        withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) {
            model.todayDayOffset = min(0, max(TodayModel.farthestBack, offset + days))
        }
    }
}

/// A round chevron inside a glass capsule.
private struct StepperButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Design.iconInk).frame(width: 32, height: 32)
                .background(Circle().fill(Design.rowHover.opacity(hovered && enabled ? 0.9 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(NavTabStyle())
        .opacity(enabled ? 1 : 0.3)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(label))
    }
}

/// Activities and Trends choose a stretch of days: day, week, month, and
/// where it sits.
private struct RangeControls: View {
    @Bindable var model: AppModel
    let density: BarDensity
    @State private var showingCustomRange = false
    @State private var customStart = Date()
    @State private var customEnd = Date()

    private var next: DateRangeSelection { var next = model.range; next.shift(1); return next }

    var body: some View {
        HStack(spacing: 10) {
            if model.sidebarSelection == .stats {
                LensPicker(options: [DateRangeSelection.Kind.day, .week, .month], selection: Binding(
                    get: { model.range.kind }, set: { model.range = DateRangeSelection(kind: $0, anchor: Date()) })) { kind in
                    switch kind {
                    case .day: Text("日")
                    case .week: Text("周")
                    default: Text("月")
                    }
                }
                .padding(.horizontal, 4).frame(height: Design.controlHeight).glassControl()
            }
            HStack(spacing: 2) {
                StepperButton(symbol: "chevron.left", label: "上一个时段") { model.range.shift(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                Menu {
                    ForEach(DateRangeSelection.Kind.allCases.filter { $0 != .custom }, id: \.self) { kind in
                        Button(label(for: kind)) { model.range = DateRangeSelection(kind: kind, anchor: Date()) }
                    }
                    Button(label(for: .custom)) { showingCustomRange = true }
                } label: {
                    Text(rangeLabel).font(.num(13, .bold)).foregroundStyle(Design.ink).lineLimit(1).fixedSize().padding(.horizontal, 6)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .popover(isPresented: $showingCustomRange) { customRangePopover }
                StepperButton(symbol: "chevron.right", label: "下一个时段") { model.range.shift(1) }
                    .disabled(next.interval == model.range.interval)
                    .keyboardShortcut("]", modifiers: .command)
            }
            .padding(.horizontal, 4).frame(height: Design.controlHeight).glassControl()
        }
    }

    /// The range's name; Today and Yesterday also show their date. An
    /// older day is named by its date already.
    private var rangeLabel: String {
        let date = model.range.interval.start.formatted(.dateTime.month().day())
        return model.range.kind == .day && model.range.label != date ? "\(model.range.label) · \(date)" : model.range.label
    }

    private var customRangePopover: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(DateRangeSelection.Kind.allCases.filter { $0 != .custom }, id: \.self) { kind in
                    Button(label(for: kind)) {
                        let range = DateRangeSelection(kind: kind, anchor: Date())
                        customStart = range.interval.start
                        customEnd = range.interval.end.addingTimeInterval(-1)
                    }.buttonStyle(.plain).frame(width: 75, height: 28, alignment: .leading)
                }
                Button("昨天") {
                    let date = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
                    customStart = date; customEnd = date
                }.buttonStyle(.plain).frame(width: 75, height: 28, alignment: .leading)
            }.font(.system(size: 12))
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("选择起止日期").font(.system(size: 13, weight: .semibold))
                DatePicker("开始", selection: $customStart, in: ...min(customEnd, Date()), displayedComponents: .date)
                DatePicker("结束", selection: $customEnd, in: customStart...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden()
                HStack {
                    Text("\(Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: customStart), to: Calendar.current.startOfDay(for: customEnd)).day! + 1) 天")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("应用此范围") {
                        model.range = DateRangeSelection(kind: .custom, anchor: customEnd, customStart: customStart, customEnd: customEnd)
                        showingCustomRange = false
                    }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(18).fixedSize()
        .onAppear { customStart = model.range.interval.start; customEnd = min(Date(), model.range.interval.end.addingTimeInterval(-1)) }
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

/// 专注与限额: pick a category to limit.
private struct AddLimitMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            let taken = Set(((try? model.budgetStore?.budgets()) ?? []).map(\.categoryID))
            ForEach(model.resolver.categoriesByID.values.filter { !taken.contains($0.id) }.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { category in
                Button(category.name) {
                    try? model.budgetStore?.setBudget(categoryID: category.id, dailySeconds: 45 * 60)
                    model.requestNotificationPermission()
                    model.settingsChanged()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text("添加限额").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Design.ink).padding(.horizontal, 14).frame(height: Design.controlHeight)
            .glassControl(interactive: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

// MARK: - Right: do, search, record

/// 开始专注: a length from the usual few, or the page to set one.
private struct FocusStartButton: View {
    let model: AppModel
    let density: BarDensity
    let start: (Int) -> Void

    var body: some View {
        if model.focus?.running != nil {
            Button { model.sidebarSelection = .focus } label: {
                label(symbol: "scope", text: "专注中", showsText: density.actionLabels)
            }
            .buttonStyle(.plain).help("专注中")
        } else {
            Menu {
                ForEach(FocusPresets.minutes, id: \.self) { minutes in
                    Button("\(minutes) 分钟") { start(minutes) }.disabled(model.focus == nil)
                }
                Divider()
                Button("自定义…") { model.sidebarSelection = .focus }
            } label: {
                label(symbol: "scope", text: "开始专注", showsText: density.actionLabels)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("开始专注")
        }
    }

    private func label(symbol: String, text: LocalizedStringKey, showsText: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Design.accent)
            if showsText { Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Design.accentInk).fixedSize() }
        }
        .padding(.leading, 12).padding(.trailing, showsText ? 16 : 12).frame(height: Design.controlHeight)
        .glassControl(interactive: true)
        .contentShape(Capsule())
    }
}

/// Search, one icon until it is wanted. A page that can be searched
/// (Activities, the rules list) gets the field right here; from elsewhere
/// the icon takes you to Activities with the field open.
private struct SearchCapsule: View {
    let model: AppModel
    let provided: ShellSearch?
    @State private var expanded = false
    @State private var wantsFocus = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { provided != nil && (expanded || !(provided?.text.wrappedValue.isEmpty ?? true)) }

    var body: some View {
        Group {
            if isOpen, let provided {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Design.iconInk)
                    TextField(provided.prompt, text: provided.text)
                        .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                        .frame(width: 190)
                        .onExitCommand { provided.text.wrappedValue = ""; close() }
                    if !provided.text.wrappedValue.isEmpty {
                        Button { provided.text.wrappedValue = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Design.ink3)
                        }.buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 14).frame(height: Design.controlHeight).glassControl()
                .transition(reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .trailing).combined(with: .opacity))
            } else {
                Button { open() } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(Design.iconInk)
                        .frame(width: Design.controlHeight, height: Design.controlHeight)
                        .glassControl(interactive: true).contentShape(Circle())
                }
                .buttonStyle(.plain).help("搜索").accessibilityLabel("搜索")
                .keyboardShortcut("f", modifiers: .command)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Design.settle, value: isOpen)
        .onChange(of: provided != nil) { _, available in
            if available, wantsFocus { wantsFocus = false; expanded = true; focused = true }
        }
    }

    private func open() {
        if provided != nil { expanded = true; focused = true; return }
        wantsFocus = true
        model.activitySearch = ""
        model.openActivities(category: nil, range: .today())
    }

    private func close() { expanded = false; focused = false }
}

/// Is TimeSink recording? A dot and a word; a menu to pause it or open Settings.
private struct RecordingCapsule: View {
    let model: AppModel
    let density: BarDensity
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // The engine's own state is not observable, so it is read on a slow
        // beat: coarse enough to cost nothing, fine enough to catch leaving.
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            let status = status
            Menu {
                if model.trackingPaused {
                    Button("继续记录", systemImage: "play.fill") { model.resumeTracking() }
                } else {
                    Text("暂停应用、网站、标题和屏幕采集")
                    Button("暂停 15 分钟", systemImage: "pause.circle") { model.pauseTracking(minutes: 15) }
                    Button("暂停 1 小时", systemImage: "clock") { model.pauseTracking(minutes: 60) }
                    Button("直到手动恢复", systemImage: "hand.raised") { model.pauseTracking(minutes: nil) }
                }
                Divider()
                Button("设置…", systemImage: "gearshape") { openSettings(); AppWindow.settings.bringForward() }
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(status.color.opacity(0.14)).frame(width: 16, height: 16)
                        Circle().fill(status.color).frame(width: 8, height: 8)
                    }
                    if density != .compact {
                        Text(status.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(status.ink).fixedSize()
                    }
                }
                .padding(.leading, 12).padding(.trailing, density == .compact ? 12 : 14).frame(height: Design.controlHeight)
                .glassControl(interactive: true)
                .contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(status.title)
            .accessibilityLabel(Text(status.title))
        }
    }

    private var status: (title: LocalizedStringKey, color: Color, ink: Color) {
        let running = model.engine.isRunning, suspended = model.engine.isSuspended
        let recording = running && !suspended && !model.trackingPaused && model.engine.currentActivity != nil
        if !model.accessibilityGranted { return ("未记录 · 需要权限", RefinedStyle.warning, RefinedStyle.warning) }
        if model.trackingPaused { return ("已暂停", RefinedStyle.warning, RefinedStyle.warning) }
        if !running { return ("记录未启动", .secondary, Design.ink2) }
        if suspended { return ("离开电脑", .secondary, Design.ink2) }
        return recording ? ("正在记录", Design.live, Design.liveInk) : ("等待活动", .secondary, Design.ink2)
    }
}

// MARK: - Window chrome

/// Drag the window by any bare part of the bar, and double-click to zoom or
/// minimise as the system says a title bar does.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2, let window else { super.mouseDown(with: event); return }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        }
    }
}

/// The traffic lights stay the system's own; this centres them in the
/// bar's height instead of a 28 pt title bar's.
private struct TrafficLightInset: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { Probe(height: height) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.height = height }

    private final class Probe: NSView {
        var height: CGFloat
        private var observers: [NSObjectProtocol] = []

        init(height: CGFloat) { self.height = height; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Observers belong to the window the view was in.
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                              NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                                              NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let container = window.standardWindowButton(.closeButton)?.superview?.superview else { return }
            var frame = container.frame
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            if container.frame != frame { container.frame = frame }
        }
    }
}
