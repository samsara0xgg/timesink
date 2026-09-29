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

    static func category(_ id: String, hex: String) -> Color {
        let colors: [String: (String, String)] = [
            "softwareDev": ("#2F6BE4", "#4D8DFF"), "learning": ("#2C9A55", "#3CC46E"),
            "writing": ("#0C8898", "#2BB8C8"), "business": ("#6B50D6", "#9580FF"),
            "utilities": ("#6C7581", "#8D96A3"), "communication": ("#E27F0C", "#FFA23A"),
            "news": ("#A043C4", "#C77AE8"), "shopping": ("#DB4F7B", "#FF7BA2"),
            "socialMedia": ("#DA4338", "#FF645A"), "entertainment": ("#C29406", "#F2C51C"),
            "misc": ("#978E82", "#A99F92"), "uncategorized": ("#B4B4BB", "#6A6A72")
        ]
        // Keep personal category colors; only remap the shipped palette.
        guard let original = Taxonomy.categories.first(where: { $0.id == id }),
              original.colorHex.caseInsensitiveCompare(hex) == .orderedSame,
              let pair = colors[id] else { return Color(hex: hex) }
        return adaptive(pair.0, pair.1)
    }

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
    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID.split(separator: ".").last.map(String.init) ?? String(localized: "应用") }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    let bundleID: String
    var size: CGFloat = 22
    @State private var icon: NSImage?
    var body: some View {
        Group {
            if let icon { Image(nsImage: icon).resizable().interpolation(.high) }
            else { Image(systemName: "app.fill").resizable().foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: bundleID) {
            icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
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
