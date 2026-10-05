import SwiftUI

/// F2 打断雷达 (Trends): who interrupted you, when, and what to do about
/// it. A rose of the 24 hours stacked by app, the apps as a table beside it,
/// and (today) the day as a strip of just the interruptions. Counts only
/// interruptions by the rule the timeline draws; a glance back is counted
/// apart, never as an interruption.
struct InterruptionRadarCard: View {
    let model: AppModel
    @State private var period: Period
    @State private var loaded: Loaded?
    @State private var hoveredHour: Int?
    @State private var selectedHour: Int?
    @State private var hoveredSource: String?
    /// The summary that sits beside the heatmap: rose, count, one line, and
    /// a button to the full card.
    private let onOpen: (() -> Void)?

    enum Period: Hashable, CaseIterable { case today, week }

    /// Amber in steps for the leading apps (darkest first), grey for the rest.
    private static let palette: [Color] = ColorSystem.radar

    private struct Loaded: Equatable {
        var data: DayInterruptions
        var longest: DateInterval?
        var runs: [BandRun]
        var rose: InterruptionRose
    }

    init(model: AppModel, period: Period = .today, onOpen: (() -> Void)? = nil) {
        self.model = model
        self.onOpen = onOpen
        _period = State(initialValue: period)
        #if DEBUG
        _hoveredHour = State(initialValue: Self.previewState.hovered)
        _selectedHour = State(initialValue: Self.previewState.selected)
        _hoveredSource = State(initialValue: Self.previewState.source)
        #endif
        // The last result for this period and day, so the page's first frame
        // is laid out already; the load replaces it if a write came since.
        // No model reads here: an init runs inside the parent's body, so a
        // read would make the whole page redraw on every tracker write.
        if let last = Self.last, last.key.period == period, last.key.day == Calendar.current.startOfDay(for: Date()) {
            _loaded = State(initialValue: last.loaded)
        }
    }

    #if DEBUG
    /// What the review captures point at: an hour, a chosen hour, an app.
    @MainActor static var previewState: (hovered: Int?, selected: Int?, source: String?) = (nil, nil, nil)
    #endif

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
    @MainActor private static var last: (key: LoadKey, loaded: Loaded)?
    /// The card is built in its own pass after the page (80 ms later, so the
    /// two never share a frame): Trends then opens at its pre-radar cost,
    /// and an empty panel of the card's last height holds its place.
    @State private var built = false
    @MainActor private static var lastHeights: [Bool: CGFloat] = [:]
    private var lastHeight: CGFloat {
        get { Self.lastHeights[onOpen != nil] ?? 320 }
        nonmutating set { Self.lastHeights[onOpen != nil] = newValue }
    }

    private static let numberWidth: CGFloat = 64
    private static let repliedWidth: CGFloat = 88
    private static let actionWidth: CGFloat = 140

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

