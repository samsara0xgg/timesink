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

    private var label: SessionLabel? { model.sessionLabels[session.nameKey] }
    private var override: SessionNameRow? { model.sessionOverrides[session.signature] }
    private var title: String? { model.sessionTitle(session) }
    private var basis: WorkSession { SessionNamer.cleaned(session) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                projectRow
                composition
                sources
                splitMenu
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .onChange(of: session.start) { _, _ in editingName = false; newProject = false }
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
            Text("由这些应用组成").font(.system(size: 12, weight: .medium))
            let color = Color(hex: model.resolver.categoriesByID[session.categoryID]?.colorHex ?? "#8E8E93")
            ForEach(session.apps.prefix(6), id: \.bundleID) { app in
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
                Label("拆分这个会话", systemImage: "scissors")
            }
            .fixedSize()
        }
    }
}
