import SwiftUI

/// F1: a session in the inspector -- what it is made of, which titles its
/// name came from, and 改名 / 拆分 / 归入项目.
struct SessionInspector: View {
    let model: AppModel
    @Bindable var activities: ActivitiesModel
    let session: WorkSession
    @State private var editingName = false
    @State private var name = ""
    @State private var newProject = false
    @State private var project = ""
    @FocusState private var focused: Bool
    @State private var recatOpen = false
    @State private var recatCategory = ""
    @State private var recatScope: ReclassificationEdit.Scope = .segment
    @State private var captures: [Capture] = []
    @State private var selectedCapture: Capture?
    @State private var error: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var label: SessionLabel? { model.sessionLabels[session.nameKey] }
    private var override: SessionNameRow? { model.sessionOverrides[session.signature] }
    private var title: String? { model.sessionTitle(session) }
    private var basis: WorkSession { SessionNamer.cleaned(session) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                actions
                mergeSuggestion
                projectRow
                composition
                categoryRow
                screenReview
                sources
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .onChange(of: session.start) { _, _ in editingName = false; newProject = false; recatOpen = false }
        .task(id: session.start) { loadCaptures() }
        .sheet(item: $selectedCapture) { CaptureReviewSheet(capture: $0) }
    }

    private var previous: WorkSession? { activities.sessions.last { $0.start < session.start } }

