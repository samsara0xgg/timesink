import SwiftUI

/// The top of every dashboard page, the same height and in the same place on
/// all five, so a switch changes words and never geometry. One line says
/// where in time (a control, or a label) with the page's own actions at its
/// end; under it, one sentence, and up to four figures in fixed columns on
/// the right. A figure the sentence already says is not repeated.
struct PageHeader<Control: View, Actions: View>: View {
    let sentence: Text
    let stats: [StripStat]
    /// The page's content width; below `PageLayout.wideWidth` the figures go under the sentence.
    let width: CGFloat
    @ViewBuilder var control: Control
    @ViewBuilder var actions: Actions

    static var columnWidth: CGFloat { 136 }

    var body: some View {
        let wide = width >= PageLayout.wideWidth
        VStack(alignment: .leading, spacing: Design.Space.md) {
            HStack(spacing: Design.Space.sm) {
                control
                Spacer(minLength: Design.Space.lg)
                actions
            }
            .frame(height: Design.controlHeight)
            if wide {
                HStack(alignment: .figureBaseline, spacing: Design.Space.page) {
                    headline.frame(maxWidth: .infinity, alignment: .leading)
                    columns
                }
            } else {
                headline
                columns
            }
        }
        // Fixed, so a long sentence or a missing figure moves nothing below.
        .frame(height: wide ? 96 : 148, alignment: .top)
    }

    private var headline: some View {
        sentence
            .font(.display).foregroundStyle(Design.ink)
            .lineLimit(1).minimumScaleFactor(0.7)
            .alignmentGuide(.figureBaseline) { $0[.lastTextBaseline] }
            .accessibilityAddTraits(.isHeader)
    }

    /// Right-aligned columns of one width: a page with three figures keeps
    /// the last three where a page with four has them.
    private var columns: some View {
        HStack(alignment: .figureBaseline, spacing: 0) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.label).font(.note).foregroundStyle(Design.ink2)
                    Text(verbatim: stat.value).font(.figure).foregroundStyle(stat.color)
                        .refinedNumberMotion(stat.value)
                        .alignmentGuide(.figureBaseline) { $0[.lastTextBaseline] }
                    Text(verbatim: stat.note).font(.note).foregroundStyle(Design.ink2).lineLimit(1)
                }
                .frame(width: Self.columnWidth, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// What every page shares around its content.
enum PageLayout {
    /// Content this wide puts the header's figures beside the sentence and
    /// cards side by side.
    static let wideWidth: CGFloat = 1040
}

extension View {
    /// A page's margins: the same on all five, so content starts in one place.
    func pagePadding() -> some View {
        padding(.horizontal, Design.Space.page).padding(.top, 20).padding(.bottom, Design.Space.page)
    }
}

extension VerticalAlignment {
    /// The sentence's baseline meets the figures' baseline.
    private enum FigureBaseline: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.lastTextBaseline] }
    }
    static let figureBaseline = VerticalAlignment(FigureBaseline.self)
}

struct StripStat: Identifiable {
    let id: Int
    let label: LocalizedStringKey
    let value: String
    var note = ""
    var color: Color = Design.ink
}

/// What a page shows for where in time when there is nothing to change.
struct HeaderLabel: View {
    let text: Text
    var body: some View {
        text.font(.body).foregroundStyle(Design.ink2)
    }
}

/// A card heading: the title, then a quiet caption.
struct CardHeading: View {
    let title: LocalizedStringKey
    var caption: Text?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.sm) {
            Text(title).cardTitle()
            caption?.font(.note).foregroundStyle(Design.ink2)
        }
    }
}

// MARK: - Where in time

/// A chevron, square and quiet.
struct StepperButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.medium))
                .foregroundStyle(Design.iconInk).frame(width: Design.controlHeight, height: Design.controlHeight)
                .background(hovered && enabled ? Design.hoverFill : .clear,
                            in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.3)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(label))
    }
}

/// ⌘[ and ⌘] for the page on screen only: hidden pages stay alive.
private struct StepShortcut: ViewModifier {
    let key: KeyEquivalent
    @Environment(\.pageActive) private var active
    func body(content: Content) -> some View {
        content.keyboardShortcut(active ? KeyboardShortcut(key, modifiers: .command) : nil)
    }
}

extension View {
    fileprivate func stepShortcut(_ key: KeyEquivalent) -> some View { modifier(StepShortcut(key: key)) }
}

/// 今天: previous day, the day, next day; and a way back to today.
struct DayStepper: View {
    let model: AppModel

    private var offset: Int { model.todayDayOffset }
    private var date: Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    }

    private var title: String {
        let full = date.formatted(.dateTime.month().day().weekday(.abbreviated).locale(model.textLocale))
        switch offset {
        case 0: return String(localized: "今天 \(full)")
        case -1: return String(localized: "昨天 \(full)")
        default: return full
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            StepperButton(symbol: "chevron.left", label: "前一天") { step(-1) }
                .disabled(offset <= TodayModel.farthestBack)
                .stepShortcut("[")
            Text(title).font(.body.weight(.semibold)).foregroundStyle(Design.ink).lineLimit(1).fixedSize()
                .padding(.horizontal, Design.Space.xs)
            StepperButton(symbol: "chevron.right", label: "后一天") { step(1) }
                .disabled(offset >= 0)
                .stepShortcut("]")
            if offset != 0 {
                Button("回到今天") { model.todayDayOffset = 0 }
                    .buttonStyle(PillButtonStyle()).padding(.leading, Design.Space.sm)
            }
        }
    }

    private func step(_ days: Int) {
        model.todayDayOffset = min(0, max(TodayModel.farthestBack, offset + days))
    }
}