    private var isToday: Bool { period == .today }
    /// The hour the pointer is on, else the one chosen.
    private var activeHour: Int? { hoveredHour ?? selectedHour }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("打断雷达").font(.body.weight(.semibold))
                Text("悬停或点一个小时，只看那一小时").font(.body).foregroundStyle(Design.ink2)
                Spacer()
                Segmented(options: Period.allCases, selection: $period, height: 24) { option in
                    option == .today ? Text("今天") : Text("近 7 天")
                }
                .accessibilityLabel("时段")
            }
            if let loaded {
                content(loaded)
            } else {
                RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.track).frame(height: 240)
            }
        }
        .padding(Design.Space.card)
        .designCard()
        .pageTask(id: LoadKey(model: model, period: period)) { await load() }
        .onChange(of: period) { _, _ in selectedHour = nil; hoveredHour = nil; hoveredSource = nil }
    }

    @ViewBuilder private func content(_ loaded: Loaded) -> some View {
        let data = loaded.data
        let shown = selectedHour.map { data.restricted(toHour: $0) } ?? data
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 8) {
                InterruptionRoseView(rose: loaded.rose, colors: Self.palette, showsDots: isToday,
                                     now: isToday ? Date() : nil, replay: period,
                                     highlightedSource: hoveredSource.map { loaded.rose.sourceIndex(of: $0) },
                                     hoveredHour: $hoveredHour, selectedHour: $selectedHour)
                    .frame(width: 264, height: 264)
                if isToday { dotKey }
            }
            VStack(alignment: .leading, spacing: 16) {
                stats(data, longest: loaded.longest)
                table(loaded, shown)
            }
        }
        if isToday, !loaded.runs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("时间带").font(.note.weight(.semibold))
                    Text("只画打断和拦下").font(.note).foregroundStyle(Design.ink2)
                }
                TimeBand(runs: loaded.runs, data: data, rose: loaded.rose, colors: Self.palette, hour: activeHour,
                         highlighted: hoveredSource, hourLabel: { model.time($0) })
            }
        }
        Label {
            Text("切到聊天、社交、娱乐这类窗口，停留 \(Int(model.interruptionRule.dwell)) 秒以上或在那里打了字才算打断；看一眼就回来的不算，不到 3 秒的路过不画。")
        } icon: { Image(systemName: "info.circle") }
            .font(.note).foregroundStyle(Design.ink2).fixedSize(horizontal: false, vertical: true)
    }

    private var dotKey: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) { Circle().fill(Design.ink2).frame(width: 7, height: 7); Text("回了消息") }
            HStack(spacing: 4) { Circle().stroke(Design.ink2, lineWidth: 1.2).frame(width: 7, height: 7); Text("只是停留") }
            Text("点越大，停留越久")
        }
        .font(.note).foregroundStyle(Design.ink2).lineLimit(1).fixedSize()
    }

    // MARK: The four numbers

    private func stats(_ data: DayInterruptions, longest: DateInterval?) -> some View {
        HStack(spacing: 0) {
            cell(String(localized: "打断"), "\(data.interruptions.count)", help: String(localized: "停留够久或打了字的切换"))
            Divider().frame(height: 36)
            cell(String(localized: "瞄一眼"), "\(data.peeks.count)", help: String(localized: "看一眼就回来的切换，不算打断"))
            Divider().frame(height: 36)
            if isToday {
                cell(String(localized: "最长连续"), longest.map { Format.duration($0.duration) } ?? "—",
                     help: longest.map { String(localized: "最长一段没被打断的时间：\(model.time($0.start))–\(model.time($0.end))") }
                        ?? String(localized: "最长一段没被打断的时间"))
                Divider().frame(height: 36)
            }
            cell(String(localized: "拦下"), "\(data.blocked.count)", help: String(localized: "专注时被拦下的切换，不算离开"))
        }
    }

    private func cell(_ title: String, _ value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body).foregroundStyle(Design.ink2).lineLimit(1)
            Text(value).font(.figure).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(help)
    }

    // MARK: The apps

    private func table(_ loaded: Loaded, _ shown: DayInterruptions) -> some View {
        let sources = Array(shown.sources.prefix(6))
        return VStack(alignment: .leading, spacing: 0) {
            if let hour = selectedHour {
                HStack(spacing: 8) {
                    Text("\(hour)–\(hour + 1) 点").font(.body.weight(.semibold))
                    Button("取消") { selectedHour = nil }.buttonStyle(PillButtonStyle(height: 24))
                }.padding(.bottom, 8)
            }
            if sources.isEmpty {
                Text(selectedHour != nil ? "这一小时没有被打断。" : isToday ? "今天还没有被打断。" : "这 7 天没有被打断。")
                    .font(.body).foregroundStyle(Design.ink2).padding(.vertical, 8)
            } else {
                header
                Divider()
                ForEach(sources) { source in
                    row(source, loaded.rose)
                        .onHover { hoveredSource = $0 ? source.id : (hoveredSource == source.id ? nil : hoveredSource) }
                    if source.id != sources.last?.id { Divider() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("应用").frame(maxWidth: .infinity, alignment: .leading)
            Text("次数").frame(width: Self.numberWidth, alignment: .trailing)
            Text("瞄一眼").frame(width: Self.numberWidth, alignment: .trailing)
            Text("回复 / 停留").multilineTextAlignment(.trailing).frame(width: Self.repliedWidth, alignment: .trailing)
            Color.clear.frame(width: Self.actionWidth, height: 1)
        }
        .font(.note).foregroundStyle(Design.ink2).fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 6)
    }

    private func row(_ source: DayInterruptions.Source, _ rose: InterruptionRose) -> some View {
        let index = rose.sourceIndex(of: source.id)
        // Pointing at an hour keeps the apps that have something in it.
        let dim: Bool = {
            if let hour = activeHour, selectedHour == nil { return rose.counts[hour][index] == 0 }
            return false
        }()
        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Self.palette[index]).frame(width: 8, height: 8)
                ActivityIcon(bundleID: source.bundleID, domain: source.domain, size: 20)
                Text(source.label).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text("\(source.count)").monospacedDigit().frame(width: Self.numberWidth, alignment: .trailing)
            Text("\(source.peeks)").monospacedDigit().foregroundStyle(Design.ink2).frame(width: Self.numberWidth, alignment: .trailing)
            Text("\(source.typed) / \(source.count - source.typed)").monospacedDigit().foregroundStyle(Design.ink2)
                .frame(width: Self.repliedWidth, alignment: .trailing)
            action(source).frame(width: Self.actionWidth, alignment: .trailing)
        }
        .font(.body)
        .padding(.vertical, 8)
        .opacity(dim ? 0.35 : 1)
        .contentShape(Rectangle())
        .animation(Design.quick, value: dim)
    }

    /// What TimeSink can already do about a source: hide the app during
    /// focus, or put a limit on the site's category.
    @ViewBuilder private func action(_ source: DayInterruptions.Source) -> some View {
        if source.count < 2 {
            Text("只有 1 次，不给建议").font(.note).foregroundStyle(Design.ink2).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
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
            .controlSize(.small).buttonStyle(.borderless).fixedSize()
        } else {
            Button { model.sidebarSelection = .focus } label: { Label("设限额…", systemImage: "gauge.with.dots.needle.33percent") }
                .controlSize(.small).buttonStyle(.borderless).fixedSize()
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("打断").font(.body.weight(.semibold))
            Group {
                if let loaded {
                    InterruptionRoseView(rose: loaded.rose, colors: Self.palette, showsDots: false, compact: true,
                                         now: Date(), replay: period, highlightedSource: nil,
                                         hoveredHour: $hoveredHour, selectedHour: .constant(nil))
                } else {
                    Circle().fill(Design.track)
                }
            }
            .frame(width: 200, height: 200).frame(maxWidth: .infinity).padding(.vertical, 2)
            Group {
                if let top = loaded?.data.sources.first {
                    Text("停留 \(Int(model.interruptionRule.dwell)) 秒以上或打了字才算。最多的是\(top.label)，\(top.count) 次。")
                } else {
                    Text("今天还没有被打断。")
                }
                if let longest = loaded?.longest {
                    Text("最长没被打断：\(model.time(longest.start))–\(model.time(longest.end))")
                }
            }
            .font(.body).foregroundStyle(Design.ink2).fixedSize(horizontal: false, vertical: true)
            Button { onOpen?() } label: { HStack(spacing: 4) { Text("打开打断雷达"); Image(systemName: "chevron.right").imageScale(.small) } }
                .buttonStyle(PillButtonStyle(height: 24)).fixedSize().padding(.top, 4)
        }
        .padding(Design.Space.card)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .designCard()
        .pageTask(id: LoadKey(model: model, period: period)) { await load() }
    }

    // MARK: Loading

    private func load() async {
        let key = LoadKey(model: model, period: period)
        if let last = Self.last, last.key == key {
            if loaded != last.loaded { loaded = last.loaded }
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
        var longest: DateInterval?
        var bandRuns: [BandRun] = []
        if period == .today {
            // Stretches of continuous recording, split by away gaps, and the
            // same spans as category runs, which only give the band its extent.
            var stretches: [DateInterval] = []
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
        }
        let result = Loaded(data: merged, longest: longest, runs: bandRuns, rose: InterruptionRose(data: merged))
        loaded = result
        Self.last = (key, result)
    }
}

