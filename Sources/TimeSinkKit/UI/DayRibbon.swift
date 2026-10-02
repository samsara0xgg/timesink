import SwiftUI
import AppKit

struct DayRibbonView: View {
    let overview: DayOverview
    var compact = false
    var events: [CalendarEvent] = []
    var onSelect: ((DayOverview.Piece) -> Void)?
    private var interval: DateInterval { overview.displayInterval }
    @Environment(\.locale) private var locale
    private struct Tick: Identifiable {
        let id: Date
        let text: String
        let width: CGFloat
        let x: CGFloat
        var isNow = false
    }
    private func ticks(width: CGFloat) -> [Tick] {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        func label(_ date: Date) -> (text: String, width: CGFloat) {
            let text = date.formatted(.dateTime.hour().minute().locale(locale))
            return (text, min(width, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2))
        }
        func hours(every step: Int) -> [Date] {
            var result: [Date] = []
            var time = interval.start
            while time < interval.end {
                result.append(time)
                guard let next = Calendar.current.date(byAdding: .hour, value: step, to: time) else { break }
                time = next
            }
            return result
        }
        // One even step that fits every label, edge-pinned ones included,
        // rather than hourly labels with gaps where collisions dropped some.
        let widest = hours(every: 1).map { label($0).width }.max() ?? 0
        let perHour = width / max(1, interval.duration / 3600)
        // The popover's band reads at a glance: 8:00, 11:00, 14:00, 17:00.
        let step: Int = [1, 2, 3, 4, 6].first(where: { (!compact || $0 >= 3) && CGFloat($0) * perHour >= widest * 1.5 + 8 }) ?? 6
        var result: [Tick] = []
        // The right edge gets a label only on the step's grid; an off-grid
        // edge label would crowd out the last even tick.
        let alignedEnd = interval.duration.truncatingRemainder(dividingBy: Double(step) * 3600) == 0
        func tick(_ date: Date) -> Tick {
            let (text, labelWidth) = label(date)
            let x = max(0, min(width - labelWidth, bounds(start: date, end: date, width: width).minX - labelWidth / 2))
            return Tick(id: date, text: text, width: labelWidth, x: x)
        }
        for date in hours(every: step) + (alignedEnd ? [interval.end] : []) {
            let next = tick(date)
            if date == interval.end {
                while let last = result.last, next.x < last.x + last.width + 8 { result.removeLast() }
            }
            if result.last.map({ next.x >= $0.x + $0.width + 8 }) ?? true { result.append(next) }
        }
        // Now's own label wins over any hour label it would touch.
        var now = tick(overview.now)
        now.isNow = true
        return result.filter { $0.x + $0.width + 6 <= now.x || $0.x >= now.x + now.width + 6 } + [now]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    if !compact {
                        ForEach(events.filter { !$0.isAllDay }) { event in
                            let rect = bounds(start: event.start, end: event.end, width: geometry.size.width)
                            Text(event.title).font(.system(size: 11)).lineLimit(1).padding(.horizontal, 4)
                                .frame(width: rect.width, height: 16, alignment: .leading)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                                .offset(x: rect.minX).help(event.title)
                        }
                    }
                    let nowX = bounds(start: overview.now, end: overview.now, width: geometry.size.width).minX
                    ZStack(alignment: .topLeading) {
                        let past = bounds(start: interval.start, end: overview.now, width: geometry.size.width)
                        Rectangle().fill(.quaternary.opacity(0.5)).frame(width: past.width)
                        // The rest of the day is still to come: a faint dashed outline.
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .frame(width: max(0, geometry.size.width - past.width)).offset(x: past.width)
                        ForEach(ribbonPieces(width: geometry.size.width)) { piece in
                            let rect = bounds(start: piece.start, end: piece.end, width: geometry.size.width)
                            Group {
                                if let segment = piece.segment {
                                    let categoryID = segment.leadingCategoryID
                                    Rectangle().fill(RefinedStyle.category(categoryID, hex: categoryHex(categoryID)))
                                        .overlay { if categoryID == "uncategorized" { HatchFill() } }
                                } else { HatchFill() }
                            }
                            .frame(width: rect.width)
                            .offset(x: rect.minX)
                            .help(Self.tooltip(piece, overview: overview, locale: locale))
                            .onTapGesture { if piece.item != nil { onSelect?(piece) } }
                            .accessibilityHidden(true)
                        }
                    }.frame(height: compact ? 12 : 26).clipShape(RoundedRectangle(cornerRadius: 5)).offset(y: compact ? 0 : 20)
                    Rectangle().fill(.primary).frame(width: 1.5, height: compact ? 18 : 32)
                        .offset(x: nowX, y: compact ? -3 : 17)
                    if !compact {
                        ForEach(Array(overview.sessions.enumerated()), id: \.offset) { _, session in
                            let rect = bounds(start: session.start, end: session.end, width: geometry.size.width)
                            Capsule().fill(.tint).frame(width: rect.width, height: 3).offset(x: rect.minX, y: 50)
                        }
                    }
                }
            }.frame(height: compact ? 12 : 54)
            GeometryReader { geometry in
                ForEach(ticks(width: geometry.size.width)) { tick in
                    Text(tick.text).font(.system(size: 11, weight: tick.isNow ? .semibold : .regular)).monospacedDigit()
                        .foregroundStyle(tick.isNow ? .primary : .secondary)
                        .fixedSize().frame(width: tick.width)
                        .offset(x: tick.x)
                }

            }.frame(height: 14)
            if !compact {
                HStack(spacing: 14) {
                    Label("专注会话", systemImage: "minus").foregroundStyle(.tint)
                    Label("日程", systemImage: "rectangle")
                    Label("未记录", systemImage: "rectangle.dashed")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("时间带，\(interval.start.formatted(.dateTime.hour().minute().locale(locale))) 至 \(interval.end.formatted(.dateTime.hour().minute().locale(locale)))，已记录 \(Format.duration(overview.total))。片段详情见活动列表。")
    }

    private func bounds(start: Date, end: Date, width: CGFloat) -> CGRect {
        let left = max(0, min(1, start.timeIntervalSince(interval.start) / interval.duration))
        let right = max(left, min(1, end.timeIntervalSince(interval.start) / interval.duration))
        return CGRect(x: width * left, y: 0, width: width * (right - left), height: 26)
    }

    /// Folded at the band's own scale: nothing narrower than a few points,
    /// so a day of window switching reads as stretches, not stripes.
    private func ribbonPieces(width: CGFloat) -> [DayOverview.Piece] {
        let hours = max(interval.duration / 3600, 1)
        let resolution = TimelineSegmenter.resolution(points: compact ? 3 : 4, pointsPerHour: width / hours)
        return DayOverview.pieces(overview.items, resolution: resolution, grouping: .category, forDrawing: true)
    }

    private func categoryHex(_ id: String) -> String {
        overview.categories.first { $0.id == id }?.colorHex ?? "#C7C7CC"
    }

    static func tooltip(_ piece: DayOverview.Piece, overview: DayOverview, locale: Locale) -> String {
        let time = "\(piece.start.formatted(.dateTime.hour().minute().locale(locale)))–\(piece.end.formatted(.dateTime.hour().minute().locale(locale)))"
        guard let segment = piece.segment else {
            return String(localized: "未记录 · \(time) · \(Format.duration(piece.seconds))")
        }
        let name = overview.categories.first { $0.id == segment.leadingCategoryID }?.name ?? String(localized: "未分类")
        return ([String(localized: "\(name) · \(time) · \(Format.duration(segment.recorded))")]
            + TimelineSegmentText.composition(segment)).joined(separator: "\n")
    }
}

