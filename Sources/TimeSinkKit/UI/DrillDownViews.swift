import SwiftUI

/// C1+ hover drill-down content: the seven popover panes' subwindow bodies.
/// Every type here is a pure renderer over plain value data handed in by
/// `MenuBarDashboardView`'s content-builder methods -- none of them read
/// `AppModel`/`TrackerEngine`/`TodayDashboardModel` directly, so there's no
/// way for a hover pane to trigger `dataChanged()` or an observation
/// dependency (discipline carried over from the rest of the dashboard: see
/// `MenuBarDashboard.swift`'s header comment).

/// Shared "floating card" chrome for every drill-down pane -- the `NSPanel`
/// itself is borderless/transparent (`PanelHost.makePanel`), so the visual
/// chrome lives entirely in the SwiftUI content.
private struct FlyoutCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
    }
}

extension View {
    fileprivate func flyoutCard() -> some View { modifier(FlyoutCard()) }
}

// MARK: - 分数环: ScoreBreakdownView

/// 分数环 hover pane: `TodayDashboardModel.scoreContributions` rows (color
/// dot + name + per-category points + share-proportional bar + duration),
/// plus today's pulse and its 较昨日 delta.
struct ScoreBreakdownView: View {
    struct Row: Identifiable {
        let id: String
        let name: String
        let colorHex: String
        let seconds: TimeInterval
        let points: Double
        let share: Double
    }

    let rows: [Row]
    let pulse: Int?
    let pulseDelta: Int?
    /// Panel default is `DrillWidths.score`; the degraded in-popover
    /// expansion passes `DrillWidths.compact` so it fits inside the
    /// popover's own content width (F1 fix).
    var width: CGFloat = DrillWidths.score

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("分数构成").font(.headline)
                Spacer()
                if let pulse {
                    Text(pulseDelta.map { "\(pulse) · 较昨日 \(Format.signedInt($0))" } ?? "\(pulse)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            // Points take the width their widest label needs ("100 pts" in
            // English); the bar keeps at least 48pt beside dot, spacing and numbers.
            let points = rows.map { String(localized: "\(Int($0.points.rounded()))分") }
            let pointsWidth = RefinedStyle.nameColumn(points, font: .monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular), cap: 60)
            let nameWidth = RefinedStyle.nameColumn(rows.map(\.name), font: .preferredFont(forTextStyle: .caption1), cap: width - 132 - pointsWidth)
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Circle().fill(RefinedStyle.category(row.id, hex: row.colorHex)).frame(width: 8, height: 8)
                    Text(row.name).font(.caption).lineLimit(1).frame(width: nameWidth, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(RefinedStyle.category(row.id, hex: row.colorHex))
                            .frame(width: max(4, geo.size.width * row.share))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 6)
                    Text("\(Int(row.points.rounded()))分")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize().frame(width: pointsWidth, alignment: .trailing)
                    Text(Format.duration(row.seconds))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Text("每分钟按分类的投入程度计分，全天取平均。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: width, alignment: .leading)
        .flyoutCard()
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

    private var yesterdayValue: TimeInterval? { delta.map { todayValue - $0 } }
    /// Whole minutes, as `Format.duration` shows them.
    private func minutes(_ t: TimeInterval) -> TimeInterval { (t / 60).rounded(.down) * 60 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.headline)
            HStack {
                Text("今日").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Format.duration(todayValue)).font(.caption).monospacedDigit()
            }
            if let yesterdayValue, let delta {
                HStack {
                    Text("昨日同时段").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.duration(yesterdayValue)).font(.caption).monospacedDigit()
                    // The difference of the two minutes shown, so the three numbers add up.
                    Text(Format.durationDelta(minutes(todayValue) - minutes(yesterdayValue)))
                        .font(.caption2.weight(.bold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("昨日暂无同时段数据可比较").font(.caption2).foregroundStyle(.secondary)
            }
            Text("昨天只算到现在。时长多少不评判好坏。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: width, alignment: .leading)
        .flyoutCard()
    }
}

// MARK: - 连续达标行: StreakDotsView

/// 连续达标行 hover pane: 30-day dot pattern (`dailyPulses`, tail = today) --
/// filled/tinted at >= `threshold`, hollow otherwise; a `nil` entry (no
/// tracked day) renders the same as a miss.
struct StreakDotsView: View {
    let dailyPulses: [Int?]
    let threshold: Int
    let streakDays: Int
    var width: CGFloat = DrillWidths.streak

    private var metDaysCount: Int { dailyPulses.compactMap { $0 }.filter { $0 >= threshold }.count }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 10)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("连续达标").font(.headline)
                Spacer()
                Text("\(streakDays) 天 · 达标线 \(threshold) 分")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(dailyPulses.enumerated()), id: \.offset) { _, pulse in
                    RoundedRectangle(cornerRadius: 2)
                        .fill((pulse ?? 0) >= threshold ? Color.green.opacity(0.85) : Color.secondary.opacity(0.2))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            Text("近 30 天 · 达标 \(metDaysCount) 天，当前连续 \(streakDays) 天")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: width, alignment: .leading)
        .flyoutCard()
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
            Text(mode == .today ? "今天 · 00:00–24:00" : "近 7 天 · 按小时累计")
                .font(.caption).foregroundStyle(.secondary)
            HourlyActivityChart(bars: bars.sorted { $0.categoryID < $1.categoryID })
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日预算").font(.headline)
                Spacer()
                Text("\(rows.count) 项启用").font(.caption).foregroundStyle(.secondary)
            }
            // Bar keeps at least 48pt beside the 124pt of dot, spacing and totals.
            let nameWidth = RefinedStyle.nameColumn(rows.map(\.name), font: .preferredFont(forTextStyle: .caption1), cap: width - 172)
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Circle().fill(RefinedStyle.category(row.id, hex: row.colorHex)).frame(width: 8, height: 8)
                    Text(row.name).font(.caption).lineLimit(1).frame(width: nameWidth, alignment: .leading)
                    GeometryReader { geo in
                        let ratio = row.limit > 0 ? min(1, row.spent / row.limit) : 0
                        Capsule().fill(RefinedStyle.category(row.id, hex: row.colorHex))
                            .frame(width: max(4, geo.size.width * ratio))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 6)
                    Text("\(Format.duration(row.spent)) / \(Format.duration(row.limit))")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .trailing)
                }
            }
            Text("剩 \(warnPercent)% 时预警，每类每日「预警 + 上限」各一次")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(width: width, alignment: .leading)
        .flyoutCard()
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
    static let streak: CGFloat = 220
    static let category: CGFloat = 340
    static let hourly: CGFloat = 340
    static let budget: CGFloat = 280
    static let compact: CGFloat = RefinedStyle.popoverWidth - 56
}