struct BandRun: Equatable {
    var start: Date
    var end: Date
    var categoryID: String
}

/// The day as one strip (F2 时间带): a light baseline for the recorded day,
/// with only the distractions on it, each in its app's colour (a bar when
/// longer than 5 minutes), focus blocks hollow. Pointing at an app or an
/// hour fades every other tick.
private struct TimeBand: View {
    let runs: [BandRun]
    let data: DayInterruptions
    let rose: InterruptionRose
    let colors: [Color]
    let hour: Int?
    let highlighted: String?
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
                let calendar = Calendar.current
                let bar = CGRect(x: 0, y: 10, width: size.width, height: 8)
                context.fill(Path(roundedRect: bar, cornerRadius: 3), with: .color(Design.track.opacity(0.6)))
                for run in runs {
                    let rect = CGRect(x: x(run.start), y: bar.minY, width: max(1, x(run.end) - x(run.start) - 0.5), height: bar.height)
                    context.fill(Path(rect), with: .color(Design.line.opacity(0.4)))
                }
                for episode in data.interruptions {
                    let index = rose.sourceIndex(of: episode.destination)
                    let dim = (highlighted != nil && rose.sourceIDs.indices.contains(index) ? rose.sourceIDs[index] != highlighted : highlighted != nil)
                        || (hour != nil && calendar.component(.hour, from: episode.start) != hour)
                    let width = episode.dwell > 300 ? max(3, x(episode.end) - x(episode.start)) : 3
                    context.fill(Path(roundedRect: CGRect(x: x(episode.start) - 1, y: 2, width: width, height: 24), cornerRadius: 1.5),
                                 with: .color(colors[index].opacity(dim ? 0.18 : 1)))
                }
                for date in data.blocked {
                    context.stroke(Path(ellipseIn: CGRect(x: x(date) - 3.5, y: 10.5, width: 7, height: 7)), with: .color(Design.ink), lineWidth: 1.5)
                }
                let now = x(.now)
                if now < size.width {
                    context.fill(Path(CGRect(x: now - 0.5, y: 0, width: 1, height: 28)), with: .color(Design.ink))
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