/// 活动 and 趋势: a stretch of days; 趋势 also picks day, week or month.
struct RangeControls: View {
    @Bindable var model: AppModel
    var lenses = false
    @State private var showingCustomRange = false
    @State private var customStart = Date()
    @State private var customEnd = Date()

    private var next: DateRangeSelection { var next = model.range; next.shift(1); return next }

    var body: some View {
        HStack(spacing: Design.Space.md) {
            if lenses {
                Segmented(options: [DateRangeSelection.Kind.day, .week, .month], selection: Binding(
                    get: { model.range.kind }, set: { model.range = DateRangeSelection(kind: $0, anchor: Date()) })) { kind in
                    switch kind {
                    case .day: Text("日")
                    case .week: Text("周")
                    default: Text("月")
                    }
                }
            }
            HStack(spacing: 0) {
                StepperButton(symbol: "chevron.left", label: "上一个时段") { model.range.shift(-1) }
                    .stepShortcut("[")
                Menu {
                    ForEach(DateRangeSelection.Kind.allCases.filter { $0 != .custom }, id: \.self) { kind in
                        Button(label(for: kind)) { model.range = DateRangeSelection(kind: kind, anchor: Date()) }
                    }
                    Button(label(for: .custom)) { showingCustomRange = true }
                } label: {
                    HStack(spacing: 4) {
                        Text(rangeLabel).font(.body.weight(.semibold)).foregroundStyle(Design.ink).lineLimit(1).fixedSize()
                        Image(systemName: "chevron.down").font(.note.weight(.semibold)).foregroundStyle(Design.ink2)
                    }
                    .padding(.horizontal, Design.Space.xs)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .popover(isPresented: $showingCustomRange) { customRangePopover }
                StepperButton(symbol: "chevron.right", label: "下一个时段") { model.range.shift(1) }
                    .disabled(next.interval == model.range.interval)
                    .stepShortcut("]")
            }
        }
    }

    /// The range's name; Today and Yesterday also show their date. An
    /// older day is named by its date already.
    private var rangeLabel: String {
        let date = model.range.interval.start.formatted(.dateTime.month().day().locale(model.textLocale))
        return model.range.kind == .day && model.range.label != date ? "\(model.range.label) · \(date)" : model.range.label
    }

    private var customRangePopover: some View {
        HStack(alignment: .top, spacing: Design.Space.lg) {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                ForEach(DateRangeSelection.Kind.allCases.filter { $0 != .custom }, id: \.self) { kind in
                    Button(label(for: kind)) {
                        let range = DateRangeSelection(kind: kind, anchor: Date())
                        customStart = range.interval.start
                        customEnd = range.interval.end.addingTimeInterval(-1)
                    }.buttonStyle(.plain).frame(width: 76, height: Design.controlHeight, alignment: .leading)
                }
                Button("昨天") {
                    let date = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
                    customStart = date; customEnd = date
                }.buttonStyle(.plain).frame(width: 76, height: Design.controlHeight, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: Design.Space.md) {
                Text("选择起止日期").font(.body.weight(.semibold))
                DatePicker("开始", selection: $customStart, in: ...min(customEnd, Date()), displayedComponents: .date)
                DatePicker("结束", selection: $customEnd, in: customStart...Date(), displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden()
                HStack {
                    Text("\(Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: customStart), to: Calendar.current.startOfDay(for: customEnd)).day! + 1) 天")
                        .foregroundStyle(Design.ink2)
                    Spacer()
                    Button("应用此范围") {
                        model.range = DateRangeSelection(kind: .custom, anchor: customEnd, customStart: customStart, customEnd: customEnd)
                        showingCustomRange = false
                    }.buttonStyle(AccentButtonStyle())
                }
            }
        }
        .font(.body).padding(Design.Space.card).fixedSize()
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

// MARK: - Actions

/// 开始专注: a length from the usual few, or the page to set one.
struct FocusStartButton: View {
    let model: AppModel
    @State private var error: String?

    var body: some View {
        Group {
            if model.focus?.running != nil {
                Button { model.sidebarSelection = .focus } label: { Label("专注中", systemImage: "scope") }
                    .buttonStyle(PillButtonStyle())
            } else {
                Menu {
                    ForEach(FocusPresets.minutes, id: \.self) { minutes in
                        Button("\(minutes) 分钟") { start(minutes) }.disabled(model.focus == nil)
                    }
                    Divider()
                    Button("自定义…") { model.sidebarSelection = .focus }
                } label: { Label("开始专注", systemImage: "scope") }
                .menuStyle(.button).buttonStyle(PillButtonStyle()).menuIndicator(.hidden).fixedSize()
            }
        }
        .alert("无法开始专注", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func start(_ minutes: Int) {
        do { try model.focus?.start(minutes: minutes) } catch { self.error = error.localizedDescription }
    }
}

/// 专注: pick a category to limit.
struct AddLimitMenu: View {
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
        } label: { Label("添加限额", systemImage: "plus") }
        .menuStyle(.button).buttonStyle(PillButtonStyle()).menuIndicator(.hidden).fixedSize()
    }
}
