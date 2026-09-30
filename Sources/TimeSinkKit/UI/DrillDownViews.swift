import SwiftUI

/// C1+ hover drill-down content: the seven popover panes' subwindow bodies.
/// Every type here is a pure renderer over plain value data handed in by
/// `MenuBarDashboardView`'s content-builder methods -- none of them read
/// `AppModel`/`TrackerEngine`/`TodayDashboardModel` directly, so there's no
/// way for a hover pane to trigger `dataChanged()` or an observation
/// dependency (discipline carried over from the rest of the dashboard: see
/// `MenuBarDashboard.swift`'s header comment).

/// Shared "floating card" chrome for every drill-down pane -- the `NSPanel`
/// itself is borderless/transparent (`PanelHost.makePanel`) with its own
/// window shadow, so the droplet's glass lives entirely in the SwiftUI content.
private struct FlyoutCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .glassSurface(cornerRadius: 26)
    }
}

extension View {
    fileprivate func flyoutCard() -> some View { modifier(FlyoutCard()) }
}

// MARK: - 分数环: ScoreFlyoutView

/// 分数环 hover pane: how the score is weighted, the last two weeks as
/// met / missed / no record, and the current streak.
struct ScoreFlyoutView: View {
    let pulse: Int?
    /// One entry per day, tail = today; `nil` is a day with no record.
    let dailyPulses: [Int?]
    let threshold: Int
    let streakDays: Int
    var width: CGFloat = DrillWidths.score

    var body: some View {
        let days = Array(dailyPulses.suffix(14))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("评分").font(.headline)
                Spacer()
                Text(pulse.map { "\($0) 分" } ?? "—").font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("按分类加权：投入类 75–100 分，中性 50 分，分心类 0–25 分。\(threshold) 分算达标。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, pulse in
                        let day = Calendar.current.date(byAdding: .day, value: index - days.count + 1, to: .now) ?? .now
                        VStack(spacing: 3) {
                            square(pulse)
                                .overlay { if index == days.count - 1 { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary, lineWidth: 1.5) } }
                                .frame(height: 20)
                            Text(verbatim: "\(Calendar.current.component(.day, from: day))").font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                        }
                        .help(pulse.map { String(localized: "\(day.formatted(.dateTime.month().day())) · \($0) 分") }
                              ?? String(localized: "\(day.formatted(.dateTime.month().day())) · 无记录"))
                    }
                }
                HStack(spacing: 12) {
                    legend(square(threshold), "达标")
                    legend(square(0), "未达标")
                    legend(square(nil), "没有记录")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .padding(10).glassPlatter(cornerRadius: 14)
            HStack {
                Text("连续达标").foregroundStyle(.secondary)
                Spacer()
                Text("\(streakDays) 天").fontWeight(.semibold).monospacedDigit()
            }.font(.callout)
        }
        .frame(width: width, alignment: .leading)
        .flyoutCard()
    }

    @ViewBuilder private func square(_ pulse: Int?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        if let pulse {
            shape.fill(pulse >= threshold ? Color.green.opacity(0.85) : Color.secondary.opacity(0.25))
        } else {
            HatchFill().clipShape(shape).overlay(shape.strokeBorder(Color.secondary.opacity(0.2)))
        }
    }

    private func legend(_ swatch: some View, _ title: LocalizedStringKey) -> some View {
        HStack(spacing: 4) { swatch.frame(width: 10, height: 10); Text(title) }
    }
}

// MARK: - 专注/总计行: CompareBaseView

/// 专注/总计行 hover pane: explains CONTROLLER RULING 14's comparison basis
/// (yesterday clipped to the same elapsed time-of-day, not yesterday's full
/// day) and shows that clipped yesterday value -- `todayValue - delta`, both
/// already computed by `TodayDashboardModel.recompute`, so no new lookup.
struct CompareBaseView: View {
    let label: String
    let todayValue: TimeInterval
    let delta: TimeInterval?
    var width: CGFloat = DrillWidths.compare

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.headline)
                Spacer()
                Text("截至 \(Date.now, format: .dateTime.hour().minute())").font(.caption).foregroundStyle(.secondary)
            }
            // Rounded to whole minutes before subtracting, so the three numbers add up.
            let today = Format.minutes(todayValue)
            if let delta {
                let yesterday = Format.minutes(todayValue - delta)
                let difference = Format.minutes(todayValue) - Format.minutes(todayValue - delta)
                let top = Double(max(today, yesterday, 1))
                row("今天", minutes: today, fraction: Double(today) / top, color: .primary, secondary: false)
                row("昨天同一时刻", minutes: yesterday, fraction: Double(yesterday) / top, color: .secondary.opacity(0.5), secondary: true)
                Divider()
                HStack {
                    Text("差").foregroundStyle(.secondary)
                    Spacer()
                    Text(difference >= 0 ? "多 \(Self.text(abs(difference)))" : "少 \(Self.text(abs(difference)))")
                        .fontWeight(.semibold).monospacedDigit()
                }.font(.callout)
            } else {
                row("今天", minutes: today, fraction: 1, color: .primary, secondary: false)
                Text("昨日暂无同时段数据可比较").font(.caption).foregroundStyle(.secondary)
            }
            Text("三个数都先取整到分钟再相减，所以永远对得上。时长多少不评判好坏。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
        .flyoutCard()
    }

    static func text(_ minutes: Int) -> String { Format.chineseDuration(Double(minutes) * 60) }

    private func row(_ title: LocalizedStringKey, minutes: Int, fraction: Double, color: Color, secondary: Bool) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).foregroundStyle(secondary ? .secondary : .primary)
                Spacer()
                Text(Self.text(minutes)).monospacedDigit().foregroundStyle(secondary ? .secondary : .primary)
            }.font(.callout)
            GeometryReader { geo in
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: geo.size.width * min(1, max(0, fraction)))
            }.frame(height: 8)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 分类行: CategoryDetailView

