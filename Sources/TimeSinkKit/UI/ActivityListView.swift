import SwiftUI
import os

private let activityListLogger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "activityList")

#if DEBUG
/// Counts row builds, so a test can say how many rows an interaction redraws.
@MainActor enum ActivityListProbe {
    static var rows = 0
    static var bodies = 0
}
#endif

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
        #if DEBUG
        let _ = ActivityListProbe.bodies += 1
        #endif
        return VStack(alignment: .leading, spacing: Design.Space.md) {
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
        let entries = entries
        return ScrollViewReader { proxy in
            // A lazy stack instead of List: List measured every row of a
            // month-long range up front.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // One flat run of one-view elements: a lazy stack builds
                    // and sizes only the rows near the viewport, and its
                    // scroll bar knows the true length. Nested ForEach groups
                    // were built whole and made it guess.
                    ForEach(entries) { EntryRow(list: self, entry: $0, selected: isSelected($0)).equatable() }
                }
                // The fade covers this margin, never the last row.
                .padding(.bottom, Design.Space.lg)
            }
            .cardList()
            .modifier(FollowSelection(activities: activities, proxy: proxy))
        }
    }

    /// One row of the list, whatever its level; everything a row needs that
    /// does not change with the selection is settled here, once per rebuild.
    private enum Entry: Identifiable, Equatable {
        case category(ActivitiesModel.CategoryGroup, open: Bool, share: Int)
        case activity(ActivitiesModel.ActivityRow, categoryID: String, open: Bool, visits: Int)
        case title(ActivitiesModel.TitleRow, parent: ActivitiesModel.ActivityRow, categoryID: String)
        case app(ActivitiesModel.AppGroup)
        case appRow(ActivitiesModel.AppGroup.Row, app: String, level: Int, strong: Bool, dot: Color, dotName: String)
        case day(Date)
        /// `colors`: what the stretch's category bar is drawn with.
        case time(TimelineSegment, colors: [String])

        /// Two entries that draw the same: a row is redrawn only when its entry changes.
        static func == (a: Entry, b: Entry) -> Bool {
            switch (a, b) {
            case let (.category(g1, o1, s1), .category(g2, o2, s2)): g1 == g2 && o1 == o2 && s1 == s2
            case let (.activity(i1, c1, o1, v1), .activity(i2, c2, o2, v2)): i1 == i2 && c1 == c2 && o1 == o2 && v1 == v2
            case let (.title(t1, p1, c1), .title(t2, p2, c2)): t1 == t2 && p1.id == p2.id && c1 == c2
            case let (.app(g1), .app(g2)): g1 == g2
            case let (.appRow(i1, a1, l1, s1, d1, n1), .appRow(i2, a2, l2, s2, d2, n2)): i1 == i2 && a1 == a2 && l1 == l2 && s1 == s2 && d1 == d2 && n1 == n2
            case let (.day(d1), .day(d2)): d1 == d2
            case let (.time(t1, c1), .time(t2, c2)):
                t1.id == t2.id && t1.end == t2.end && t1.recorded == t2.recorded && t1.spanCount == t2.spanCount && c1 == c2
            default: false
            }
        }

        /// `scrollTo(selection)` finds a selectable row by its selection.
        var id: AnyHashable {
            switch self {
            case .category(let group, _, _): "category:\(group.id)"
            case .activity(let item, let categoryID, _, _): ActivitySelection(categoryID: categoryID, rowID: item.id)
            case .title(let title, let parent, let categoryID): ActivitySelection(categoryID: categoryID, rowID: parent.id, title: title.title)
            case .app(let group): "app:\(group.id)"
            case .appRow(let item, _, _, _, _, _): item.selection
            case .day(let day): day
            case .time(let segment, _): segment.id
            }
        }
    }

    private var entries: [Entry] {
        switch activities.grouping {
        case 0:
            let total = displayedGroups.reduce(0) { $0 + $1.seconds }
            var out: [Entry] = []
            for group in displayedGroups {
                let open = !activities.collapsedCategories.contains(group.id)
                out.append(.category(group, open: open, share: Int((group.seconds / max(1, total) * 100).rounded())))
                guard open else { continue }
                for item in group.rows {
                    let key = ActivitySelection(categoryID: group.id, rowID: item.id)
                    let expanded = activities.expandedRows.contains(key)
                    out.append(.activity(item, categoryID: group.id, open: expanded, visits: activities.segmentCounts[key] ?? 0))
                    if expanded { out += item.titles.map { .title($0, parent: item, categoryID: group.id) } }
                }
            }
            return out
        case 1:
            return activities.appGroups.flatMap { group -> [Entry] in
                if group.rows.count == 1, let only = group.rows.first, only.label == group.name {
                    return [appEntry(only, app: group.id, level: 0, strong: true)]
                }
                return [.app(group)] + group.rows.map { appEntry($0, app: group.id, level: 1, strong: false) }
            }
        default:
            let days = Dictionary(grouping: activities.timeRows) { Calendar.current.startOfDay(for: $0.start) }
            return days.keys.sorted(by: >).flatMap { day in [Entry.day(day)] + (days[day] ?? []).map { segment in
                .time(segment, colors: segment.isMixed ? segment.parts.map { categoryHex($0.categoryID) } : [])
            } }
        }
    }

    private func appEntry(_ item: ActivitiesModel.AppGroup.Row, app: String, level: Int, strong: Bool) -> Entry {
        let id = item.selection.categoryID
        return .appRow(item, app: app, level: level, strong: strong, dot: categoryColor(id),
                       dotName: model.resolver.categoriesByID[id]?.name ?? String(localized: "未分类"))
    }

    private func categoryHex(_ id: String) -> String { model.resolver.categoriesByID[id]?.colorHex ?? "#C7C7CC" }

    /// Whether the inspected activity is this row. Read per row here, not in
    /// the row, so a selection redraws only the rows whose answer changed.
    private func isSelected(_ entry: Entry) -> Bool {
        switch entry {
        case .activity(let item, let categoryID, _, _): activities.selectedActivity == ActivitySelection(categoryID: categoryID, rowID: item.id)
        case .title(let title, let parent, let categoryID):
            activities.selectedActivity == ActivitySelection(categoryID: categoryID, rowID: parent.id, title: title.title)
        case .appRow(let item, _, _, _, _, _): activities.selectedActivity?.row == item.selection
        case .time(let segment, _):
            activities.selectedActivity.map(segment.contains) == true
                && activities.selectedStart.map { segment.start <= $0 && $0 < segment.end } == true
        default: false
        }
    }

    /// One list row as its own view: SwiftUI skips its body while `entry`
    /// and `selected` are unchanged.
    private struct EntryRow: View, Equatable {
        let list: ActivityListView
        let entry: Entry
        let selected: Bool

        nonisolated static func == (a: Self, b: Self) -> Bool { a.entry == b.entry && a.selected == b.selected }

        var body: some View {
            switch entry {
            case .category(let group, let open, let share): list.categoryRow(group, open: open, share: share)
            case .activity(let item, let categoryID, let open, let visits):
                list.activityRow(item, in: categoryID, open: open, visits: visits, selected: selected)
            case .title(let title, let parent, let categoryID): list.titleRow(title, parent: parent, categoryID: categoryID, selected: selected)
            case .app(let group): list.appHeader(group)
            case .appRow(let item, let app, let level, let strong, let dot, let dotName):
                list.appRow(item, app: app, level: level, strong: strong, dot: dot, dotName: dotName, selected: selected)
            case .day(let day):
                Text(list.dayLabel(day)).font(.note.weight(.semibold)).foregroundStyle(Design.ink2)
                    .padding(.horizontal, Design.Space.sm).padding(.top, Design.Space.md).padding(.bottom, Design.Space.xs)
            case .time(let segment, _): list.timeRow(segment, selected: selected)
            }
        }
    }

    // MARK: Rows

    /// One row of any level: a disclosure mark when it has one, what it is,
    /// then the count column and the time column.
    private func row<Lead: View, Count: View>(level: Int, open: Bool? = nil, selected: Bool = false,
                                              height: CGFloat = Design.rowHeight, seconds: TimeInterval, strong: Bool = false,
                                              @ViewBuilder lead: () -> Lead,
                                              @ViewBuilder count: () -> Count = { EmptyView() }) -> some View {
        #if DEBUG
        ActivityListProbe.rows += 1
        #endif
        return HStack(spacing: Design.Space.sm) {
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
    private func categoryRow(_ group: ActivitiesModel.CategoryGroup, open: Bool, share: Int) -> some View {
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
    }

    /// Level 2: a site or app. A click selects it (and opens its titles);
    /// a click on the selected one folds or opens them.
    private func activityRow(_ item: ActivitiesModel.ActivityRow, in categoryID: String, open: Bool, visits: Int, selected: Bool) -> some View {
        let key = ActivitySelection(categoryID: categoryID, rowID: item.id)
        return Button {
            if activities.selectedActivity == key {
                if open { activities.expandedRows.remove(key) } else { activities.expandedRows.insert(key) }
            } else {
                activities.select(key)
            }
        } label: {
            row(level: 1, open: item.titles.isEmpty ? nil : open, selected: selected, seconds: item.seconds) {
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
        .contextMenu {
            Button("检查并调整分类…", systemImage: "tag") { activities.select(key, start: nil) }
        }
    }

    /// Level 3: one title of a site or app. Right-click: always file this
    /// title under a category, scoped to its site or app.
    private func titleRow(_ title: ActivitiesModel.TitleRow, parent: ActivitiesModel.ActivityRow, categoryID: String, selected: Bool) -> some View {
        let selection = ActivitySelection(categoryID: categoryID, rowID: parent.id, title: title.title)
        return Button { activities.select(selection) } label: {
            // Under its site or app's name, where that row's icon would be blank.
            row(level: 1, selected: selected, seconds: title.seconds) {
                Color.clear.frame(width: 16, height: 1)
                Text(title.title).foregroundStyle(Design.ink2)
            }
        }
        .buttonStyle(HoverRowStyle())
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
    /// only row is one selectable row (`appRow`), not a header over a copy of itself.
    private func appHeader(_ group: ActivitiesModel.AppGroup) -> some View {
        row(level: 0, seconds: group.seconds, strong: true) {
            AppIcon(bundleID: group.id, size: 16)
            Text(group.name).fontWeight(.semibold).foregroundStyle(Design.ink)
        }
    }

    private func appRow(_ item: ActivitiesModel.AppGroup.Row, app: String, level: Int, strong: Bool, dot: Color, dotName: String, selected: Bool) -> some View {
        Button { activities.select(item.selection) } label: {
            row(level: level, selected: selected, seconds: item.seconds, strong: strong) {
                ActivityIcon(bundleID: app, domain: item.domain, size: 16)
                Text(item.label).fontWeight(strong ? .semibold : .regular).foregroundStyle(Design.ink)
                Circle().fill(dot).frame(width: 6, height: 6).help(dotName)
            }
        }
        .buttonStyle(HoverRowStyle())
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "今天") }
        if calendar.isDateInYesterday(day) { return String(localized: "昨天") }
        return day.formatted(.dateTime.weekday(.wide).month().day().locale(model.textLocale))
    }

    /// A folded stretch: its leading activity, what else it holds, and its
    /// category mix when no single activity dominates.
    private func timeRow(_ segment: TimelineSegment, selected: Bool) -> some View {
        let part = segment.dominant
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
