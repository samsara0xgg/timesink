import SwiftUI

/// The interruption radar as a 24-hour rose: noon straight up, a sector per
/// hour as long as that hour's interruptions, stacked by app. The middle
/// reads the day's total, or the hour under the pointer. Pointing at a
/// sector and clicking one are reported through the bindings; what they do
/// to the list beside it is the card's business.
struct InterruptionRoseView: View {
    let rose: InterruptionRose
    /// One colour per leading app, then the rest.
    let colors: [Color]
    /// Dots for each interruption (today): size is the stay, solid is a reply.
    var showsDots = false
    /// The small card: fewer words in the middle, thinner labels.
    var compact = false
    /// Today: where the clock stands.
    var now: Date?
    /// Changing it grows the sectors again.
    var replay: AnyHashable = 0
    /// An app (index into the colours) the list is pointing at: only its colour stays.
    var highlightedSource: Int?
    @Binding var hoveredHour: Int?
    @Binding var selectedHour: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false

    private struct Frame {
        let center: CGPoint
        let outer: CGFloat
        let inner: CGFloat
        let unit: CGFloat
    }

    private func frame(_ size: CGSize) -> Frame {
        let side = min(size.width, size.height)
        let outer = side / 2 - (compact ? 20 : 24)
        let inner = outer * 0.46
        return Frame(center: CGPoint(x: size.width / 2, y: size.height / 2), outer: outer, inner: inner,
                     unit: (outer - inner) / CGFloat(max(1, rose.scaleMax)))
    }

    /// An annular sector for `hour`, between two radii, with a hair of gap either side.
    private static func sector(_ hour: Int, from innerRadius: CGFloat, to outerRadius: CGFloat, center: CGPoint) -> Path {
        let gap = 0.006
        let a0 = InterruptionRose.theta(hour: Double(hour)) - .pi / 2 + gap
        let a1 = InterruptionRose.theta(hour: Double(hour + 1)) - .pi / 2 - gap
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
        path.closeSubpath()
        return path
    }

    private static func point(_ hour: Double, _ radius: CGFloat, _ center: CGPoint) -> CGPoint {
        let theta = InterruptionRose.theta(hour: hour)
        return CGPoint(x: center.x + radius * CGFloat(sin(theta)), y: center.y - radius * CGFloat(cos(theta)))
    }

