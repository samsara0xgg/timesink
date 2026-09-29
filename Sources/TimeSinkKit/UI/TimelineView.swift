import SwiftUI

/// A nil title selects all titles within an app/entity row.
struct ActivitySelection: Hashable {
    let categoryID: String
    let rowID: String
    var title: String? = nil
    var row: ActivitySelection { ActivitySelection(categoryID: categoryID, rowID: rowID) }
    func matches(_ other: ActivitySelection) -> Bool {
        categoryID == other.categoryID && rowID == other.rowID && (title == nil || title == other.title)
    }
}

struct TimelineBlock: Identifiable {
    let start: Date
    let end: Date
    let color: Color
    let label: String
    let tooltip: String
    var activity: ActivitySelection? = nil
    var matchesFilter = true
    // Appending to a recorded interval keeps its view identity.
    var id: String {
        "\(start.timeIntervalSince1970)|\(activity?.categoryID ?? label)|\(activity?.rowID ?? "")|\(activity?.title ?? "")"
    }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct TimelineEventBlock: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: Color
    let tooltip: String
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum TimelineNavigation {
    static func initialDate(day: Date, starts: [Date], now: Date = Date(), calendar: Calendar = .current) -> Date {
        if calendar.isDate(day, inSameDayAs: now) {
            return starts.filter { $0 <= now }.max() ?? starts.min() ?? now
        }
        return starts.min() ?? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    static func hourAnchors(day: Date, calendar: Calendar = .current) -> [Date] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        // Preserve both repeated hours on a 25-hour DST day.
        return stride(from: 0.0, to: interval.duration, by: 3600).map { interval.start.addingTimeInterval($0) }
    }
}

/// Vertically laid-out hour anchors make scrollTo reliable; blocks overlay the
/// same day origin and scale. Selection and zoom are owned by the page model.
struct DayTimelineView: View {
    let day: Date
    let blocks: [TimelineBlock]
    var events: [TimelineEventBlock] = []
    var allDay: [String] = []
    var focusBlocks: [TimelineBlock] = []
    var selectedActivity: ActivitySelection?
    var selectedStart: Date?
    var isFiltered = false
    @Binding var hourHeight: CGFloat
    let onSelect: (TimelineBlock) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let labelWidth: CGFloat = 44
    private var dayStart: Date { Calendar.current.startOfDay(for: day) }
    private var hours: [Date] { TimelineNavigation.hourAnchors(day: day) }
    private var selectedBlocks: [TimelineBlock] {
        guard let selectedActivity else { return blocks.filter(\.matchesFilter) }
        return blocks.filter { $0.matchesFilter && ($0.activity.map(selectedActivity.matches) ?? false) }
    }
    private var selectedIndex: Int? { selectedBlocks.firstIndex { $0.start == selectedStart } }
    private var selectedBlock: TimelineBlock? { selectedIndex.map { selectedBlocks[$0] } }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                Text(isFiltered ? "全天 · 筛选命中已高亮" : "全天时间轴")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button(Calendar.current.isDateInToday(day) ? "现在" : "首条记录") {
                        scroll(to: Calendar.current.isDateInToday(day) ? Date() : (blocks.first?.start ?? dayStart),
                               proxy: proxy, animated: true)
                    }
                    Spacer(minLength: 0)
                    Button { hourHeight = max(36, hourHeight - 12) } label: { Image(systemName: "minus") }
                        .disabled(hourHeight <= 36)
                        .accessibilityLabel("缩小时间轴").help("缩小时间轴")
                    Button { hourHeight = min(144, hourHeight + 12) } label: { Image(systemName: "plus") }
                        .disabled(hourHeight >= 144)
                        .accessibilityLabel("放大时间轴").help("放大时间轴")
                }
                .buttonStyle(.bordered).controlSize(.small)
                selectionSummary
                if !allDay.isEmpty {
                    Text(String(localized: "全天日程：\(allDay.joined(separator: String(localized: "、")))"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if blocks.isEmpty {
                    Text("这一天没有活动记录").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView { hourGrid }
            }
            .task(id: dayStart) {
                await Task.yield()
                let starts = blocks.filter(\.matchesFilter).map(\.start)
                scroll(to: selectedStart ?? TimelineNavigation.initialDate(day: day, starts: starts),
                       proxy: proxy, animated: false)
            }
            .onChange(of: selectedStart) { _, date in
                if let date { scroll(to: date, proxy: proxy, animated: true) }
            }
            .onChange(of: hourHeight) { _, _ in
                if let selectedStart { scroll(to: selectedStart, proxy: proxy, animated: false) }
            }
        }
    }

    @ViewBuilder private var selectionSummary: some View {
        if let selectedActivity {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedActivity.title ?? selectedBlock?.label ?? String(localized: "已选活动"))
                    .font(.caption).lineLimit(2)
                HStack {
                    if let selectedBlock {
                        Text("\(selectedBlock.start.formatted(date: .omitted, time: .shortened))–\(selectedBlock.end.formatted(date: .omitted, time: .shortened))")
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Text("\(selectedBlocks.isEmpty ? 0 : (selectedIndex ?? 0) + 1) / \(selectedBlocks.count) 段")
                    Button { move(-1) } label: { Image(systemName: "chevron.up") }
                        .disabled((selectedIndex ?? 0) == 0).accessibilityLabel("上一段活动")
                    Button { move(1) } label: { Image(systemName: "chevron.down") }
                        .disabled((selectedIndex ?? 0) >= selectedBlocks.count - 1).accessibilityLabel("下一段活动")
                }
                .font(.caption2).foregroundStyle(.secondary)
                .buttonStyle(.bordered).controlSize(.mini)
            }
        }
    }

