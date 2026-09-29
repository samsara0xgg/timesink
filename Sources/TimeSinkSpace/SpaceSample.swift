import AppKit
import SwiftUI

struct SpaceSnapshot: Identifiable, Sendable {
    let id: Int64
    let at: Date
    let lastSeenAt: Date
    let url: URL?
    var time: String { SpaceEvent.localDate(at, format: "HH:mm:ss") }
}

struct SpaceEvent: Identifiable, Sendable {
    let id: Int
    let start: Date
    let end: Date
    let app: String
    let bundleID: String
    let title: String
    let category: Category
    let snapshots: [SpaceSnapshot]

    // Window types, never inferred topics or productivity scores.
    enum Category: String, Sendable {
        case development = "开发", reading = "浏览", writing = "文档", conversation = "对话", other = "活动"
        var rgb: SIMD3<Float> {
            switch self {
            case .development: return [0.91, 0.56, 0.32]
            case .reading: return [0.46, 0.66, 0.69]
            case .writing: return [0.79, 0.70, 0.46]
            case .conversation: return [0.64, 0.60, 0.79]
            case .other: return [0.62, 0.65, 0.65]
            }
        }
        var color: Color { Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)) }
        var nsColor: NSColor { NSColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1) }
        var symbol: String {
            switch self {
            case .development: return "curlybraces"
            case .reading: return "globe"
            case .writing: return "doc.text"
            case .conversation: return "bubble.left.and.bubble.right"
            case .other: return "macwindow"
            }
        }
        static func infer(app: String, title: String) -> Self {
            let app = app.lowercased()
            if ["ghostty", "terminal", "xcode", "code", "iterm2"].contains(app) { return .development }
            if ["chatgpt", "claude", "wechat", "discord", "messages", "slack", "facetime"].contains(app) { return .conversation }
            if title.lowercased().hasSuffix(".docx") || ["pages", "notes", "备忘录", "word", "notion"].contains(app) { return .writing }
            if ["google chrome", "safari", "arc", "firefox"].contains(app) { return .reading }
            return .other
        }
    }
    var time: String { Self.clock(start) }
    var endTime: String { Self.clock(end) }
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var durationLabel: String {
        if duration < 1 { return "一个瞬间" }
        if duration < 60 { return "\(Int(duration)) 秒" }
        return "\(Int(duration / 60)) 分 \(Int(duration) % 60) 秒"
    }
    var availableSnapshots: [SpaceSnapshot] { snapshots.filter { $0.url != nil } }
    var cover: SpaceSnapshot? {
        let available = availableSnapshots
        return available.isEmpty ? nil : available[available.count / 2]
    }
    static func nearest(to date: Date, in events: [SpaceEvent]) -> SpaceEvent? {
        // At a shared boundary the new interval wins. In a gap, compare edges, not starts.
        if let containing = events.last(where: { $0.start <= date && date < $0.end }) {
            return containing
        }
        func distance(_ event: SpaceEvent) -> TimeInterval {
            min(abs(event.start.timeIntervalSince(date)), abs(event.end.timeIntervalSince(date)))
        }
        return events.min { distance($0) < distance($1) }
    }
    static func clock(_ date: Date) -> String {
        localDate(date, format: "HH:mm")
    }
    static func localDate(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

@MainActor
final class SpaceState: ObservableObject {
    static let zoomRange: ClosedRange<Float> = 0.5...1
    static let defaultZoom: Float = 0.8
    let library: SpaceLibrary
    var events: [SpaceEvent] { library.events }
    var position: Float
    @Published var isFocused = false
    @Published var isExpanded = false
    @Published var snapshotIndex = 0
    @Published private(set) var zoom = SpaceState.defaultZoom

    init() {
        let library = SpaceLibrary.loadToday()
        self.library = library
        let initial = library.events.filter {
            $0.category == .development && $0.title.localizedCaseInsensitiveContains("timesink") && $0.availableSnapshots.count > 2
        }.max { $0.duration < $1.duration }?.id ?? 0
        position = Float(initial)
        if library.events.indices.contains(initial) { snapshotIndex = library.events[initial].availableSnapshots.count / 2 }
    }
    var index: Int { min(max(0, events.count - 1), max(0, Int(position.rounded()))) }
    var selected: SpaceEvent? { events.indices.contains(index) ? events[index] : nil }
    var snapshots: [SpaceSnapshot] { selected?.availableSnapshots ?? [] }
    var snapshot: SpaceSnapshot? { snapshots.indices.contains(snapshotIndex) ? snapshots[snapshotIndex] : nil }

    static func clampedZoom(_ value: Float) -> Float {
        min(zoomRange.upperBound, max(zoomRange.lowerBound, value))
    }

    func setZoom(_ value: Float) {
        // The canvas keeps continuous gesture precision; publish only visible percentage changes.
        let next = Self.clampedZoom((value * 100).rounded() / 100)
        if next != zoom { zoom = next }
    }

    func travel(_ delta: Float) {
        guard !isExpanded else { return }
        let next = min(Float(max(0, events.count - 1)), max(0, position + delta))
        let changed = Int(next.rounded()) != index
        if changed { objectWillChange.send() }
        if isFocused { isFocused = false }
        position = next
        if changed { snapshotIndex = snapshots.count / 2 }
    }
    func select(_ next: Int, focus: Bool = false) {
        let previous = index
        let newPosition = Float(min(max(0, events.count - 1), max(0, next)))
        if newPosition != position { objectWillChange.send() }
        position = newPosition
        if isFocused != focus { isFocused = focus }
        if isExpanded { isExpanded = false }
        if previous != index { snapshotIndex = snapshots.count / 2 }
    }
    func pickSnapshot(_ index: Int) { snapshotIndex = min(max(0, snapshots.count - 1), max(0, index)) }
    func openOriginal() { if snapshot != nil { isExpanded = true } }
    func closeDetail() { if isExpanded { isExpanded = false } else { isFocused = false } }
}
