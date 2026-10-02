import SwiftUI

/// F2 打断雷达 (Trends): who interrupted you, when, and what to do about
/// it. Counts only interruptions by the rule the timeline draws; peeks show
/// under 所有切换.
struct InterruptionRadarCard: View {
    let model: AppModel
    @State private var period: Period
    @State private var mode = Mode.interruptions
    @State private var data: DayInterruptions?
    @State private var longest: DateInterval?
    @State private var runs: [BandRun] = []
    @State private var hoveredSource: String?
    /// The summary that sits beside the heatmap: radar, count, one line, and
    /// a button to the full card.
    private let onOpen: (() -> Void)?

    enum Period: Hashable { case today, week }

    init(model: AppModel, period: Period = .today, onOpen: (() -> Void)? = nil) {
        self.model = model
        self.onOpen = onOpen
        _period = State(initialValue: period)
        // The last result for this period and day, so the page's first frame
        // is laid out already; the load replaces it if a write came since.
        // No model reads here: an init runs inside the parent's body, so a
        // read would make the whole page redraw on every tracker write.
        if let last = Self.last, last.key.period == period, last.key.day == Calendar.current.startOfDay(for: Date()) {
            _data = State(initialValue: last.data)
            _longest = State(initialValue: last.longest)
            _runs = State(initialValue: last.runs)
        }
    }
    enum Mode: Hashable { case interruptions, all }

    private struct LoadKey: Equatable {
        let period: Period
        let version: Int
        let rule: InterruptionRule
        let day: Date

        @MainActor init(model: AppModel, period: Period) {
            self.period = period
            version = model.dataVersion
            rule = model.interruptionRule
            day = Calendar.current.startOfDay(for: Date())
        }
    }
    @MainActor private static var last: (key: LoadKey, data: DayInterruptions, longest: DateInterval?, runs: [BandRun])?
    /// The card is built in its own pass after the page (80 ms later, so the
    /// two never share a frame): Trends then opens at its pre-radar cost,
    /// and an empty panel of the card's last height holds its place.
    @State private var built = false
    @MainActor private static var lastHeights: [Bool: CGFloat] = [:]
    private var lastHeight: CGFloat {
        get { Self.lastHeights[onOpen != nil] ?? 320 }
        nonmutating set { Self.lastHeights[onOpen != nil] = newValue }
    }

