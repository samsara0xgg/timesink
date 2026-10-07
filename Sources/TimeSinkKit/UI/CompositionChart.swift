import SwiftUI

/// One colour of a composition, a project or a category, as the legend lists it.
struct CompositionSeries: Identifiable, Equatable {
    let id: String
    let name: String
    let color: Color
}

extension AppModel {
    /// The projects or categories present in `composition`, biggest first, in the colours the rest of the app gives them.
    func compositionSeries(_ composition: DayComposition, _ colors: TimelineColors) -> [CompositionSeries] {
        let slots = ProjectPalette.lookup(projects)
        return composition.totals(colors).map { entry in
            if colors == .project {
                guard entry.id != DayComposition.noProject else { return CompositionSeries(id: entry.id, name: String(localized: "没有项目"), color: Design.projectColor(nil)) }
                let slot = slots[SessionProjectResolver.normalized(entry.id)] ?? ProjectPalette.preferredSlot(entry.id)
                return CompositionSeries(id: entry.id, name: entry.id, color: Design.projectColor(slot))
            }
            let category = resolver.categoriesByID[entry.id]
            return CompositionSeries(id: entry.id, name: category?.name ?? String(localized: "未分类"),
                                     color: RefinedStyle.category(entry.id, hex: category?.colorHex ?? "#C7C7CC"))
        }
    }
}

extension AppModel {
    /// The day's calls as lane lines, each in its app's category colour.
    func callLines(_ calls: [CallSpan]) -> [CompositionCallLane.Line] {
        calls.map { call in
            let probe = Span(start: call.start, end: call.end, appBundleID: call.appBundleID, appName: call.appName,
                             title: nil, url: nil, domain: nil)
            let id = resolver.categoryID(for: probe)
            let hex = resolver.categoriesByID[id]?.colorHex ?? "#C7C7CC"
            return .init(id: call.id ?? 0, start: call.start, end: call.end, name: call.appName, color: RefinedStyle.category(id, hex: hex))
        }
    }
}

/// 通话: a thin line under the main band for the stretches a call app held the microphone.
struct CompositionCallLane: View {
    struct Line: Identifiable {
        let id: Int64
        let start: Date
        let end: Date
        let name: String
        let color: Color
    }

    let lines: [Line]
    let axis: DateInterval

    static let height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(lines) { line in
                    let left = proxy.size.width * axis.fraction(of: line.start)
                    let width = max(proxy.size.width * (axis.fraction(of: line.end) - axis.fraction(of: line.start)), 3)
                    Capsule().fill(line.color).frame(width: width, height: Self.height).offset(x: left)
                        .help(String(localized: "通话 · \(line.name)"))
                        .accessibilityLabel(Text("通话 · \(line.name)"))
                }
            }
        }
        .frame(height: Self.height)
    }
}

extension DateInterval {
    /// Where `date` falls along the interval, 0...1.
    func fraction(of date: Date) -> CGFloat { CGFloat(max(0, min(1, date.timeIntervalSince(start) / max(1, duration)))) }
}

/// What is not in focus is drawn at this strength.
private let fadedStrength = 0.13

/// 构成: a thin 100%-stacked column per five-minute slot, one colour per project or category.
/// `tap` gets the time under a click.
struct CompositionBars: View {
    let composition: DayComposition
    let colors: TimelineColors
    let series: [CompositionSeries]
    let axis: DateInterval
    var focus: String?
    var tap: ((Date) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let order = Dictionary(uniqueKeysWithValues: series.enumerated().map { ($1.id, $0) })
                let swatch = Dictionary(uniqueKeysWithValues: series.map { ($0.id, $0.color) })
                for (index, slot) in composition.slots.enumerated() {
                    let total = slot.total
                    let from = composition.start(of: index)
                    guard total > 0, from < axis.end else { continue }
                    let left = size.width * axis.fraction(of: from)
                    let right = size.width * axis.fraction(of: from.addingTimeInterval(DayComposition.slot))
                    // A thin seam between columns, unless they are too narrow to spare it.
                    let width = max(1, right - left - (right - left >= 3 ? 1 : 0))
                    context.drawLayer { layer in
                        layer.clip(to: Path(roundedRect: CGRect(x: left, y: 0, width: width, height: size.height), cornerRadius: min(1.5, width / 2)))
                        var bottom = size.height
                        for part in slot.parts(colors).sorted(by: { order[$0.key, default: .max] < order[$1.key, default: .max] }) {
                            let height = size.height * part.value / total
                            let color = swatch[part.key] ?? Design.ink2
                            layer.fill(Path(CGRect(x: left, y: bottom - height, width: width, height: height)),
                                       with: .color(focus == nil || focus == part.key ? color : color.opacity(fadedStrength)))
                            bottom -= height
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                tap?(axis.start.addingTimeInterval(axis.duration * Double(value.location.x / max(1, proxy.size.width))))
            })
        }
        .accessibilityHidden(true)
    }
}

/// 泳道: a row per project or category, a cell per five-minute slot lit by that row's share of it.
struct CompositionLanes: View {
    struct Row: Identifiable {
        let id: String
        let name: String
        let color: Color
        /// The series this row stands for: one, or all of "其他".
        let ids: Set<String>
    }

    let composition: DayComposition
    let colors: TimelineColors
    let rows: [Row]
    let axis: DateInterval
    var focus: String?
    var tap: ((Date) -> Void)?

