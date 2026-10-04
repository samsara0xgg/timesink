import SwiftUI
import os

private let activityListLogger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "activityList")

/// Over a stretch of days: what was recorded by category (each with its
/// apps and sites, each of those with its titles), by app, or by time.
/// Every row is one height and one indent per level; the share or visits
/// and the time sit in fixed columns at the right, so all levels line up.
/// The header above already says the totals, so the card does not.
struct ActivityListView: View {
    let model: AppModel
    @Bindable var activities: ActivitiesModel
    let groups: [ActivitiesModel.CategoryGroup]
    /// Non-nil only while a search or a heatmap period narrows the list.
    let matchCount: Int?

    /// Hosted here, not in the transient context menu, which tears itself
    /// down as soon as its action runs.
    @State private var pendingTitleRule: PendingTitleRule?

    private static let countWidth: CGFloat = 72
    private static let indent: CGFloat = 20

    private var displayedGroups: [ActivitiesModel.CategoryGroup] {
        guard let filter = model.activityFilter else { return groups }
        return groups.filter { $0.id == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.md) {
            ViewThatFits(in: .horizontal) {
                HStack { heading(caption: true); Spacer(minLength: Design.Space.md); groupingControl }
                HStack { heading(caption: false); Spacer(minLength: Design.Space.md); groupingControl }
                groupingControl
            }
            if displayedGroups.isEmpty {
                Text(emptyStateText).foregroundStyle(Design.ink2).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .padding([.horizontal, .top], Design.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .designCard()
        .sheet(item: $pendingTitleRule) { TitleRuleEditor(model: model, pending: $0) }
    }

    private func heading(caption: Bool) -> some View {
        let count: Text = switch activities.grouping {
        case 0: Text("\(displayedGroups.count) 个分类")
        case 1: Text("\(activities.appGroups.count) 个应用")
        default: Text("\(activities.timeRows.count) 个时段")
        }
        return CardHeading(title: "明细", caption: caption ? count : nil)
    }

    private var groupingControl: some View {
        Segmented(options: [0, 1, 2], selection: $activities.grouping, height: 24) { option in
            switch option {
            case 0: Text("按分类")
            case 1: Text("按应用")
            default: Text("按时间")
            }
        }
        .accessibilityLabel("分组方式")
    }

    private var list: some View {
        ScrollViewReader { proxy in
            // A lazy stack instead of List: List measured every row of a
            // month-long range up front.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch activities.grouping {
                    case 0: ForEach(displayedGroups) { categoryRows($0) }
                    case 1: ForEach(activities.appGroups) { appRows($0) }
                    default: timeRows
                    }
                }
                // The fade covers this margin, never the last row.
                .padding(.bottom, Design.Space.lg)
            }
            .cardList()
            .modifier(FollowSelection(activities: activities, proxy: proxy))
        }
    }

    // MARK: Rows