    var body: some View {
        if built {
            Group { if onOpen != nil { summary } else { card } }.background(GeometryReader { geometry in
                Color.clear.onAppear { lastHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in lastHeight = height }
            })
        } else {
            Color.clear.frame(height: lastHeight).frame(maxWidth: .infinity)
                .designCard()
                .task { try? await Task.sleep(for: .milliseconds(80)); built = true }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("打断雷达").font(.body.weight(.semibold))
                Text("悬停一行，只看它").font(.body).foregroundStyle(Design.ink2)
                Spacer()
                Picker("显示", selection: $mode) {
                    Text("只看打断").tag(Mode.interruptions)
                    Text("所有切换").tag(Mode.all)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("时段", selection: $period) {
                    Text("今天").tag(Period.today)
                    Text("近 7 天").tag(Period.week)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if let data {
                content(data)
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary).frame(height: 220)
            }
        }
        .padding(18)
        .designCard()
        .pageTask(id: LoadKey(model: model, period: period)) { await load() }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("打断").font(.body.weight(.semibold))
            (Text(data?.interruptions.count ?? 0, format: .number).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                + Text(" 次").font(.body).foregroundStyle(Design.ink2))
            Group {
                if let data {
                    InterruptionRadar(data: data, sources: Array(data.sources.prefix(4)), showsPeeks: false, highlighted: nil)
                } else {
                    Circle().fill(.quaternary)
                }
            }
            .frame(width: 180, height: 180).frame(maxWidth: .infinity).padding(.vertical, 6)
            Group {
                if let top = data?.sources.first {
                    Text("停留 \(Int(model.interruptionRule.dwell)) 秒以上或打了字才算。最多的是\(top.label)，\(top.count) 次。")
                } else {
                    Text("今天还没有被打断。")
                }
                if let longest {
                    Text("最长没被打断：\(model.time(longest.start))–\(model.time(longest.end))")
                }
            }
            .font(.body).foregroundStyle(Design.ink2).fixedSize(horizontal: false, vertical: true)
            Button { onOpen?() } label: { HStack(spacing: 4) { Text("打开打断雷达"); Image(systemName: "chevron.right").imageScale(.small) } }
                .controlSize(.small).glassButton().fixedSize().padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .designCard()
        .pageTask(id: LoadKey(model: model, period: period)) { await load() }
    }

    @ViewBuilder private func content(_ data: DayInterruptions) -> some View {
        let sources = data.sources
        columns(data, sources)
        if period == .today, !runs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("时间带").font(.note.weight(.semibold))
                    Text(mode == .all ? "所有切换，路过的不画" : "只画打断和拦下").font(.note).foregroundStyle(Design.ink2)
                }
                TimeBand(runs: runs, data: data, sources: sources, showsPeeks: mode == .all, highlighted: hoveredSource,
                         color: { RefinedStyle.category($0, hex: model.resolver.categoriesByID[$0]?.colorHex ?? "#C7C7CC") },
                         hourLabel: { model.time($0) })
            }
        }
    }

    private func columns(_ data: DayInterruptions, _ sources: [DayInterruptions.Source]) -> some View {
        HStack(alignment: .top, spacing: 20) {
            InterruptionRadar(data: data, sources: Array(sources.prefix(4)), showsPeeks: mode == .all, highlighted: hoveredSource)
                .frame(width: 250, height: 250)
            VStack(alignment: .leading, spacing: 12) {
                stats(data)
                if sources.isEmpty {
                    Text(period == .today ? "今天还没有被打断。" : "这 7 天没有被打断。")
                        .font(.body).foregroundStyle(Design.ink2).padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(sources.prefix(6)) { source in
                            row(source)
                                .onHover { hoveredSource = $0 ? source.id : (hoveredSource == source.id ? nil : hoveredSource) }
                            if source.id != sources.prefix(6).last?.id { Divider() }
                        }
                    }
                }
                Label {
                    Text("切到聊天、社交、娱乐这类窗口，停留 \(Int(model.interruptionRule.dwell)) 秒以上或在那里打了字才算打断；看一眼就回来的不算，不到 3 秒的路过不画。")
                } icon: { Image(systemName: "info.circle") }
                    .font(.note).foregroundStyle(Design.ink2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stats(_ data: DayInterruptions) -> some View {
        let interruptions = data.interruptions
        let typed = interruptions.filter { $0.reason == .typed }.count
        return HStack(spacing: 0) {
            cell(String(localized: "打断"), "\(interruptions.count)",
                 String(localized: "回消息 \(typed) · 停留 \(interruptions.count - typed)"))
            Divider().frame(height: 44)
            cell(String(localized: "看一眼就回来"), "\(data.peeks.count)",
                 mode == .all ? String(localized: "另有 \(data.passes) 次路过") : String(localized: "不算打断"))
            Divider().frame(height: 44)
            if period == .today {
                cell(String(localized: "最长没被打断"), longest.map { Format.duration($0.duration) } ?? "—",
                     longest.map { "\(model.time($0.start))–\(model.time($0.end))" } ?? "")
                Divider().frame(height: 44)
            }
            cell(String(localized: "专注中拦下"), "\(data.blocked.count)", String(localized: "不算离开"))
        }
    }

    private func cell(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.body).foregroundStyle(Design.ink2).lineLimit(1)
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().lineLimit(1)
            Text(detail).font(.note).foregroundStyle(Design.ink2).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ source: DayInterruptions.Source) -> some View {
        let hours = Dictionary(grouping: source.starts) { Calendar.current.component(.hour, from: $0) }.mapValues(\.count)
        return HStack(spacing: 10) {
            ActivityIcon(bundleID: source.bundleID, domain: source.domain, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(source.label).fontWeight(.semibold).lineLimit(1)
                    Text("打断 \(source.count) 次").foregroundStyle(Design.ink2)
                    if source.peeks > 0 { Text("· 另有 \(source.peeks) 次看一眼").foregroundStyle(Design.ink2) }
                }.font(.body)
                Text(how(source)).font(.body).foregroundStyle(Design.ink2).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 3) {
                // One canvas, not a dozen shapes per row.
                Canvas { context, _ in
                    for hour in 8..<20 {
                        let height = hours[hour].map { CGFloat(4 + min($0, 4) * 3) } ?? 2
                        context.fill(Path(roundedRect: CGRect(x: CGFloat(hour - 8) * 6, y: 16 - height, width: 4, height: height), cornerRadius: 1),
                                     with: .color(hours[hour] == nil ? Color.primary.opacity(0.12) : Color.red.opacity(0.8)))
                    }
                }.frame(width: 70, height: 16)
                Text(peak(hours)).font(.note).foregroundStyle(Design.ink2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(peak(hours))
            action(source).frame(width: 140, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .opacity(hoveredSource == nil || hoveredSource == source.id ? 1 : 0.45)
        .contentShape(Rectangle())
    }

    private func how(_ source: DayInterruptions.Source) -> String {
        if source.typed == source.count { return source.count > 1 ? String(localized: "每次都回了消息") : String(localized: "回了消息") }
        if source.typed > 0 { return String(localized: "回消息 \(source.typed) 次，停留 \(source.count - source.typed) 次") }
        return String(localized: "都在看，共 \(Format.duration(source.seconds))")
    }

    private func peak(_ hours: [Int: Int]) -> String {
        guard let top = hours.values.max() else { return "" }
        let peaks = hours.filter { $0.value == top }.keys.sorted()
        return peaks.count > 2 ? String(localized: "全天都有")
            : String(localized: "多在 \(peaks.map(String.init).joined(separator: String(localized: "、"))) 点")
    }

    /// What TimeSink can already do about a source: hide the app during
    /// focus, or put a limit on the site's category.
    @ViewBuilder private func action(_ source: DayInterruptions.Source) -> some View {
        if source.count < 2 {
            Text("只有 1 次，不给建议").font(.note).foregroundStyle(Design.ink2)
        } else if source.domain == nil {
            let hidden = model.settings.focusBlockedApps.contains(source.bundleID)
            Button {
                var apps = Set(model.settings.focusBlockedApps)
                if hidden { apps.remove(source.bundleID) } else { apps.insert(source.bundleID) }
                model.settings.setFocusBlockedApps(apps.sorted())
                model.settingsChanged()
            } label: {
                Label("专注时隐藏", systemImage: hidden ? "checkmark" : "eye.slash")
            }
            .controlSize(.small).buttonStyle(.borderless)
        } else {
            Button { model.sidebarSelection = .focus } label: { Label("设限额…", systemImage: "gauge.with.dots.needle.33percent") }
                .controlSize(.small).buttonStyle(.borderless)
        }
    }

    private func load() async {
        let key = LoadKey(model: model, period: period)
        if let last = Self.last, last.key == key {
            if data != last.data { data = last.data; longest = last.longest; runs = last.runs }
            return
        }
        let calendar = Calendar.current
        let today = calendar.dateInterval(of: .day, for: Date())!
        let days = period == .today ? [today] : (0..<7).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today.start).flatMap { calendar.dateInterval(of: .day, for: $0) }
        }
        var merged = DayInterruptions()
        for day in days {
            let value = await model.interruptions(for: day)
            merged.episodes += value.episodes
            merged.blocked += value.blocked
        }
        guard !Task.isCancelled else { return }
        if period == .today {
            // Stretches of continuous recording, split by away gaps, and the
            // same spans as category runs for the time band.
            var stretches: [DateInterval] = []
            var bandRuns: [BandRun] = []
            for item in model.rangedSpans(for: DateRangeSelection.today()).sorted(by: { $0.span.start < $1.span.start })
            where item.span.end > item.span.start {
                let joined = stretches.last.map { item.span.start.timeIntervalSince($0.end) <= InterruptionClassifier.awayGap } ?? false
                if joined, let last = stretches.last {
                    stretches[stretches.count - 1] = DateInterval(start: last.start, end: max(last.end, item.span.end))
                } else {
                    stretches.append(DateInterval(start: item.span.start, end: item.span.end))
                }
                if joined, let last = bandRuns.last, last.categoryID == item.categoryID {
                    bandRuns[bandRuns.count - 1].end = max(last.end, item.span.end)
                } else {
                    bandRuns.append(BandRun(start: item.span.start, end: item.span.end, categoryID: item.categoryID))
                }
            }
            longest = merged.longestUnbroken(activity: stretches)
            runs = bandRuns
        }
        data = merged
        Self.last = (key, merged, longest, runs)
    }
}

/// A 24-hour clock face: one ring per leading source, a dot for each
/// interruption at its time (filled when typed), hollow dots for focus
/// blocks, and the busiest hour shaded.
private struct InterruptionRadar: View {
    let data: DayInterruptions
    let sources: [DayInterruptions.Source]
    let showsPeeks: Bool
    let highlighted: String?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2 - 18
            func point(_ date: Date, _ radius: CGFloat) -> CGPoint {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                let angle = (Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60) / 24 * 2 * .pi - .pi / 2
                return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }
            let line = Color.primary.opacity(contrast == .increased ? 0.4 : 0.12)
            // The busiest hour.
            let byHour = data.byHour()
            if let top = byHour.max(), top > 0, let hour = byHour.firstIndex(of: top) {
                var wedge = Path()
                let a0 = Angle.radians(Double(hour) / 24 * 2 * .pi - .pi / 2), a1 = Angle.radians(Double(hour + 1) / 24 * 2 * .pi - .pi / 2)
                wedge.move(to: center)
                wedge.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
                wedge.closeSubpath()
                context.fill(wedge, with: .color(.red.opacity(0.08)))
            }
            for index in 0...max(1, sources.count) {
                let radius = outer * (0.35 + 0.65 * CGFloat(index) / CGFloat(max(1, sources.count)))
                context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                               with: .color(line), lineWidth: 0.5)
            }
            for hour in stride(from: 0, to: 24, by: 6) {
                let angle = Double(hour) / 24 * 2 * .pi - .pi / 2
                let label = context.resolve(Text(verbatim: "\(hour)").font(.note).foregroundStyle(Design.ink2))
                context.draw(label, at: CGPoint(x: center.x + (outer + 10) * cos(angle), y: center.y + (outer + 10) * sin(angle)))
            }
            // Blocked focus attempts sit on the innermost ring.
            let inner = outer * 0.25
            for date in data.blocked {
                let p = point(date, inner)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(.primary), lineWidth: 1.5)
            }
            if showsPeeks {
                for episode in data.peeks {
                    let p = point(episode.start, inner * 1.3)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(.secondary))
                }
            }
            for (index, source) in sources.enumerated() {
                let radius = outer * (0.35 + 0.65 * CGFloat(index + 1) / CGFloat(max(1, sources.count)))
                let dim = highlighted != nil && highlighted != source.id
                for episode in data.interruptions where episode.destination.hasPrefix(source.destination + "\u{1F}") || episode.destination == source.destination {
                    let p = point(episode.start, radius)
                    let dot = Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                    let red = Color.red.opacity(dim ? 0.2 : 1)
                    if episode.reason == .typed { context.fill(dot, with: .color(red)) }
                    else { context.stroke(dot, with: .color(red), lineWidth: 2) }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "打断雷达：\(data.interruptions.count) 次打断"))
    }
}

