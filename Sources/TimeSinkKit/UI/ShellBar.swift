import AppKit
import SwiftUI

// The main window's top bar, level with the title bar: the five pages in a
// flat row at the centre, search and the recording state on the right, a
// hairline underneath. It is the same on every page; what belongs to one
// page (a day, a range, a filter) sits in that page's header instead.

// MARK: - What pages put in the bar

struct ShellSearch {
    var text: Binding<String>
    var prompt: LocalizedStringKey
}

struct PageBarItems {
    var search: ShellSearch?
}

struct PageBarKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue = PageBarItems()
    static func reduce(value: inout PageBarItems, nextValue: () -> PageBarItems) {
        if let search = nextValue().search { value.search = search }
    }
}

// MARK: - Layout

/// Leading, centre and trailing: the centre sits in the middle of the bar,
/// and gives way only when a side would run into it.
private struct BarLayout: Layout {
    var gap: CGFloat = Design.Space.lg

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? Design.windowMinSize.width, height: proposal.height ?? Design.barHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let center = subviews[1].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .init(leading))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .init(trailing))
        let low = bounds.minX + leading.width + gap, high = bounds.maxX - trailing.width - gap - center.width
        let wanted = bounds.midX - center.width / 2
        let x = high >= low ? min(max(wanted, low), high) : low
        subviews[1].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: .init(center))
    }
}

// MARK: - The bar

struct ShellBar: View {
    let model: AppModel
    let items: PageBarItems
    /// Below 960 pt the recording state is a dot and the field narrows.
    @State private var compact = false

    var body: some View {
        BarLayout {
            // The traffic lights' room.
            Color.clear.frame(width: 72, height: 1)
            NavTabs(model: model)
            HStack(spacing: Design.Space.sm) {
                SearchField(model: model, provided: items.search, width: compact ? 150 : 190, compact: compact)
                RecordingStatus(model: model, compact: compact)
            }
        }
        .padding(.horizontal, Design.Space.lg)
        .frame(height: Design.barHeight)
        .background(Design.floor)
        .overlay(alignment: .bottom) { Rectangle().fill(Design.line).frame(height: 0.5) }
        .onGeometryChange(for: Bool.self) { $0.size.width < 960 } action: { compact = $0 }
        .background { WindowDragArea() }
        // The lights sit 14 pt above their container's bottom edge.
        .background { TrafficLightInset(height: Design.barHeight / 2 + 14) }
    }
}

// MARK: - Tabs

/// The five pages as flat segments. ⌘1 to ⌘5 live in the 导航 menu.
private struct NavTabs: View {
    let model: AppModel

    private var selection: SidebarItem { model.sidebarSelection }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarItem.allCases, id: \.self) { page in
                SegmentButton(selected: page == selection) { go(page) } label: {
                    HStack(spacing: 6) {
                        Text(title(page))
                        if page == .organization, model.pendingClassificationCount > 0 {
                            // A badge, not a word: on its own plate, never read as part of the name.
                            Text(verbatim: "\(model.pendingClassificationCount)").font(.note.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(Design.surface)
                                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 16)
                                .background(Design.ink2, in: Capsule())
                        }
                    }
                }
                .accessibilityLabel(page == .organization && model.pendingClassificationCount > 0
                                    ? Text("\(title(page))，\(model.pendingClassificationCount) 项待分类") : Text(title(page)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主导航")
    }

    private func title(_ page: SidebarItem) -> LocalizedStringKey {
        switch page {
        case .today: return "今天"
        case .activities: return "活动"
        case .stats: return "趋势"
        case .focus: return "专注"
        case .organization: return "分类"
        }
    }

    private func go(_ page: SidebarItem) {
        guard page != selection else { return }
        switch page {
        case .today: model.openToday()
        case .stats: model.openStats(range: DateRangeSelection(kind: .last7, anchor: Date()))
        default: model.sidebarSelection = page
        }
    }
}

// MARK: - Search

/// Always a field, always the same width. A page that can be searched
/// (活动, 分类) binds it; anywhere else, typing takes you to 活动.
private struct SearchField: View {
    let model: AppModel
    let provided: ShellSearch?
    let width: CGFloat
    /// Too narrow for the page's prompt: it says only 搜索, the rest on hover.
    let compact: Bool
    @FocusState private var focused: Bool

    private var text: Binding<String> {
        provided?.text ?? Binding(get: { "" }, set: { value in
            guard !value.isEmpty else { return }
            model.activitySearch = value
            model.openActivities(category: nil, range: .today())
        })
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Design.iconInk).accessibilityHidden(true)
            TextField(compact ? "搜索" : provided?.prompt ?? "搜索活动", text: text)
                .textFieldStyle(.plain).focused($focused)
                .help(Text(provided?.prompt ?? "搜索活动"))
                .onExitCommand { text.wrappedValue = ""; focused = false }
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Design.ink2)
                }.buttonStyle(.plain).accessibilityLabel("清除搜索")
            }
        }
        .font(.body)
        .padding(.horizontal, Design.Space.sm).frame(width: width, height: Design.controlHeight)
        .background(Design.hoverFill, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
        .background {
            // ⌘F from anywhere in the window.
            Button("搜索") { focused = true }.keyboardShortcut("f").hidden()
        }
    }
}

