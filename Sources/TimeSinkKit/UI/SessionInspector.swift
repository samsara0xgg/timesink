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
            VStack(alignment: .leading, spacing: Design.Space.card) {
                header
                kpiRow
                actions
                mergeSuggestion
                projectRow
                composition
                categoryRow
                screenReview
                sources
            }
            .padding(Design.Space.lg)
        }
        .scrollContentBackground(.hidden)
        .onChange(of: session.start) { _, _ in editingName = false; newProject = false; recatOpen = false }
        .task(id: session.start) { loadCaptures() }
        .sheet(item: $selectedCapture) { CaptureReviewSheet(capture: $0) }
    }

    private var kpis: SessionKPIs {
        SessionKPIs.make(session, items: model.rangedSpans(for: DateInterval(start: session.start, end: session.end)),
                         episodes: activities.dayInterruptions?.episodes ?? [])
    }

    /// 时长, 切换, 打断 and 主要应用 at a glance.
    private var kpiRow: some View {
        let k = kpis
        let known = activities.dayInterruptions != nil
        let interval: String = k.interruptionInterval.map { String(localized: "平均 \(Format.duration($0)) 一次") } ?? String(localized: "没被打断")
        return Grid(alignment: .leading, horizontalSpacing: Design.Space.md, verticalSpacing: Design.Space.md) {
            GridRow {
                kpi("时长", Format.duration(session.recorded), note: String(localized: "跨度 \(Format.duration(session.duration))"))
                kpi("切换", String(localized: "\(k.switches) 次"), note: String(localized: "每分钟 \(String(format: "%.1f", k.switchRate)) 次"))
            }
            GridRow {
                kpi("打断", known ? String(localized: "\(k.interruptions) 次") : "—", note: known ? interval : "")
                kpi("主要应用", k.topApp ?? "—", note: String(localized: "占 \(Int((k.topShare * 100).rounded()))%"))
            }
        }
        .padding(Design.Space.md).frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.floor, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
    }

    private func kpi(_ label: LocalizedStringKey, _ value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.note).foregroundStyle(Design.ink2)
            Text(verbatim: value).font(.figure).foregroundStyle(Design.ink).lineLimit(1).minimumScaleFactor(0.8)
            Text(verbatim: note).font(.note).monospacedDigit().foregroundStyle(Design.ink2).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previous: WorkSession? { activities.sessions.last { $0.start < session.start } }

    /// 拆开 and 并入上一段, as pills under the name.
    private var actions: some View {
        HStack(spacing: Design.Space.sm) {
            splitMenu
            Button { withAnimation(Design.motion(Design.layout, reduced: reduceMotion)) { activities.join(session, model: model) } } label: {
                Label("并入上一段", systemImage: "arrow.up.to.line")
            }
            .buttonStyle(PillButtonStyle()).disabled(previous == nil)
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
                HStack(spacing: Design.Space.sm) {
                    Image(systemName: "arrow.up.to.line").foregroundStyle(Design.iconInk)
                    Group {
                        if sameProject { gap < 60 ? Text("和上一段是同一个项目，紧接着。") : Text("和上一段是同一个项目，隔了 \(Format.duration(gap))。") }
                        else { gap < 60 ? Text("和上一段是同一类，紧接着。") : Text("和上一段是同一类，只隔了 \(Format.duration(gap))。") }
                    }.foregroundStyle(Design.ink2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Design.Space.xs)
                    Button("合并成一段") { withAnimation(Design.motion(Design.layout, reduced: reduceMotion)) { activities.join(session, model: model) } }
                        .buttonStyle(PillButtonStyle(height: 24))
                }
                .padding(Design.Space.md)
                .background(Design.floor, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
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
                Text("分类").font(.body.weight(.semibold))
                Spacer()
                CategoryChip(category: current)
                if !recatOpen {
                    Button("修改分类…") { recatCategory = session.categoryID; recatScope = .segment; recatOpen = true }
                        .buttonStyle(PillButtonStyle(height: 24, font: .note))
                }
            }
            if recatOpen {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(ordered.filter { $0.id != "uncategorized" }, id: \.id) { category in
                        let chosen = recatCategory == category.id
                        Button { recatCategory = category.id } label: {
                            HStack(spacing: 5) {
                                Circle().fill(RefinedStyle.category(category.id, hex: category.colorHex)).frame(width: 7, height: 7)
                                Text(category.name).lineLimit(1)
                            }
                            .fontWeight(chosen ? .semibold : .regular).foregroundStyle(chosen ? Design.ink : Design.ink2)
                            .padding(.horizontal, Design.Space.sm).frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                            .background(chosen ? Design.selectedFill : Design.hoverFill,
                                        in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                        }.buttonStyle(.plain).accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
                HStack(spacing: 6) {
                    Text("应用到").foregroundStyle(Design.ink2)
                    Segmented(options: [ReclassificationEdit.Scope.segment, .activity], selection: $recatScope, height: 24) { scope in
                        scope == .segment ? Text("这一段会话") : Text("整个应用")
                    }
                }
                if recatScope == .activity, let app = session.apps.first {
                    Text("\(app.name) 的记录以后都归这一类。").font(.note).foregroundStyle(Design.ink2)
                }
                HStack {
                    Spacer()
                    Button("取消") { recatOpen = false }.buttonStyle(PillButtonStyle())
                    Button("重新归类") { applyRecat() }.buttonStyle(AccentButtonStyle()).disabled(recatCategory == session.categoryID)
                }
                if let error { Text(error).font(.note).foregroundStyle(Design.alert) }
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
            withAnimation(Design.motion(Design.layout, reduced: reduceMotion)) { recatOpen = false }
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
                Text("屏幕回看").font(.body.weight(.semibold))
                Spacer()
                Text("只在本机").font(.note).foregroundStyle(Design.ink2)
            }
            if captures.isEmpty {
                Text("这段时间没有保存的画面。可在「记录与隐私」中查看采集状态。").font(.note).foregroundStyle(Design.ink2)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(captures, id: \.id) { capture in
                        Button { selectedCapture = capture } label: {
                            VStack(spacing: 3) {
                                CaptureThumbnail(capture: capture, maxPixels: 240).frame(height: 50).clipped().clipShape(RoundedRectangle(cornerRadius: Design.Radius.mark))
                                Text(capture.at, format: .dateTime.hour().minute()).font(.note).monospacedDigit()
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
            Label("会话", systemImage: "rectangle.stack").font(.note).foregroundStyle(Design.ink2)
            if editingName {
                HStack {
                    TextField("会话名称", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                        .onSubmit(commitName)
                    Button("完成", action: commitName).controlSize(.small)
                }
                Text("以后同类的会话也用这个名字").font(.note).foregroundStyle(Design.ink2)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(title ?? String(localized: "没有起名"))
                        .font(.figure)
                        .foregroundStyle(title == nil ? Design.ink2 : Design.ink)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button { name = title ?? ""; editingName = true; focused = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless).help("改名")
                }
            }
            Text("\(model.time(session.start))–\(model.time(session.end)) · 记录 \(Format.chineseDuration(session.recorded))")
                .foregroundStyle(Design.ink2).monospacedDigit()
            Text(sourceNote).font(.note).foregroundStyle(Design.ink2)
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
                Text("项目").font(.body.weight(.semibold))
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
                Text("用到的应用").font(.body.weight(.semibold))
                Spacer()
                Text("颜色是应用的分类").font(.note).foregroundStyle(Design.ink2)
            }
            ForEach(session.apps.prefix(6), id: \.bundleID) { app in
                let appCategory = category(of: app.bundleID)
                let color = RefinedStyle.category(appCategory?.id ?? session.categoryID, hex: appCategory?.colorHex ?? "#8E8E93")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(app.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.duration(app.seconds)).font(.note).foregroundStyle(Design.ink2).monospacedDigit()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Design.track)
                            Capsule().fill(color).frame(width: max(3, geometry.size.width * app.seconds / max(1, session.recorded)))
                        }
                    }
                    .frame(height: 4)
                }
            }
            if session.apps.count > 6 {
                Text("另有 \(session.apps.count - 6) 个应用").font(.note).foregroundStyle(Design.ink2)
            }
        }
    }

    @ViewBuilder private var sources: some View {
        let items = Array((basis.documents.prefix(3) + basis.titles).prefix(8))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("名字依据的标题").font(.body.weight(.semibold))
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title).font(.note).lineLimit(2)
                        Spacer(minLength: 4)
                        Text(Format.duration(item.seconds)).font(.note).foregroundStyle(Design.ink2).monospacedDigit()
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
            .menuStyle(.button).buttonStyle(PillButtonStyle()).menuIndicator(.hidden).fixedSize()
        }
    }
}