    /// One row of any level: a disclosure mark when it has one, what it is,
    /// then the count column and the time column.
    private func row<Lead: View, Count: View>(level: Int, open: Bool? = nil, selected: Bool = false,
                                              height: CGFloat = Design.rowHeight, seconds: TimeInterval, strong: Bool = false,
                                              @ViewBuilder lead: () -> Lead,
                                              @ViewBuilder count: () -> Count = { EmptyView() }) -> some View {
        HStack(spacing: Design.Space.sm) {
            Image(systemName: "chevron.right").font(.note.weight(.semibold)).foregroundStyle(Design.iconInk)
                .rotationEffect(.degrees(open == true ? 90 : 0))
                .opacity(open == nil ? 0 : 1)
                .frame(width: 12)
            lead().lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Design.Space.sm)
            count().font(.note).foregroundStyle(Design.ink2).lineLimit(1)
                .frame(width: Self.countWidth, alignment: .trailing)
            Text(Format.duration(seconds)).fontWeight(strong ? .semibold : .regular)
                .foregroundStyle(strong ? Design.ink : Design.ink2)
                .frame(width: Design.durationWidth, alignment: .trailing)
        }
        .monospacedDigit()
        .padding(.leading, CGFloat(level) * Self.indent)
        .padding(.horizontal, Design.Space.sm)
        .frame(height: height)
        .background(selected ? Design.selectedFill : .clear,
                    in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func categoryColor(_ id: String) -> Color {
        RefinedStyle.category(id, hex: model.resolver.categoriesByID[id]?.colorHex ?? "#C7C7CC")
    }

    /// Level 1: a category and its share; a click folds it.
    @ViewBuilder private func categoryRows(_ group: ActivitiesModel.CategoryGroup) -> some View {
        let open = !activities.collapsedCategories.contains(group.id)
        let total = displayedGroups.reduce(0) { $0 + $1.seconds }
        let share = Int((group.seconds / max(1, total) * 100).rounded())
        Button {
            if open { activities.collapsedCategories.insert(group.id) } else { activities.collapsedCategories.remove(group.id) }
        } label: {
            row(level: 0, open: open, seconds: group.seconds, strong: true) {
                Circle().fill(RefinedStyle.category(group.id, hex: group.colorHex)).frame(width: 8, height: 8)
                Text(group.name).fontWeight(.semibold).foregroundStyle(Design.ink)
            } count: {
                Text(verbatim: share > 0 ? "\(share)%" : "<1%")
            }
        }
        .buttonStyle(HoverRowStyle())
        if open {
            ForEach(group.rows) { activityRows($0, in: group.id) }
        }
    }

    /// Level 2: a site or app. A click selects it (and opens its titles);
    /// a click on the selected one folds or opens them.
    @ViewBuilder private func activityRows(_ item: ActivitiesModel.ActivityRow, in categoryID: String) -> some View {
        let key = ActivitySelection(categoryID: categoryID, rowID: item.id)
        let open = activities.expandedRows.contains(key)
        let visits = activities.segmentCounts[key] ?? 0
        Button {
            if activities.selectedActivity == key {
                if open { activities.expandedRows.remove(key) } else { activities.expandedRows.insert(key) }
            } else {
                activities.select(key)
            }
        } label: {
            row(level: 1, open: item.titles.isEmpty ? nil : open, selected: activities.selectedActivity == key, seconds: item.seconds) {
                ActivityIcon(bundleID: item.reassignKey, domain: item.isDomain ? item.reassignKey : nil, size: 16)
                Text(item.label).foregroundStyle(Design.ink)
                if item.hasMeeting {
                    Text("会议").font(.note).foregroundStyle(Design.ink2)
                        .padding(.horizontal, 6).frame(height: 18).background(Design.track, in: Capsule())
                        .help("由日历事件自动标注")
                }
            } count: {
                if visits > 1 { Text("\(visits) 次").help("来回 \(visits) 次") }
            }
        }
        .buttonStyle(HoverRowStyle())
        .id(key)
        .contextMenu {
            Button("检查并调整分类…", systemImage: "tag") { activities.select(key, start: nil) }
        }
        if open {
            ForEach(item.titles) { titleRow($0, parent: item, categoryID: categoryID) }
        }
    }

    /// Level 3: one title of a site or app. Right-click: always file this
    /// title under a category, scoped to its site or app.
    private func titleRow(_ title: ActivitiesModel.TitleRow, parent: ActivitiesModel.ActivityRow, categoryID: String) -> some View {
        let selection = ActivitySelection(categoryID: categoryID, rowID: parent.id, title: title.title)
        return Button { activities.select(selection) } label: {
            // Under its site or app's name, where that row's icon would be blank.
            row(level: 1, selected: activities.selectedActivity == selection, seconds: title.seconds) {
                Color.clear.frame(width: 16, height: 1)
                Text(title.title).foregroundStyle(Design.ink2)
            }
        }
        .buttonStyle(HoverRowStyle())
        .id(selection)
        .help(title.title)
        .contextMenu {
            Button("始终把此标题归为…", systemImage: "text.badge.checkmark") {
                // `scopeKey` must be `parent.reassignKey` (domain/bundleID),
                // never `parent.id` -- `TitleRuleInput.affected` and
                // `Classifier.scopeMatches` both compare a rule's scopeKey
                // against `span.domain ?? span.appBundleID`, which an
                // entity row's finer-grained `id` (e.g. a specific repo)
                // never equals. A rule scoped to `id` would show a live "影响
                // 0 项" preview and never fire once saved. `scopeLabel`
                // mirrors that: an entity row shows `reassignKey`, not its
                // repo-level `label`, so the picker never promises a
                // repo-level scope it can't honor -- same honesty as the
                // 「（整站）」 reassignment-menu suffix.
                pendingTitleRule = PendingTitleRule(
                    prefill: title.title == String(localized: "(无标题)") ? "" : title.title,
                    scopeKey: parent.reassignKey,
                    scopeLabel: parent.isEntity ? parent.reassignKey : parent.label,
                    categoryID: model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }.first?.id ?? ""
                )
            }
        }
    }