    /// 拆开 and 并入上一段, as pills under the name.
    private var actions: some View {
        HStack(spacing: 8) {
            splitMenu
            Button { withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) { activities.join(session, model: model) } } label: {
                Label("并入上一段", systemImage: "arrow.up.to.line")
            }
            .buttonStyle(PillButtonStyle(height: 28)).disabled(previous == nil)
        }
    }

    /// A previous session of the same project, or the same kind a few minutes
    /// before, is probably the same piece of work.
    @ViewBuilder private var mergeSuggestion: some View {
        if let previous {
            let gap = session.start.timeIntervalSince(previous.end)
            let sameProject = model.sessionProject(session) != nil && model.sessionProject(session) == model.sessionProject(previous)
            let sameKind = previous.categoryID == session.categoryID && gap < 15 * 60
            if sameProject || sameKind {
                HStack(spacing: 8) {
                    Text("✦").foregroundStyle(Design.accent)
                    Group {
                        if sameProject { Text("和上一段是同一个项目，隔了 \(Format.chineseDuration(max(0, gap)))。") }
                        else { Text("和上一段是同一类，只隔了 \(Format.chineseDuration(max(0, gap)))。") }
                    }.font(.system(size: 12)).foregroundStyle(Design.ink2)
                    Spacer(minLength: 4)
                    Button("合并成一段") { withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) { activities.join(session, model: model) } }
                        .buttonStyle(PillButtonStyle(height: 26, tint: Design.accentInk))
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Design.track))
            }
        }
    }

    /// The category the session mostly sat in, and a way to change it for
    /// the session or for its main app.
    private var categoryRow: some View {
        let current = model.resolver.categoriesByID[session.categoryID]
        let ordered = model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("分类").font(.system(size: 12, weight: .medium))
                Spacer()
                CategoryChip(category: current)
                if !recatOpen {
                    Button("修改分类…") { recatCategory = session.categoryID; recatScope = .segment; recatOpen = true }
                        .buttonStyle(PillButtonStyle(height: 24, font: .system(size: 11)))
                }
            }
            if recatOpen {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(ordered.filter { $0.id != "uncategorized" }, id: \.id) { category in
                        Button { recatCategory = category.id } label: {
                            HStack(spacing: 5) {
                                Circle().fill(RefinedStyle.category(category.id, hex: category.colorHex)).frame(width: 7, height: 7)
                                Text(category.name).lineLimit(1)
                            }
                            .font(.system(size: 12, weight: recatCategory == category.id ? .bold : .regular))
                            .padding(.horizontal, 8).frame(height: 26)
                            .background(Capsule().fill(recatCategory == category.id ? Design.pillTop : Design.track))
                        }.buttonStyle(.plain)
                    }
                }
                HStack(spacing: 6) {
                    Text("应用到").font(.system(size: 12)).foregroundStyle(Design.ink3)
                    Picker("应用范围", selection: $recatScope) {
                        Text("这一段会话").tag(ReclassificationEdit.Scope.segment)
                        Text("整个应用").tag(ReclassificationEdit.Scope.activity)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                if recatScope == .activity, let app = session.apps.first {
                    Text("\(app.name) 的记录以后都归这一类。").font(.system(size: 11)).foregroundStyle(Design.ink3)
                }
                HStack {
                    Spacer()
                    Button("取消") { recatOpen = false }.buttonStyle(PillButtonStyle(height: 26))
                    Button("重新归类") { applyRecat() }.buttonStyle(AccentButtonStyle(height: 26)).disabled(recatCategory == session.categoryID)
                }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            }
        }
    }

    private func applyRecat() {
        let items = activities.displayedItems.filter { $0.span.start < session.end && $0.span.end > session.start }
        do {
            if recatScope == .segment {
                for item in items where item.categoryID != recatCategory {
                    _ = try model.categoryStore.reclassify(span: item.span, scope: .segment, categoryID: recatCategory)
                }
            } else if let top = session.apps.first, let item = items.first(where: { $0.span.appBundleID == top.bundleID }) {
                _ = try model.categoryStore.reclassify(span: item.span, scope: .activity, categoryID: recatCategory)
            }
            model.resolver.refresh(); model.dataChanged()
            error = nil
            withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) { recatOpen = false }
        } catch { self.error = String(localized: "分类未保存，请重试。") }
    }

    private func loadCaptures() {
        let all = (try? model.observationStore?.captures(overlapping: DateInterval(start: session.start, end: session.end))) ?? []
        // Six, spread across the session.
        let step = max(1, all.count / 6)
        captures = all.enumerated().filter { $0.offset % step == 0 }.prefix(6).map(\.element)
    }

    @ViewBuilder private var screenReview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("屏幕回看").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("只在本机").font(.system(size: 11)).foregroundStyle(Design.ink3)
            }
            if captures.isEmpty {
                Text("这段时间没有保存的画面。可在「记录与隐私」中查看采集状态。").font(.system(size: 11)).foregroundStyle(Design.ink3)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(captures, id: \.id) { capture in
                        Button { selectedCapture = capture } label: {
                            VStack(spacing: 3) {
                                CaptureThumbnail(capture: capture, maxPixels: 240).frame(height: 50).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(capture.at, format: .dateTime.hour().minute()).font(.system(size: 11)).monospacedDigit()
                            }
                        }.buttonStyle(.plain).help("打开本机截图")
                    }
                }
            }
        }
    }

    /// The category an app mostly sat in during this session.
    private func category(of bundleID: String) -> Category? {
        var seconds: [String: TimeInterval] = [:]
        for item in activities.displayedItems where item.span.appBundleID == bundleID && item.span.start < session.end && item.span.end > session.start {
            seconds[item.categoryID, default: 0] += item.span.duration
        }
        return seconds.max { $0.value < $1.value }.flatMap { model.resolver.categoriesByID[$0.key] }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("会话", systemImage: "rectangle.stack").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if editingName {
                HStack {
                    TextField("会话名称", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                        .onSubmit(commitName)
                    Button("完成", action: commitName).controlSize(.small)
                }
                Text("以后同类的会话也用这个名字").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(title ?? String(localized: "没有起名"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(title == nil ? .secondary : .primary)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button { name = title ?? ""; editingName = true; focused = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("改名")
                }
            }
            Text("\(model.time(session.start))–\(model.time(session.end)) · 记录 \(Format.chineseDuration(session.recorded))")
                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            Text(sourceNote).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private var sourceNote: String {
        if override?.name != nil { return String(localized: "你起的名字，同类会话沿用") }
        switch label?.source {
        case nil: return String(localized: "正在本机起名…")
        case .model?: return label?.name == nil ? String(localized: "Apple 智能把握不够，没有起名，下面列出应用")
            : String(localized: "Apple 智能在本机起的名，只读了标题和应用名")
        case .title?: return String(localized: "取自停留最久的窗口标题")
        case .none?: return String(localized: "标题太分散，没有起名，下面列出应用")
        }
    }

    private func commitName() {
        model.renameSession(session, to: name)
        editingName = false
    }

    private var projectRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("项目").font(.system(size: 12, weight: .medium))
                Spacer()
                Menu {
                    ForEach(model.knownProjects, id: \.self) { name in
                        Button(name) { model.assignSession(session, toProject: name) }
                    }
                    if !model.knownProjects.isEmpty { Divider() }
                    Button("新项目…") { project = ""; newProject = true }
                    if override?.project != nil {
                        Button("不归入项目") { model.assignSession(session, toProject: "") }
                    }
                } label: {
                    Text(model.sessionProject(session) ?? String(localized: "未归入"))
                }
                .fixedSize()
            }
            if newProject {
                HStack {
                    TextField("项目名称", text: $project).textFieldStyle(.roundedBorder)
                        .onSubmit { model.assignSession(session, toProject: project); newProject = false }
                    Button("归入") { model.assignSession(session, toProject: project); newProject = false }.controlSize(.small)
                }
            }
        }
    }

    private var composition: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("用到的应用").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("颜色是应用的分类").font(.system(size: 11)).foregroundStyle(Design.ink3)
            }
            ForEach(session.apps.prefix(6), id: \.bundleID) { app in
                let appCategory = category(of: app.bundleID)
                let color = RefinedStyle.category(appCategory?.id ?? session.categoryID, hex: appCategory?.colorHex ?? "#8E8E93")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(app.name).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.duration(app.seconds)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(color).frame(width: max(3, geometry.size.width * app.seconds / max(1, session.recorded)))
                        }
                    }
                    .frame(height: 4)
                }
            }
            if session.apps.count > 6 {
                Text("另有 \(session.apps.count - 6) 个应用").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var sources: some View {
        let items = Array((basis.documents.prefix(3) + basis.titles).prefix(8))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("名字依据的标题").font(.system(size: 12, weight: .medium))
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title).font(.system(size: 11.5)).lineLimit(2)
                        Spacer(minLength: 4)
                        Text(Format.duration(item.seconds)).font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    .help(item.appName)
                }
            }
        }
    }

    /// Where the session can be cut: the blocks that start inside it.
    @ViewBuilder private var splitMenu: some View {
        let points = activities.timelineBlocks
            .filter { !$0.isHighlight && $0.activity != nil && $0.start.timeIntervalSince(session.start) >= 60 && $0.start < session.end.addingTimeInterval(-60) }
            .prefix(12)
        if !points.isEmpty {
            Menu {
                ForEach(Array(points), id: \.id) { block in
                    Button("从 \(model.time(block.start)) 起拆开 · \(block.label)") { model.splitSession(at: block.start) }
                }
            } label: {
                Label("拆开", systemImage: "scissors")
            }
            .menuStyle(.button).buttonStyle(PillButtonStyle(height: 28)).menuIndicator(.hidden).fixedSize()
        }
    }
}