/// A folded segment's mix as one proportional bar, a colour per category.
struct CompositionBar: View {
    let segment: TimelineSegment
    var axis: Axis = .horizontal
    let color: (String) -> Color

    private var shares: [(id: String, seconds: TimeInterval)] {
        var seconds: [String: TimeInterval] = [:]
        for part in segment.parts { seconds[part.categoryID, default: 0] += part.seconds }
        return seconds.map { ($0.key, $0.value) }.sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds > $1.seconds }
    }

    var body: some View {
        GeometryReader { geometry in
            let length = axis == .horizontal ? geometry.size.width : geometry.size.height
            let total = max(1, segment.recorded)
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 1)) : AnyLayout(VStackLayout(spacing: 1))
            layout {
                ForEach(shares, id: \.id) { share in
                    let size = max(1, (length - CGFloat(shares.count - 1)) * share.seconds / total)
                    Rectangle().fill(color(share.id))
                        .frame(width: axis == .horizontal ? size : nil, height: axis == .vertical ? size : nil)
                }
            }
        }
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// Shared wording for a folded segment's contents.
enum TimelineSegmentText {
    /// Up to `limit` rows by time, then what was left out and how choppy it was.
    static func composition(_ segment: TimelineSegment, limit: Int = 4) -> [String] {
        var lines = segment.parts.prefix(limit).map { "\($0.label) \(Format.duration($0.seconds))" }
        if segment.parts.count > limit {
            let rest = segment.parts.dropFirst(limit)
            lines.append(String(localized: "另有 \(rest.count) 项 · \(Format.duration(rest.reduce(0) { $0 + $1.seconds }))"))
        }
        if segment.switches > 0 {
            lines.append(String(localized: "\(segment.spanCount) 条记录 · 切换 \(segment.switches) 次"))
        }
        return lines
    }
}

/// A daily limit as captioned under its category, in whole minutes as shown.
enum LimitStatus: Equatable {
    case over(minutes: Int)
    /// Within `warningPercent` of the limit.
    case near(minutes: Int)
    /// Comfortably under; carries the limit itself.
    case within(minutes: Int)

    init(spent: TimeInterval, limit: TimeInterval, warningPercent: Int) {
        let left = Int(Format.minuteDelta(limit, spent) / 60)
        if left < 0 { self = .over(minutes: -left) }
        else if limit - spent <= limit * Double(warningPercent) / 100 { self = .near(minutes: left) }
        else { self = .within(minutes: Int(limit / 60)) }
    }

    var isOver: Bool { if case .over = self { true } else { false } }
}

struct RefinedRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RefinedRowButtonBody(configuration: configuration)
    }
    private struct RefinedRowButtonBody: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label.background(Color.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.05 : 0))
                .onHover { hovered = $0 }
        }
    }
}
