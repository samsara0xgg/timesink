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
    /// One category's share of a mixed block, for its composition strip.
    struct Share: Identifiable {
        let id: String
        let color: Color
        let fraction: Double
    }

    let start: Date
    let end: Date
    let color: Color
    let label: String
    let tooltip: String
    /// The leading row; focus blocks have none.
    var activity: ActivitySelection? = nil
    var matchesFilter = true
    /// Folded contents; nil for focus blocks.
    var segment: TimelineSegment? = nil
    /// Per-category shares, only for blocks that mix several rows.
    var mix: [Share] = []
    /// Switch-outs drawn on the block's left edge (2.0 rule): interruptions
    /// in red, focus-blocked attempts hollow, long related switches grey.
    /// Peeks and passes are counted in the inspector, never drawn.
    var ticks: [TimelineTick] = []
    /// Highlight layer blocks drawn over a filtered day.
    var isHighlight = false
    /// Peeks that started in the block: counted for VoiceOver, never drawn.
    var peekCount = 0
    /// Light category colours read better with dark text.
    var darkInk: Bool { ["entertainment", "uncategorized", "misc", "utilities"].contains(activity?.categoryID ?? "") }
    /// The leading row's longest title, drawn after the label when it fits.
    var subtitle: String? {
        guard let title = segment?.dominant.longest.span.title, !title.isEmpty, title != label else { return nil }
        return title
    }
    // A live block that grows keeps its view identity; zoom steps that keep a
    // block's start keep it too, so SwiftUI can animate the resize.
    var id: String { "\(isHighlight ? "hit" : "block")|\(start.timeIntervalSince1970)" }
    var duration: TimeInterval { end.timeIntervalSince(start) }

    func contains(_ selection: ActivitySelection) -> Bool {
        segment?.contains(selection) ?? (activity.map(selection.matches) ?? false)
    }

    /// The first raw span of `selection` inside this block.
    func start(of selection: ActivitySelection) -> Date? {
        guard contains(selection) else { return nil }
        return segment?.firstStart(of: selection) ?? start
    }

    func covers(_ date: Date?) -> Bool {
        guard let date else { return false }
        return start <= date && date < end
    }
}

struct TimelineTick: Sendable, Equatable {
    enum Kind: Sendable { case related, interruption, blocked }
    let offset: TimeInterval
    let seconds: TimeInterval
    let kind: Kind
    /// Where the time went, for the tooltip and VoiceOver.
    let label: String
    var reason: SwitchEpisode.Reason? = nil
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

/// Zoom stops for the day timeline, in points per hour. Each stop folds
/// activity below `TimelineZoom.minimumBlockPoints` tall into its neighbours,
/// so zooming in reveals detail instead of stretching stripes.
enum TimelineZoom {
    static let stops: [CGFloat] = [36, 48, 64, 96, 144, 216, 324, 480, 720]
    static let minimumBlockPoints: CGFloat = 8
    static let labelPoints: CGFloat = 22

    /// The stop a continuous (pinch) height folds at: the nearest one not above it.
    static func stop(for hourHeight: CGFloat) -> CGFloat {
        stops.last { $0 <= hourHeight + 0.5 } ?? stops[0]
    }

    static func step(_ hourHeight: CGFloat, by offset: Int) -> CGFloat {
        let index = stops.firstIndex(of: stop(for: hourHeight)) ?? 0
        return stops[min(stops.count - 1, max(0, index + offset))]
    }

    static func resolution(for hourHeight: CGFloat) -> TimeInterval {
        TimelineSegmenter.resolution(points: minimumBlockPoints, pointsPerHour: stop(for: hourHeight))
    }