/// 分类行 hover pane (one per category with tracked time today): that
/// category's today hourly bar chart, plus its top-5 domain/app sub-entries.
struct CategoryDetailView: View {
    struct SubEntry: Identifiable {
        let id: String
        let label: String
        let seconds: TimeInterval
    }

    let categoryID: String
    let name: String
    let colorHex: String
    let seconds: TimeInterval
    /// 24 entries, hours of tracked time per hour-of-day (today, this
    /// category only).
    let hourBars: [Double]
    /// Top 5, by duration descending.
    let subs: [SubEntry]
    var width: CGFloat = DrillWidths.category

    let onOpenActivities: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(RefinedStyle.category(categoryID, hex: colorHex)).frame(width: 8, height: 8)
                Text(name).font(.headline)
                Spacer()
                Text("今日 \(Format.duration(seconds))").font(.caption).foregroundStyle(.secondary)
            }
            HourlyActivityChart(bars: hourBars.enumerated().map { hour, hours in
                HourlyBigView.Bar(hour: hour, categoryID: name, colorHex: colorHex, seconds: hours * 3600)
            })
            .padding(8).glassPlatter(cornerRadius: 14)
            if !subs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(subs) { sub in
                        HStack {
                            Text(sub.label).font(.caption2).lineLimit(1)
                            Spacer()
                            Text(Format.duration(sub.seconds))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button(action: onOpenActivities) {
                Label("查看该分类的全部活动", systemImage: "arrow.right")
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
        .frame(width: width, alignment: .leading)
        .flyoutCard()
    }
}

// MARK: - 24h 迷你图: HourlyBigView

/// 24h 迷你图 hover pane: category-stacked hourly bars, with a 今天/近 7 天
/// segmented toggle. `todayBars` is handed in ready (derived from data the
/// dashboard already loaded); `loadLast7Bars` is called lazily, only the
/// first time the user actually switches to 近 7 天 -- that range isn't
/// otherwise fetched by the popover, so this defers the one genuinely new
/// `AppModel.rangedSpans(for:)` lookup this pane can cause until it's
/// actually asked for (and it's the same LRU-cached query path every other
/// range fetch in the app already goes through).
struct HourlyBigView: View {
    /// `id` is derived from `(hour, categoryID)`, not a fresh `UUID()` per
    /// render -- the caller (`MenuBarDashboard.swift`'s `hourlyBars(items:
    /// categories:)`) guarantees at most one `Bar` per `(hour, categoryID)`
    /// pair (fold-in 4: multi-day `stackedSeries` entries sharing an
    /// hour-of-day are summed before this type ever sees them), so this id
    /// is unique within any `[Bar]` this view receives.
    struct Bar: Identifiable {
        let hour: Int
        let categoryID: String
        let colorHex: String
        let seconds: TimeInterval

        var id: String { "\(hour)_\(categoryID)" }
    }

    private enum Mode: CaseIterable {
        case today, last7
        var label: String { self == .today ? String(localized: "今天") : String(localized: "近 7 天") }
    }

    let categories: [String: Category]
    let todayBars: [Bar]
    let loadLast7Bars: () -> [Bar]
    var width: CGFloat = DrillWidths.hourly

    @State private var mode: Mode = .today
    @State private var last7Bars: [Bar]?

    private var activeBars: [Bar] {
        switch mode {
        case .today: return todayBars
        case .last7: return last7Bars ?? []
        }
    }

    var body: some View {
        let bars = activeBars
        let categoryOrder = Array(Set(bars.map(\.categoryID)))
            .sorted { (categories[$0]?.sortOrder ?? 0) < (categories[$1]?.sortOrder ?? 0) }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("24 小时分布").font(.headline)
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: mode) { _, newMode in
                    if newMode == .last7, last7Bars == nil {
                        last7Bars = loadLast7Bars()
                    }
                }
            }
            if mode == .last7 {
                Text("近 7 天 · 按小时累计").font(.caption).foregroundStyle(.secondary)
            }
            HourlyActivityChart(bars: bars.sorted { $0.categoryID < $1.categoryID })
                .padding(8).glassPlatter(cornerRadius: 14)
            Text("纵轴按数据取整到 15 分钟；横轴只画有记录的时段。")
                .font(.caption).foregroundStyle(.secondary)
            legend(categoryOrder)
        }
        .frame(width: width, alignment: .leading)
        .flyoutCard()
    }

    private func legend(_ ids: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(ids, id: \.self) { id in
                HStack(spacing: 3) {
                    Circle().fill(RefinedStyle.category(id, hex: categories[id]?.colorHex ?? "#8E8E93")).frame(width: 6, height: 6)
                    Text(categories[id]?.name ?? id).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 预算行: BudgetProgressView

/// 预算行 hover pane: every enabled budget's progress bar (not just the
/// popover row's tightest-2).
struct BudgetProgressView: View {
    struct Row: Identifiable {
        let id: String
        let name: String
        let colorHex: String
        let spent: TimeInterval
        let limit: TimeInterval
    }

    let rows: [Row]
    let warnPercent: Int
    var width: CGFloat = DrillWidths.budget

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("限额").font(.headline)
                Spacer()
                Text("\(rows.count) 项").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { LimitRowView(row: $0, warnPercent: warnPercent) }
            Text("快到时黄色提醒一次，超出时红色加图标。只提醒，不拦截。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
        .flyoutCard()
    }
}

/// Where a limit stands. Minutes are rounded before subtracting, like every
/// other difference the popover shows.
enum LimitState: Equatable {
    case over(minutes: Int)
    case near(minutes: Int)
    case fine

    /// Near: at most `warnPercent` of the limit is left.
    static func of(spent: TimeInterval, limit: TimeInterval, warnPercent: Int) -> LimitState {
        let limitMinutes = Format.minutes(limit)
        let left = limitMinutes - Format.minutes(spent)
        if left < 0 { return .over(minutes: -left) }
        if Double(left) <= Double(limitMinutes) * Double(warnPercent) / 100 { return .near(minutes: left) }
        return .fine
    }

    /// Near and over limits are drawn as rows; the rest fold into one line.
    static func fold(_ rows: [BudgetProgressView.Row], warnPercent: Int)
        -> (shown: [BudgetProgressView.Row], fine: [BudgetProgressView.Row]) {
        let isFine = { (row: BudgetProgressView.Row) in of(spent: row.spent, limit: row.limit, warnPercent: warnPercent) == .fine }
        return (rows.filter { !isFine($0) }, rows.filter(isFine))
    }
}

/// One limit: over is red with a warning icon, near is amber with a gauge,
/// otherwise the category's own color. Never color alone.
struct LimitRowView: View {
    let row: BudgetProgressView.Row
    let warnPercent: Int

    var body: some View {
        let state = LimitState.of(spent: row.spent, limit: row.limit, warnPercent: warnPercent)
        let color: Color = switch state {
        case .over: .red
        case .near: RefinedStyle.warning
        case .fine: RefinedStyle.category(row.id, hex: row.colorHex)
        }
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                switch state {
                case .over(let minutes):
                    Label("\(row.name)超出 \(minutes) 分钟", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                case .near(let minutes):
                    Label("\(row.name)还剩 \(minutes) 分钟", systemImage: "gauge.with.dots.needle.67percent")
                        .foregroundStyle(RefinedStyle.warning)
                case .fine:
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(row.name)
                    }
                }
                Spacer(minLength: 4)
                Text("\(Format.minutes(row.spent)) / \(Format.minutes(row.limit)) 分钟")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .lineLimit(1)
            GeometryReader { geo in
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: geo.size.width * (row.limit > 0 ? min(1, row.spent / row.limit) : 0))
            }.frame(height: 6)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Widths

/// Panel-mode widths for each drill-down pane (used when `PanelHost` shows
/// the pane in its own floating `NSPanel` -- no width constraint there
/// beyond looking reasonable) -- and `compact`, the one width every pane's
/// degraded in-popover expansion (`ExpandedDrillView` in
/// `MenuBarDashboard.swift`) uses instead: the popover width minus
/// `FlyoutCard`'s 14pt/side padding and the popover's own 14pt margins, so
/// the inline expansion lines up with the sections around it and never
/// clips its trailing edge.
enum DrillWidths {
    static let score: CGFloat = 280
    static let compare: CGFloat = 240
    static let category: CGFloat = 340
    static let hourly: CGFloat = 340
    static let budget: CGFloat = 280
    static let compact: CGFloat = RefinedStyle.popoverWidth - 56
}
