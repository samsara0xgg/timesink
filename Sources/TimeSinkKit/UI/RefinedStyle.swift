import AppKit
import SwiftUI

/// Values transcribed from the approved Refined artifact, not a new theme.
enum RefinedStyle {
    static let popoverWidth: CGFloat = 340
    static let panelRadius: CGFloat = 12
    static let stateAnimation = Animation.spring(response: 0.36, dampingFraction: 0.78)
    static let numberAnimation = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28)
    static func motion(reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: 0.15) : stateAnimation
    }

    static func adaptive(_ light: String, _ dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(Color(hex: hex))
        })
    }
    static let work = adaptive("#F6F6F7", "#1B1B1D")
    static let panel = adaptive("#FFFFFF", "#252528")
    static let warning = adaptive("#C98300", "#F2AA2E")

    /// Shipped hex -> its light/dark pair, built once: this is called per
    /// block, row and chip on every render.
    private static let shipped: [String: (hex: String, color: Color)] = {
        let pairs: [String: (String, String)] = [
            "softwareDev": ("#2F6BE4", "#4D8DFF"), "learning": ("#2C9A55", "#3CC46E"),
            "writing": ("#0C8898", "#2BB8C8"), "business": ("#6B50D6", "#9580FF"),
            "utilities": ("#6C7581", "#8D96A3"), "communication": ("#E27F0C", "#FFA23A"),
            "news": ("#A043C4", "#C77AE8"), "shopping": ("#DB4F7B", "#FF7BA2"),
            "socialMedia": ("#DA4338", "#FF645A"), "entertainment": ("#C29406", "#F2C51C"),
            "misc": ("#978E82", "#A99F92"), "uncategorized": ("#B4B4BB", "#6A6A72")
        ]
        var result: [String: (hex: String, color: Color)] = [:]
        for category in Taxonomy.categories {
            if let pair = pairs[category.id] { result[category.id] = (category.colorHex, adaptive(pair.0, pair.1)) }
        }
        return result
    }()

    static func category(_ id: String, hex: String) -> Color {
        // Keep personal category colors; only remap the shipped palette.
        guard let shipped = shipped[id], shipped.hex.caseInsensitiveCompare(hex) == .orderedSame else { return Color(hex: hex) }
        return shipped.color
    }

    static func shippedHex(_ id: String) -> String? { shipped[id]?.hex }

    static func remaining(spent: TimeInterval, limit: TimeInterval) -> String {
        let remaining = limit - spent
        if spent == 0 { return String(localized: "0 / \(Int(limit / 60)) 分钟") }
        if remaining == 0 { return String(localized: "已到上限") }
        if remaining < 0 { return String(localized: "已超出 \(Int(ceil(-remaining / 60))) 分钟") }
        return String(localized: "还剩 \(Int(ceil(remaining / 60))) 分钟")
    }
}

/// Shared by live summary values and the isolated native motion recording.
struct RefinedNumberMotion: ViewModifier {
    let value: String
    var reducedOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reducedOverride ?? systemReduceMotion }
    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(reduceMotion ? .easeOut(duration: 0.15) : RefinedStyle.numberAnimation, value: value)
    }
}

extension View {
    func refinedNumberMotion(_ value: String) -> some View {
        modifier(RefinedNumberMotion(value: value))
    }
}

struct CategoryChip: View {
    let category: Category?
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(RefinedStyle.category(category?.id ?? "uncategorized", hex: category?.colorHex ?? "#C7C7CC"))
                .frame(width: 6, height: 6)
            Text(category?.name ?? String(localized: "未分类")).lineLimit(1)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct AppIcon: View {
    /// Launch Services lookups cost ~50 µs each and rows re-create their
    /// icons on every scroll; apps don't change names or icons while we run.
    @MainActor private static var names: [String: String] = [:]
    @MainActor private static var icons: [String: NSImage] = [:]

    @MainActor static func name(for bundleID: String) -> String {
        if let name = names[bundleID] { return name }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID.split(separator: ".").last.map(String.init) ?? String(localized: "应用")
        names[bundleID] = name
        return name
    }
    let bundleID: String
    var size: CGFloat = 22
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon = icon ?? Self.icons[bundleID] { Image(nsImage: icon).resizable().interpolation(.high) }
            else { Image(systemName: "app.fill").resizable().foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: bundleID) {
            guard Self.icons[bundleID] == nil,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            let loaded = NSWorkspace.shared.icon(forFile: url.path)
            Self.icons[bundleID] = loaded
            icon = loaded
        }
    }
}

/// A site's monogram, or the app's icon when there is no site. Every site
/// is visited in the same browser, so its icon alone can't tell rows apart.
struct ActivityIcon: View {
    let bundleID: String
    let domain: String?
    var size: CGFloat = 22

    static func monogram(for domain: String) -> String {
        let labels = domain.split(separator: ".")
        guard labels.count >= 2 else { return String(domain.prefix(1)).uppercased() }
        let generic: Set<Substring> = ["co", "com", "org", "net", "gov", "edu", "ac"]
        let name = labels.count >= 3 && generic.contains(labels[labels.count - 2]) ? labels[labels.count - 3] : labels[labels.count - 2]
        return String(name.prefix(1)).uppercased()
    }

    var body: some View {
        if let domain {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(.quaternary)
                .overlay(Text(Self.monogram(for: domain)).font(.system(size: size * 0.55, weight: .semibold, design: .rounded)).foregroundStyle(.secondary))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            AppIcon(bundleID: bundleID, size: size)
        }
    }
}

struct RecordingPauseMenu: View {
    let model: AppModel
    var body: some View {
        if model.trackingPaused {
            Button("继续记录", systemImage: "play.fill") { model.resumeTracking() }
                .buttonStyle(.borderless).font(.system(size: 11))
        } else {
            Menu {
                Text("暂停应用、网站、标题和屏幕采集")
                Button("暂停 15 分钟") { model.pauseTracking(minutes: 15) }
                Button("暂停 1 小时") { model.pauseTracking(minutes: 60) }
                Button("直到手动恢复") { model.pauseTracking(minutes: nil) }
            } label: { Label("暂停", systemImage: "pause") }
            .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
            .help("暂停所有记录；暂停期间不补记")
        }
    }
}

struct HatchFill: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for x in stride(from: -size.height, to: size.width, by: 5) {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(path, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
        }.clipped().accessibilityHidden(true)
    }
}