    static func resolutionLabel(for hourHeight: CGFloat) -> String {
        let seconds = resolution(for: hourHeight)
        return seconds >= 60
            ? String(localized: "合并短于 \(Int((seconds / 60).rounded())) 分钟的切换")
            : String(localized: "合并短于 \(Int(seconds.rounded())) 秒的切换")
    }
}

/// Vertically laid-out hour anchors make scrollTo reliable; blocks overlay the
/// same day origin and scale. Selection and zoom are owned by the page model.
struct DayTimelineView: View {
    @Environment(\.locale) private var locale
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
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var pinchBase: CGFloat?
    /// The tick ←→ last landed on.
    @State private var tickCursor: Date?
    /// The block under a mouse press, which the canvas dims.
    @State private var pressedBlock: String?
    /// Fits the widest hour label ("10:00 PM" in English), measured below.
    @State private var labelWidth: CGFloat = 44
    private var dayStart: Date { Calendar.current.startOfDay(for: day) }
    private var hours: [Date] { TimelineNavigation.hourAnchors(day: day) }
    /// Blocks the arrows step through: the ones holding the selection, or
    /// every selectable block when nothing is selected.
    private var selectedBlocks: [TimelineBlock] {
        let live = blocks.filter(\.matchesFilter)
        guard let selectedActivity else { return live }
        return live.filter { $0.contains(selectedActivity) }
    }
    private var selectedIndex: Int? { selectedBlocks.firstIndex { $0.covers(selectedStart) } }
    private var selectedBlock: TimelineBlock? { selectedIndex.map { selectedBlocks[$0] } }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                if !allDay.isEmpty {
                    Text(String(localized: "全天日程：\(allDay.joined(separator: String(localized: "、")))"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if blocks.isEmpty {
                    Text("这一天没有活动记录").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    hourGrid
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.leftArrow) { jumpTick(-1); return .handled }
                .onKeyPress(.rightArrow) { jumpTick(1); return .handled }
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        let base = pinchBase ?? hourHeight
                        pinchBase = base
                        hourHeight = min(TimelineZoom.stops.last!, max(TimelineZoom.stops[0], base * value.magnification))
                    }
                    .onEnded { _ in
                        pinchBase = nil
                        withAnimation(reduceMotion ? nil : RefinedStyle.stateAnimation) {
                            hourHeight = TimelineZoom.stop(for: hourHeight)
                        }
                    })
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
            .onChange(of: TimelineZoom.stop(for: hourHeight)) { _, _ in
                if let selectedStart { scroll(to: selectedStart, proxy: proxy, animated: false) }
            }
        }
    }

    /// ←→: the block holding the previous or next drawn tick.
    private func jumpTick(_ direction: Int) {
        let marks = blocks.filter(\.matchesFilter).flatMap { block in
            block.ticks.map { (date: block.start.addingTimeInterval($0.offset), block: block) }
        }.sorted { $0.date < $1.date }
        let from = tickCursor.flatMap { cursor in selectedBlock?.covers(cursor) == true ? cursor : nil }
            ?? (direction > 0 ? selectedBlock?.start.addingTimeInterval(-0.001) : selectedBlock?.end) ?? .distantPast
        guard let target = direction > 0 ? marks.first(where: { $0.date > from }) : marks.last(where: { $0.date < from }) else { return }
        tickCursor = target.date
        onSelect(target.block)
    }