struct BandRun: Equatable {
    var start: Date
    var end: Date
    var categoryID: String
}

/// The day as one strip (F2 时间带): category runs, away time left empty,
/// interruptions as red ticks (a bar when longer than 5 minutes), focus
/// blocks hollow, and peeks grey under 所有切换. Hovering a source fades
/// every other tick.
private struct TimeBand: View {
    let runs: [BandRun]
    let data: DayInterruptions
    let sources: [DayInterruptions.Source]
    let showsPeeks: Bool
    let highlighted: String?
    let color: (String) -> Color
    let hourLabel: (Date) -> String

    private var span: DateInterval {
        let calendar = Calendar.current
        let first = runs.first?.start ?? .now, last = max(runs.last?.end ?? .now, .now)
        let from = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        let to = calendar.dateInterval(of: .hour, for: last)?.end ?? last
        return DateInterval(start: from, end: max(to, from.addingTimeInterval(3600)))
    }

    var body: some View {
        let span = span
        let hours = stride(from: span.start, through: span.end, by: 3600).map { $0 }
        let step = max(1, hours.count / 8)
        VStack(spacing: 3) {
            Canvas { context, size in
                func x(_ date: Date) -> CGFloat { CGFloat(date.timeIntervalSince(span.start) / span.duration) * size.width }
                let bar = CGRect(x: 0, y: 8, width: size.width, height: 12)
                context.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(.primary.opacity(0.05)))
                for run in runs {
                    let rect = CGRect(x: x(run.start), y: bar.minY, width: max(1, x(run.end) - x(run.start) - 0.5), height: bar.height)
                    context.fill(Path(rect), with: .color(color(run.categoryID).opacity(0.75)))
                }
                let sourceOf = { (episode: SwitchEpisode) in
                    sources.first { episode.destination.hasPrefix($0.destination + "\u{1F}") || episode.destination == $0.destination }?.id
                }
                if showsPeeks {
                    for episode in data.peeks {
                        let dim = highlighted != nil && sourceOf(episode) != highlighted
                        context.fill(Path(CGRect(x: x(episode.start) - 0.75, y: 2, width: 1.5, height: 24)),
                                     with: .color(.secondary.opacity(dim ? 0.2 : 0.7)))
                    }
                }
                for episode in data.interruptions {
                    let dim = highlighted != nil && sourceOf(episode) != highlighted
                    let width = episode.dwell > 300 ? max(2, x(episode.end) - x(episode.start)) : 2
                    context.fill(Path(roundedRect: CGRect(x: x(episode.start) - 1, y: 0, width: width, height: 28), cornerRadius: 1),
                                 with: .color(.red.opacity(dim ? 0.2 : 0.9)))
                }
                for date in data.blocked {
                    context.stroke(Path(ellipseIn: CGRect(x: x(date) - 3.5, y: 10.5, width: 7, height: 7)), with: .color(.primary), lineWidth: 1.5)
                }
                let now = x(.now)
                if now < size.width {
                    context.fill(Path(CGRect(x: now - 0.5, y: 0, width: 1, height: 28)), with: .color(.primary))
                }
            }
            .frame(height: 28)
            GeometryReader { geometry in
                ForEach(Array(hours.enumerated()).filter { $0.offset % step == 0 }, id: \.offset) { _, hour in
                    Text(hourLabel(hour)).font(.note).foregroundStyle(Design.ink2).fixedSize()
                        .position(x: min(max(16, CGFloat(hour.timeIntervalSince(span.start) / span.duration) * geometry.size.width), geometry.size.width - 16), y: 6)
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "时间带：\(data.interruptions.count) 次打断"))
    }
}