// MARK: - Recording

/// Is TimeSink recording? A dot and a word; a menu to pause it or open Settings.
private struct RecordingStatus: View {
    let model: AppModel
    let compact: Bool
    @Environment(\.openSettings) private var openSettings
    @State private var hovered = false

    var body: some View {
        // The engine's own state is not observable, so it is read on a slow
        // beat: coarse enough to cost nothing, fine enough to catch leaving.
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            let status = status
            Menu {
                if model.trackingPaused {
                    Button("继续记录", systemImage: "play.fill") { model.resumeTracking() }
                } else {
                    Text("暂停应用、网站、标题和屏幕采集")
                    Button("暂停 15 分钟", systemImage: "pause.circle") { model.pauseTracking(minutes: 15) }
                    Button("暂停 1 小时", systemImage: "clock") { model.pauseTracking(minutes: 60) }
                    Button("直到手动恢复", systemImage: "hand.raised") { model.pauseTracking(minutes: nil) }
                }
                Divider()
                Button("设置…", systemImage: "gearshape") { openSettings(); AppWindow.settings.bringForward() }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    if !compact { Text(status.title).foregroundStyle(Design.ink2).fixedSize() }
                }
                .font(.body)
                .padding(.horizontal, Design.Space.sm).frame(minWidth: Design.controlHeight, minHeight: Design.controlHeight)
                .background(hovered ? Design.hoverFill : .clear, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .onHover { hovered = $0 }
            .help(status.title)
            .accessibilityLabel(Text(status.title))
        }
    }

    private var status: (title: LocalizedStringKey, color: Color) {
        let running = model.engine.isRunning, suspended = model.engine.isSuspended
        let recording = running && !suspended && !model.trackingPaused && model.engine.currentActivity != nil
        if !model.accessibilityGranted { return ("未记录 · 需要权限", Design.alert) }
        if model.trackingPaused { return ("已暂停", Design.warning) }
        if !running { return ("记录未启动", Design.ink2.opacity(0.6)) }
        if suspended { return ("离开电脑", Design.ink2.opacity(0.6)) }
        return recording ? ("正在记录", Design.live) : ("等待活动", Design.ink2.opacity(0.6))
    }
}

// MARK: - Window chrome

/// Drag the window by any bare part of the bar, and double-click to zoom or
/// minimise as the system says a title bar does.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2, let window else { super.mouseDown(with: event); return }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        }
    }
}

/// The traffic lights stay the system's own; this lowers them to the
/// bar's centre line instead of a 28 pt title bar's.
private struct TrafficLightInset: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { Probe(height: height) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.height = height }

    private final class Probe: NSView {
        var height: CGFloat
        private var observers: [NSObjectProtocol] = []

        init(height: CGFloat) { self.height = height; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Observers belong to the window the view was in.
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                              NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                                              NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let container = window.standardWindowButton(.closeButton)?.superview?.superview else { return }
            var frame = container.frame
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            if container.frame != frame { container.frame = frame }
        }
    }
}