    @ViewBuilder private var selectionSummary: some View {
        if let selectedActivity {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedActivity.title ?? selectedBlock?.segment?.parts.first { $0.selection == selectedActivity }?.label
                     ?? selectedBlock?.label ?? String(localized: "已选活动"))
                    .font(.caption).lineLimit(2)
                HStack {
                    if let selectedBlock {
                        Text("\(selectedBlock.start.formatted(.dateTime.hour().minute().locale(locale)))–\(selectedBlock.end.formatted(.dateTime.hour().minute().locale(locale)))")
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

    private func zoom(by offset: Int) {
        withAnimation(reduceMotion ? nil : RefinedStyle.stateAnimation) {
            hourHeight = TimelineZoom.step(hourHeight, by: offset)
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
                    Text(hour, format: .dateTime.hour().minute())
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .leading)
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                }
                .frame(height: hourHeight, alignment: .top)
                .id(hour)
            }
        }
        .background(alignment: .topLeading) {
            // Two-digit hours on both sides of noon are the widest labels.
            ZStack {
                ForEach([10.0, 22], id: \.self) { hour in
                    Text(dayStart.addingTimeInterval(hour * 3600), format: .dateTime.hour().minute())
                }
            }
            .font(.caption2).monospacedDigit().fixedSize().hidden()
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { labelWidth = max(44, ceil($0)) }
        }
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                let width = max(0, geometry.size.width - labelWidth - 8)
                let activityWidth = min(440, events.isEmpty ? width : width * 0.62)
                let eventX = labelWidth + 8 + activityWidth + 12
                let eventWidth = max(0, labelWidth + 8 + width - eventX)
                ZStack(alignment: .topLeading) {
                    TimelineBlocksCanvas(blocks: blocks, dayStart: dayStart, hourHeight: hourHeight,
                                         x: labelWidth + 8, width: activityWidth,
                                         selectedActivity: selectedActivity, selectedStart: selectedStart,
                                         isFiltered: isFiltered, pressed: pressedBlock,
                                         contrast: contrast == .increased)
                    ForEach(blocks) { block in
                        hitTarget(block)
                            .frame(width: activityWidth, height: height(block.duration))
                            .offset(x: labelWidth + 8, y: offset(block.start))
                    }
                    ForEach(focusBlocks) { block in
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: activityWidth + 10, height: height(block.duration) + 6)
                            .offset(x: labelWidth + 3, y: offset(block.start) - 3)
                            .help(block.tooltip).allowsHitTesting(false)
                    }
                    ForEach(events) { event in
                        RoundedRectangle(cornerRadius: 7).fill(event.color.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(event.color.opacity(0.7), lineWidth: 1))
                            .overlay(alignment: .topLeading) {
                                Text(event.title).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    .lineLimit(1).padding(.horizontal, 6).padding(.top, 2)
                            }
                            .frame(width: eventWidth, height: height(event.duration))
                            .offset(x: eventX, y: offset(event.start))
                            .help(event.tooltip).accessibilityLabel(event.tooltip)
                    }
                    if Calendar.current.isDateInToday(day) {
                        NowLine(dayStart: dayStart, hourHeight: hourHeight, x: labelWidth + 8, width: activityWidth)
                    }
                }
            }
        }
    }

    /// Where a block takes clicks, tooltips and VoiceOver; the canvas draws it.
    private func hitTarget(_ block: TimelineBlock) -> some View {
        let current = block.matchesFilter && (selectedActivity.map(block.contains) ?? false) && block.covers(selectedStart)
        return Button { onSelect(block) } label: { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(PressTracking(id: block.id, pressed: $pressedBlock))
            .help(block.tooltip + (block.matchesFilter ? "" : String(localized: "\n点击后清除筛选并定位此活动")))
            .accessibilityLabel(block.tooltip)
            .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func offset(_ date: Date) -> CGFloat { max(0, date.timeIntervalSince(dayStart) / 3600 * hourHeight) }
    private func height(_ duration: TimeInterval) -> CGFloat { max(2, duration / 3600 * hourHeight) }
}

/// Where "now" is, redrawn on its own every 30 s so nothing else does.
private struct NowLine: View {
    let dayStart: Date
    let hourHeight: CGFloat
    let x: CGFloat
    let width: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let y = context.date.timeIntervalSince(dayStart) / 3600 * hourHeight
            ZStack(alignment: .topLeading) {
                Capsule().fill(.red).frame(width: width + 8, height: 2)
                    .offset(x: x - 4, y: y - 1)
                Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                    .font(.system(size: 10.5, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.red, in: RoundedRectangle(cornerRadius: 5))
                    .fixedSize()
                    .offset(x: max(0, x - 46), y: y - 8)
            }
            .accessibilityElement().accessibilityLabel(Text("现在"))
        }
        .allowsHitTesting(false)
    }
}

/// Draws nothing itself; the canvas shows the press the way a plain button would.
private struct PressTracking: ButtonStyle {
    let id: String
    @Binding var pressed: String?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onChange(of: configuration.isPressed) { _, isPressed in
            if isPressed { pressed = id } else if pressed == id { pressed = nil }
        }
    }
}

/// Every activity block as one drawing. A view per block made the timeline
/// the costliest part of changing day, zooming and selecting.
private struct TimelineBlocksCanvas: View, Animatable {
    let blocks: [TimelineBlock]
    let dayStart: Date
    var hourHeight: CGFloat
    let x: CGFloat
    let width: CGFloat
    let selectedActivity: ActivitySelection?
    let selectedStart: Date?
    let isFiltered: Bool
    let pressed: String?
    /// Increase Contrast: wider ticks, heavier rings.
    var contrast = false

    nonisolated var animatableData: CGFloat {
        get { hourHeight }
        set { hourHeight = newValue }
    }