    private func move(_ offset: Int) {
        let index = (selectedIndex ?? 0) + offset
        guard selectedBlocks.indices.contains(index) else { return }
        onSelect(selectedBlocks[index])
    }

    private func scroll(to date: Date, proxy: ScrollViewProxy, animated: Bool) {
        guard let anchor = hours.last(where: { $0 <= date }) ?? hours.first else { return }
        withAnimation(animated && !reduceMotion ? .easeOut(duration: 0.2) : nil) {
            proxy.scrollTo(anchor, anchor: .center)
        }
    }

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(hours, id: \.self) { hour in
                HStack(alignment: .top, spacing: 4) {
                    Text(String(format: "%02d:00", Calendar.current.component(.hour, from: hour)))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .leading)
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                }
                .frame(height: hourHeight, alignment: .top)
                .id(hour)
            }
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                let width = max(0, geometry.size.width - labelWidth - 4)
                let activityWidth = events.isEmpty ? width : width * 0.58
                ZStack(alignment: .topLeading) {
                    ForEach(blocks) { block in
                        activityButton(block, width: activityWidth)
                            .offset(x: labelWidth + 4, y: offset(block.start))
                    }
                    ForEach(focusBlocks) { block in
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(block.color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: activityWidth, height: height(block.duration))
                            .offset(x: labelWidth + 4, y: offset(block.start))
                            .help(block.tooltip).allowsHitTesting(false)
                    }
                    ForEach(events) { event in
                        RoundedRectangle(cornerRadius: 3).fill(event.color.opacity(0.15))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(event.color, lineWidth: 1))
                            .frame(width: width * 0.36, height: height(event.duration))
                            .offset(x: labelWidth + 4 + width * 0.64, y: offset(event.start))
                            .help(event.tooltip).accessibilityLabel(event.tooltip)
                    }
                }
            }
        }
    }

    private func activityButton(_ block: TimelineBlock, width: CGFloat) -> some View {
        let selected = block.matchesFilter && (block.activity.map { selectedActivity?.matches($0) ?? false } ?? false)
        let current = selected && selectedStart == block.start
        return Button { onSelect(block) } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(block.color.opacity(selected ? 0.95 : (block.matchesFilter ? 0.7 : 0.2)))
                .overlay {
                    if current {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary, lineWidth: 2)
                    }
                }
                .overlay(alignment: .leading) {
                    if height(block.duration) >= 22 {
                        Text(block.label).font(.caption2).lineLimit(1).padding(.horizontal, 5)
                    }
                }
                .frame(width: width, height: height(block.duration))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(block.tooltip + (block.matchesFilter ? "" : String(localized: "\n点击后清除筛选并定位此活动")))
        .accessibilityLabel(block.tooltip)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func offset(_ date: Date) -> CGFloat { max(0, date.timeIntervalSince(dayStart) / 3600 * hourHeight) }
    private func height(_ duration: TimeInterval) -> CGFloat { max(2, duration / 3600 * hourHeight) }
}
