import Foundation
import CoreGraphics

/// The interruption radar's rose: one sector per hour, as long as the
/// interruptions that began in it, stacked by app. Pure, so the counts, the
/// dots and the hit test can be checked without a window.
public struct InterruptionRose: Equatable, Sendable {
    /// One interruption, placed in its hour.
    public struct Dot: Equatable, Sendable {
        public var hour: Int
        /// How far into the hour it began, 0...1.
        public var fraction: Double
        /// Which stacked unit of the sector it sits in, from the centre out.
        public var slot: Int
        /// Index into `sourceIDs`, or `InterruptionRose.maxSources` for the rest.
        public var source: Int
        public var dwell: TimeInterval
        public var typed: Bool
    }

    /// Apps that get a colour of their own; the rest share one.
    public static let maxSources = 5

    /// The leading apps by interruptions, most first.
    public var sourceIDs: [String]
    public var labels: [String]
    /// Interruptions by hour, then by source (the last column is "the rest").
    public var counts: [[Int]]
    public var dots: [Dot]
    public var total: Int

    public var hourTotals: [Int] { counts.map { $0.reduce(0, +) } }
    public var busiest: Int { hourTotals.max() ?? 0 }
    /// The scale's top: a round number at or above the busiest hour.
    public var scaleMax: Int { Self.niceMax(busiest) }

    public init(data: DayInterruptions, calendar: Calendar = .current) {
        let sources = data.sources
        let leading = sources.prefix(Self.maxSources)
        sourceIDs = leading.map(\.id)
        labels = leading.map(\.label)
        var counts = Array(repeating: Array(repeating: 0, count: Self.maxSources + 1), count: 24)
        var dots: [Dot] = []
        func row(_ destination: String) -> String { String(destination.split(separator: "\u{1F}", maxSplits: 1).first ?? "") }
        let index = Dictionary(uniqueKeysWithValues: sourceIDs.enumerated().map { ($1, $0) })
        let ordered = data.interruptions.sorted { $0.start < $1.start }
        for episode in ordered {
            let hour = calendar.component(.hour, from: episode.start)
            let source = index[row(episode.destination)] ?? Self.maxSources
            counts[hour][source] += 1
        }
        // A dot's slot: the units of the sources before it in this hour, then
        // its place among its own source's.
        var seen: [[Int]] = Array(repeating: Array(repeating: 0, count: Self.maxSources + 1), count: 24)
        for episode in ordered {
            let parts = calendar.dateComponents([.hour, .minute, .second], from: episode.start)
            let hour = parts.hour ?? 0
            let source = index[row(episode.destination)] ?? Self.maxSources
            let before = counts[hour][..<source].reduce(0, +)
            dots.append(Dot(hour: hour, fraction: (Double(parts.minute ?? 0) + Double(parts.second ?? 0) / 60) / 60,
                            slot: before + seen[hour][source], source: source, dwell: episode.dwell, typed: episode.reason == .typed))
            seen[hour][source] += 1
        }
        self.counts = counts
        self.dots = dots
        total = ordered.count
    }

    /// Which column an app's destination belongs to; the last is "the rest".
    public func sourceIndex(of destination: String) -> Int {
        let row = String(destination.split(separator: "\u{1F}", maxSplits: 1).first ?? "")
        return sourceIDs.firstIndex(of: row) ?? Self.maxSources
    }

    /// The leading app of an hour and its count.
    public func top(inHour hour: Int) -> (label: String, count: Int)? {
        guard counts.indices.contains(hour), let best = counts[hour].enumerated().max(by: { $0.element < $1.element }), best.element > 0 else { return nil }
        return (best.offset < labels.count ? labels[best.offset] : "", best.element)
    }

    /// Round numbers for the scale rings: the half is whole as well.
    public static func niceMax(_ value: Int) -> Int {
        let steps = [2, 4, 6, 8, 10, 12, 16, 20, 24, 30, 40, 50, 60, 80, 100, 120, 160, 200, 300, 400, 500, 1000]
        return steps.first { $0 >= value } ?? ((value + 99) / 100) * 100
    }

    // MARK: Geometry

    /// Noon is straight up and the hours run clockwise, so midnight is at the
    /// bottom. Radians clockwise from straight up, for the start of `hour`.
    public static func theta(hour: Double) -> Double { (hour - 12) / 24 * 2 * .pi }

    /// The hour the point is over, between the centre disc and the rim.
    /// `nil` over the centre or outside the rim.
    public static func hour(at point: CGPoint, center: CGPoint, inner: CGFloat, outer: CGFloat) -> Int? {
        let dx = point.x - center.x, dy = point.y - center.y
        let radius = (dx * dx + dy * dy).squareRoot()
        guard radius >= inner, radius <= outer else { return nil }
        let theta = atan2(Double(dx), Double(-dy))
        var hour = Int(((theta / (2 * .pi)) * 24 + 12).rounded(.down)) % 24
        if hour < 0 { hour += 24 }
        return hour
    }

    /// Night is drawn as a faint grey behind the sectors.
    public static func isNight(hour: Int) -> Bool { hour < 6 || hour >= 22 }
}

extension DayInterruptions {
    /// Only what began in `hour` (every episode kind, and the blocked tries).
    public func restricted(toHour hour: Int, calendar: Calendar = .current) -> DayInterruptions {
        DayInterruptions(episodes: episodes.filter { calendar.component(.hour, from: $0.start) == hour },
                         blocked: blocked.filter { calendar.component(.hour, from: $0) == hour })
    }
}
