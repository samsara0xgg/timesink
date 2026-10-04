import Foundation

/// The app or site that gained the most time against the previous period,
/// and the one that lost the most. Counted over every app, not just the
/// rows the list shows.
struct AppMovers: Sendable, Equatable {
    struct Mover: Sendable, Equatable {
        let name: String
        /// Signed, in whole minutes.
        let delta: TimeInterval
    }

    /// A change under this is not worth naming.
    static let minimum: TimeInterval = 5 * 60

    var riser: Mover?
    var faller: Mover?

    typealias Total = (key: String, label: String, seconds: TimeInterval)

    init(current: [Total] = [], previous: [Total] = []) {
        let before = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(current.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [(key: String, name: String, delta: TimeInterval)] = []
        for key in Set(before.keys).union(after.keys) {
            let delta = Format.minuteDelta(after[key]?.seconds ?? 0, before[key]?.seconds ?? 0)
            guard abs(delta) >= Self.minimum else { continue }
            changes.append((key, (after[key] ?? before[key]!).label, delta))
        }
        func pick(_ better: (Double, Double) -> Bool) -> Mover? {
            changes.min { $0.delta == $1.delta ? $0.key < $1.key : better($0.delta, $1.delta) }
                .map { Mover(name: $0.name, delta: $0.delta) }
        }
        riser = pick { $0 > $1 }.flatMap { $0.delta > 0 ? $0 : nil }
        faller = pick { $0 < $1 }.flatMap { $0.delta < 0 ? $0 : nil }
    }
}