    /// 按应用: an app, then its documents and sites. An app that is its own
    /// only row is one selectable row, not a header over a copy of itself.
    @ViewBuilder private func appRows(_ group: ActivitiesModel.AppGroup) -> some View {
        if group.rows.count == 1, let only = group.rows.first, only.label == group.name {
            appRow(only, app: group.id, level: 0, strong: true)
        } else {
            row(level: 0, seconds: group.seconds, strong: true) {
                AppIcon(bundleID: group.id, size: 16)
                Text(group.name).fontWeight(.semibold).foregroundStyle(Design.ink)
            }
            ForEach(group.rows) { appRow($0, app: group.id, level: 1) }
        }
    }

    private func appRow(_ item: ActivitiesModel.AppGroup.Row, app: String, level: Int, strong: Bool = false) -> some View {
        Button { activities.select(item.selection) } label: {
            row(level: level, selected: activities.selectedActivity?.row == item.selection, seconds: item.seconds, strong: strong) {
                ActivityIcon(bundleID: app, domain: item.domain, size: 16)
                Text(item.label).fontWeight(strong ? .semibold : .regular).foregroundStyle(Design.ink)
                Circle().fill(categoryColor(item.selection.categoryID)).frame(width: 6, height: 6)
                    .help(model.resolver.categoriesByID[item.selection.categoryID]?.name ?? String(localized: "未分类"))
            }
        }
        .buttonStyle(HoverRowStyle())
        .id(item.selection)
    }

    /// 按时间: folded stretches, newest first, under the day they fall on.
    @ViewBuilder private var timeRows: some View {
        let days = Dictionary(grouping: activities.timeRows) { Calendar.current.startOfDay(for: $0.start) }
        ForEach(days.keys.sorted(by: >), id: \.self) { day in
            Text(dayLabel(day)).font(.note.weight(.semibold)).foregroundStyle(Design.ink2)
                .padding(.horizontal, Design.Space.sm).padding(.top, Design.Space.md).padding(.bottom, Design.Space.xs)
            ForEach(days[day] ?? []) { timeRow($0) }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "今天") }
        if calendar.isDateInYesterday(day) { return String(localized: "昨天") }
        return day.formatted(.dateTime.weekday(.wide).month().day().locale(model.textLocale))
    }

    /// A folded stretch: its leading activity, what else it holds, and its
    /// category mix when no single activity dominates.
    private func timeRow(_ segment: TimelineSegment) -> some View {
        let part = segment.dominant
        let selected = activities.selectedActivity.map(segment.contains) == true
            && activities.selectedStart.map { segment.start <= $0 && $0 < segment.end } == true
        let others = segment.parts.dropFirst()
        let span = "\(model.time(segment.start))–\(model.time(segment.end))"
        return Button { activities.select(part.selection, start: part.longest.span.start) } label: {
            row(level: 0, selected: selected, height: 44, seconds: segment.recorded) {
                ActivityIcon(bundleID: part.appBundleID, domain: part.longest.span.domain, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(part.label).foregroundStyle(Design.ink)
                    Text(others.isEmpty ? "\(span)" : String(localized: "\(span) · 另有 \(others.count) 项"))
                        .font(.note).foregroundStyle(Design.ink2)
                }
            } count: {
                if segment.isMixed { CompositionBar(segment: segment, color: categoryColor).frame(width: 36, height: 4) }
            }
        }
        .buttonStyle(HoverRowStyle())
        .help(TimelineSegmentText.composition(segment).joined(separator: "\n"))
    }

    /// Composes search-active and category-filter-active independently
    /// (R-T9a) rather than short-circuiting on search alone: with a category
    /// chip active, `matchCount` (now scoped to that category — see
    /// `ActivitiesModel.recompute`) can be zero while the search still has
    /// hits in *other* categories (`groups`, unlike `displayedGroups`, is
    /// never narrowed by `activityFilter`) — that's a distinct state from
    /// "the search matched nothing at all" and must not claim the latter.
    private var emptyStateText: String {
        guard matchCount != nil else {
            return model.activityFilter == nil ? String(localized: "当前范围内没有活动记录") : String(localized: "该分类在当前范围内没有活动记录")
        }
        if model.activityFilter != nil && !groups.isEmpty {
            return String(localized: "该分类下没有命中的活动（其他分类还有命中，可清除分类筛选查看）")
        }
        return String(localized: "没有命中的活动（隐身窗口与未授权时段无记录）")
    }
}

/// Scrolls the list to the selected row. Its own view, so a selection
/// redraws only this and the rows, not the header's controls.
private struct FollowSelection: ViewModifier {
    let activities: ActivitiesModel
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        content.task(id: activities.selectedActivity) {
            guard let selection = activities.selectedActivity else { return }
            await Task.yield()
            proxy.scrollTo(selection, anchor: .center)
        }
    }
}