    var body: some View {
        Canvas { context, _ in
            // Category colours adapt to the appearance; resolve each once per pass.
            var resolved: [Color: Color] = [:]
            let resolve = { (color: Color) -> Color in
                if let hit = resolved[color] { return hit }
                let flat = Color(color.resolve(in: context.environment))
                resolved[color] = flat
                return flat
            }
            for block in blocks { draw(block, in: context, resolve: resolve) }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ block: TimelineBlock, in context: GraphicsContext, resolve: (Color) -> Color) {
        var context = context
        let selected = block.matchesFilter && (selectedActivity.map(block.contains) ?? false)
        let current = selected && block.covers(selectedStart)
        let dimmed = isFiltered && !block.isHighlight
        let blockHeight = max(2, block.duration / 3600 * hourHeight)
        // A seam between abutting blocks instead of notched corners.
        let shape = CGRect(x: x, y: max(0, block.start.timeIntervalSince(dayStart) / 3600 * hourHeight),
                           width: width, height: blockHeight - (blockHeight > 4 ? 2 : 0))
        let corner = min(7, shape.height / 2)
        if block.id == pressed { context.opacity = 0.75 }
        context.fill(RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: shape),
                     with: .color(resolve(block.color).opacity(selected ? 1 : (dimmed ? 0.18 : 0.9))))
        guard !dimmed else { return }

        if !block.mix.isEmpty, blockHeight >= 10 {
            let gaps = CGFloat(block.mix.count - 1)
            let heights = block.mix.map { max(1, (blockHeight - 4 - gaps) * $0.fraction) }
            var y = shape.minY + (shape.height - heights.reduce(gaps, +)) / 2
            for (share, height) in zip(block.mix, heights) {
                context.fill(Path(CGRect(x: shape.maxX - 5, y: y, width: 3, height: height)), with: .color(resolve(share.color)))
                y += height + 1
            }
        }
        if !block.ticks.isEmpty {
            // On the left edge, 4 pt proud of the block, as tall as the time
            // spent away; interruptions drawn last so they sit on top.
            for tick in block.ticks.sorted(by: { ($0.kind == .interruption ? 1 : 0) < ($1.kind == .interruption ? 1 : 0) }) {
                let y = shape.minY + min(max(0, blockHeight - 2), max(0, tick.offset / 3600 * hourHeight))
                switch tick.kind {
                case .blocked:
                    context.stroke(Circle().path(in: CGRect(x: shape.minX - 3, y: y - 2.5, width: 7, height: 7)),
                                   with: .color(.primary.opacity(0.8)), lineWidth: contrast ? 2 : 1.5)
                case .interruption, .related:
                    let height = max(2, min(blockHeight - (y - shape.minY), tick.seconds / 3600 * hourHeight))
                    let color: Color = tick.kind == .interruption ? .red : .primary.opacity(0.75)
                    context.fill(RoundedRectangle(cornerRadius: 1.5).path(in: CGRect(x: shape.minX - 4, y: y, width: contrast ? 11 : 9, height: height)),
                                 with: .color(color))
                }
            }
        }
        if current {
            context.stroke(RoundedRectangle(cornerRadius: corner + 3, style: .continuous).path(in: shape.insetBy(dx: -3, dy: -3)),
                           with: .color(.accentColor), lineWidth: 2)
        }
        if blockHeight >= TimelineZoom.labelPoints {
            // Light categories take dark ink, the rest white.
            let ink: Color = block.darkInk ? .black.opacity(0.82) : .white
            let label = context.resolve(Text(block.label).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ink))
            let duration = context.resolve(Text(Format.duration(block.segment?.recorded ?? block.duration))
                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(ink.opacity(0.9)))
            let title = block.subtitle.map { context.resolve(Text($0).font(.system(size: 11.5)).foregroundStyle(ink.opacity(0.85))) }
            let unbounded = CGSize(width: CGFloat.infinity, height: .infinity)
            let durationSize = duration.measure(in: unbounded)
            let labelSize = label.measure(in: unbounded)
            let available = shape.width - 16 - (block.mix.isEmpty ? 0 : 6)
            let showsDuration = labelSize.width + durationSize.width + 8 <= available
            let room = available - (showsDuration ? durationSize.width + 8 : 0)
            let labelWidth = max(0, min(labelSize.width, room))
            let origin = CGPoint(x: shape.minX + 8, y: shape.minY + 4)
            context.draw(label, in: CGRect(origin: origin, size: CGSize(width: labelWidth, height: labelSize.height)))
            if let title, room - labelWidth > 40 {
                let size = title.measure(in: unbounded)
                context.draw(title, in: CGRect(x: origin.x + labelWidth + 6, y: origin.y,
                                               width: min(size.width, room - labelWidth - 6), height: size.height))
            }
            if showsDuration {
                context.draw(duration, in: CGRect(x: shape.minX + 8 + available - durationSize.width, y: origin.y,
                                                  width: durationSize.width, height: durationSize.height))
            }
        }
    }
}