    var body: some View {
        GeometryReader { proxy in
            let f = frame(proxy.size)
            ZStack {
                dial(f)
                roseLayer(f).scaleEffect(grown ? 1 : 0.001, anchor: .center).opacity(grown ? 1 : 0)
                pointer(f)
                middle(f)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let hour = InterruptionRose.hour(at: location, center: f.center, inner: f.inner, outer: f.outer)
                    if hour != hoveredHour { hoveredHour = hour }
                case .ended:
                    hoveredHour = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { tap in
                if let hour = InterruptionRose.hour(at: tap.location, center: f.center, inner: f.inner, outer: f.outer) {
                    selectedHour = selectedHour == hour ? nil : hour
                } else {
                    selectedHour = nil
                }
            })
        }
        .onAppear(perform: grow)
        .onChange(of: replay) { _, _ in grow() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "打断雷达：\(rose.total) 次打断"))
        .accessibilityChildren {
            ForEach(0..<24, id: \.self) { hour in
                Text("\(hour)–\(hour + 1) 点，\(rose.hourTotals[hour]) 次")
            }
        }
    }

    private func grow() {
        grown = false
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : Design.layout) { grown = true }
        }
    }

    // MARK: Layers

    /// Night, the scale rings and the clock's numbers: what the sectors sit on.
    private func dial(_ f: Frame) -> some View {
        Canvas { context, _ in
            for hour in 0..<24 where InterruptionRose.isNight(hour: hour) {
                context.fill(Self.sector(hour, from: f.inner, to: f.outer, center: f.center), with: .color(Design.track.opacity(0.55)))
            }
            let half = rose.scaleMax / 2
            for value in [0, half, rose.scaleMax] {
                let radius = f.inner + f.unit * CGFloat(value)
                context.stroke(Path(ellipseIn: CGRect(x: f.center.x - radius, y: f.center.y - radius, width: radius * 2, height: radius * 2)),
                               with: .color(Design.line), lineWidth: value == 0 ? 0.5 : 0.5)
                if value > 0 {
                    // The counts, along the bottom edge where the night is quiet.
                    let label = context.resolve(Text(verbatim: "\(value)").font(.system(size: 9).monospacedDigit()).foregroundStyle(Design.ink2))
                    context.draw(label, at: CGPoint(x: f.center.x + 3, y: f.center.y + radius - 5), anchor: .leading)
                }
            }
            for hour in stride(from: 0, to: 24, by: 3) {
                let tick = Self.point(Double(hour), f.outer + 4, f.center), edge = Self.point(Double(hour), f.outer, f.center)
                var line = Path()
                line.move(to: edge)
                line.addLine(to: tick)
                context.stroke(line, with: .color(Design.line), lineWidth: 0.5)
                let label = context.resolve(Text(verbatim: "\(hour)").font(.system(size: compact ? 9 : 10).monospacedDigit()).foregroundStyle(Design.ink2))
                context.draw(label, at: Self.point(Double(hour), f.outer + (compact ? 10 : 12), f.center))
            }
        }
        .allowsHitTesting(false)
    }

    private func roseLayer(_ f: Frame) -> some View {
        Canvas { context, _ in
            for hour in 0..<24 {
                var used = 0
                for source in 0...InterruptionRose.maxSources {
                    let count = rose.counts[hour][source]
                    guard count > 0 else { continue }
                    let from = f.inner + f.unit * CGFloat(used), to = from + f.unit * CGFloat(count)
                    used += count
                    let dim = highlightedSource != nil && highlightedSource != source
                    let opacity = dim ? 0.12 : showsDots ? 0.32 : 0.9
                    let path = Self.sector(hour, from: from, to: to, center: f.center)
                    context.fill(path, with: .color(colors[source].opacity(opacity)))
                    context.stroke(path, with: .color(Design.surface), lineWidth: 0.5)
                }
            }
            guard showsDots else { return }
            for dot in rose.dots {
                let dim = highlightedSource != nil && highlightedSource != dot.source
                let radius = f.inner + f.unit * (CGFloat(dot.slot) + 0.5)
                let center = Self.point(Double(dot.hour) + 0.12 + 0.76 * dot.fraction, radius, f.center)
                let size = min(f.unit * 0.46, 2.2 + 3.8 * CGFloat(min(1, (dot.dwell / 300).squareRoot())))
                let shape = Path(ellipseIn: CGRect(x: center.x - size, y: center.y - size, width: size * 2, height: size * 2))
                let color = colors[dot.source].opacity(dim ? 0.2 : 1)
                if dot.typed { context.fill(shape, with: .color(color)) }
                else { context.stroke(shape, with: .color(color), lineWidth: 1.4) }
            }
        }
        .allowsHitTesting(false)
    }

    /// The hour under the pointer, the chosen hour, and now.
    private func pointer(_ f: Frame) -> some View {
        Canvas { context, _ in
            if let hour = hoveredHour, hour != selectedHour {
                context.fill(Self.sector(hour, from: f.inner, to: f.outer, center: f.center), with: .color(Design.ink.opacity(0.06)))
            }
            if let hour = selectedHour {
                let path = Self.sector(hour, from: f.inner, to: f.outer, center: f.center)
                context.fill(path, with: .color(Design.ink.opacity(0.06)))
                context.stroke(path, with: .color(Design.ink), lineWidth: 1.5)
            }
            if let now {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
                let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
                var line = Path()
                line.move(to: Self.point(hour, f.inner, f.center))
                line.addLine(to: Self.point(hour, f.outer + 2, f.center))
                context.stroke(line, with: .color(Design.ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                let tip = Self.point(hour, f.outer + 2, f.center)
                context.fill(Path(ellipseIn: CGRect(x: tip.x - 3, y: tip.y - 3, width: 6, height: 6)), with: .color(Design.ink))
            }
        }
        .allowsHitTesting(false)
    }

    /// The day's total, or the hour being pointed at.
    private func middle(_ f: Frame) -> some View {
        let hour = hoveredHour ?? selectedHour
        return VStack(spacing: 2) {
            if let hour {
                Text("\(hour)–\(hour + 1) 点").font(.note).foregroundStyle(Design.ink2).monospacedDigit()
                Text("\(rose.hourTotals[hour]) 次").font(.figure).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                if !compact, let top = rose.top(inHour: hour) {
                    Text("\(top.label) \(top.count) 次").font(.note).foregroundStyle(Design.ink2).lineLimit(1).minimumScaleFactor(0.7)
                }
            } else {
                Text(rose.total, format: .number).font(compact ? .display : .system(size: 30, weight: .semibold)).monospacedDigit()
                Text("打断").font(.note).foregroundStyle(Design.ink2)
            }
        }
        .frame(width: f.inner * 1.9)
        .position(f.center)
        .allowsHitTesting(false)
    }
}