    /// The biggest `limit` series, then the rest as one row.
    static func rows(_ series: [CompositionSeries], limit: Int) -> [Row] {
        let named = series.prefix(limit).map { Row(id: $0.id, name: $0.name, color: $0.color, ids: [$0.id]) }
        guard series.count > limit else { return named }
        return named + [Row(id: "\u{1}other", name: String(localized: "其他"), color: Design.ink2, ids: Set(series.dropFirst(limit).map(\.id)))]
    }

    static let gap: CGFloat = 2
    static func rowHeight(count: Int, in height: CGFloat) -> CGFloat {
        min(16, (height - gap * CGFloat(max(0, count - 1))) / CGFloat(max(1, count)))
    }

    static func active(_ row: Row, focus: String?) -> Bool { focus.map { row.ids.contains($0) } ?? true }

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let height = Self.rowHeight(count: rows.count, in: size.height)
                let shape = { (rect: CGRect) in Path(roundedRect: rect, cornerRadius: 2) }
                for (row, lane) in rows.enumerated() {
                    let top = CGFloat(row) * (height + Self.gap)
                    let strength = Self.active(lane, focus: focus) ? 1 : fadedStrength
                    context.fill(shape(CGRect(x: 0, y: top, width: size.width, height: height)), with: .color(Design.track.opacity(0.6)))
                    for (index, slot) in composition.slots.enumerated() {
                        let total = slot.total, from = composition.start(of: index)
                        guard total > 0, from < axis.end else { continue }
                        let share = lane.ids.reduce(0) { $0 + (slot.parts(colors)[$1] ?? 0) } / total
                        guard share > 0.03 else { continue }
                        let left = size.width * axis.fraction(of: from)
                        let right = size.width * axis.fraction(of: from.addingTimeInterval(DayComposition.slot))
                        let width = max(1, right - left - (right - left >= 3 ? 1 : 0))
                        context.fill(shape(CGRect(x: left, y: top, width: width, height: height)),
                                     with: .color(lane.color.opacity(min(1, 0.25 + share) * strength)))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                tap?(axis.start.addingTimeInterval(axis.duration * Double(value.location.x / max(1, proxy.size.width))))
            })
        }
        .accessibilityHidden(true)
    }
}

/// The names of the lanes, one beside each row of `CompositionLanes` of the same height.
struct CompositionLaneLabels: View {
    let rows: [CompositionLanes.Row]
    let height: CGFloat
    var focus: String?

    var body: some View {
        let rowHeight = CompositionLanes.rowHeight(count: rows.count, in: height)
        VStack(alignment: .leading, spacing: CompositionLanes.gap) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.color).frame(width: 8, height: 8)
                    Text(verbatim: row.name).font(.note).foregroundStyle(Design.ink2).lineLimit(1)
                }
                .frame(height: rowHeight)
                .opacity(CompositionLanes.active(row, focus: focus) ? 1 : 0.4)
            }
        }
        .frame(height: height, alignment: .top)
    }
}

/// Where the sessions ran: a short rounded line with a tick at its start and the session's name over it.
struct CompositionSessionLines: View {
    struct Line: Identifiable {
        let id: Date
        let start: Date
        let end: Date
        let name: String
        var selected = false
        var faded = false
    }

    let lines: [Line]
    let axis: DateInterval
    let pick: (Date) -> Void

    static let height: CGFloat = 26
    /// A line narrower than this carries no name.
    private static let nameFrom: CGFloat = 40

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(lines) { line in
                    let left = proxy.size.width * axis.fraction(of: line.start)
                    let width = max(proxy.size.width * (axis.fraction(of: line.end) - axis.fraction(of: line.start)) - BlockLabel.seam, 3)
                    let ink = line.selected ? Design.ink : Design.ink2.opacity(0.6)
                    Button { pick(line.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Group {
                                if width >= Self.nameFrom {
                                    Text(verbatim: line.name).font(.note.weight(line.selected ? .semibold : .regular))
                                        .foregroundStyle(line.selected ? Design.ink : Design.ink2).lineLimit(1)
                                } else { Color.clear }
                            }
                            .frame(width: width, height: 14, alignment: .leading)
                            ZStack(alignment: .leading) {
                                Capsule().fill(ink).frame(width: width, height: 3)
                                RoundedRectangle(cornerRadius: 1).fill(ink).frame(width: 2, height: 9)
                            }
                            .frame(width: width, height: 9)
                        }
                        .frame(width: width, height: Self.height - 1, alignment: .topLeading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(line.faded ? 0.25 : 1)
                    .offset(x: left)
                    .help(line.name)
                    .accessibilityLabel(Text(verbatim: line.name))
                }
            }
        }
        .frame(height: Self.height)
    }
}

/// What the colours stand for. A click focuses one: everything else fades, and a second click lets go.
/// Pointing at one shows the same for as long as the pointer stays.
struct CompositionLegend: View {
    let series: [CompositionSeries]
    @Binding var focus: String?
    @Binding var hover: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(series) { item in
                let on = focus == item.id
                Button { focus = on ? nil : item.id } label: {
                    HStack(spacing: 6) {
                        Circle().fill(item.color).frame(width: 8, height: 8)
                        Text(verbatim: item.name).lineLimit(1)
                    }
                    .padding(.horizontal, Design.Space.sm).frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(on ? Design.selectedFill : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity((hover ?? focus).map { $0 == item.id } ?? true ? 1 : 0.45)
                .onHover { inside in
                    if inside { hover = item.id } else if hover == item.id { hover = nil }
                }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}
