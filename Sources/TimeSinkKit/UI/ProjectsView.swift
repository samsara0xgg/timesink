import SwiftUI

/// 分类 / 项目: the two tabs of the organization page.
struct OrganizationTabs: View {
    @Bindable var model: AppModel

    var body: some View {
        Segmented(options: [SettingsTab.uncategorized, .projects], selection: Binding(get: { model.organizationTab == .projects ? .projects : .uncategorized }, set: { model.organizationTab = $0 }), height: 28) { tab in
            tab == .projects ? Text("所有项目") : Text("分类")
        }
        .accessibilityLabel("分类页的标签")
    }
}

/// Wording for errors of the project store.
enum ProjectEditing {
    static func errorText(_ error: Error) -> String {
        switch error as? ProjectStore.ProjectError {
        case .emptyName: return String(localized: "名称不能为空。")
        case .duplicate: return String(localized: "已经有同名的项目。")
        case .limitReached: return String(localized: "最多 \(ProjectStore.maxProjects) 个项目，先合并或删除一个。")
        case .notFound: return String(localized: "找不到这个项目。")
        case .sameProject: return String(localized: "请选择另一个项目。")
        case nil: return error.localizedDescription
        }
    }
}

/// 项目: the projects you named, what is recommended, and a form to add one.
/// Jev is asked about every project on each window, so this list is also
/// what it can answer with.
struct ProjectsView: View {
    @Bindable var model: AppModel
    /// nil until the 14-day pass is done: the page shows names at once and a dash for the time.
    @State private var hours: [String: TimeInterval]?
    @State private var suggestions: ProjectSuggester.Result?
    @State private var name = ""
    @State private var details = ""
    @State private var error: String?
    @State private var editing: UserProject?
    private struct LoadKey: Equatable { let edits: Int; let projects: [UserProject] }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 2 * Design.Space.page
            if width >= PageLayout.wideWidth {
                VStack(alignment: .leading, spacing: Design.Space.lg) {
                    header(width: width)
                    HStack(alignment: .top, spacing: Design.Space.lg) {
                        listCard
                        recommendations.frame(width: 420)
                    }
                }
                .pagePadding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Design.Space.lg) {
                        header(width: width)
                        listCard.frame(minHeight: 320)
                        recommendations
                    }
                    .pagePadding()
                }.scrollIndicators(.never)
            }
        }
        .background(WorkspaceBackground())
        .pageTask(id: LoadKey(edits: model.dataEditVersion, projects: model.projects)) { await load() }
        .sheet(item: $editing) { project in ProjectEditSheet(model: model, project: project) { editing = nil } }
    }

    private func header(width: CGFloat) -> some View {
        let count = model.projects.count
        let sentence: Text
        if count == 0 { sentence = Text("还没有项目。") }
        else if let hours { sentence = Text("\(count) 个项目，近 14 天共 \(Format.duration(hours.values.reduce(0, +)))。") }
        else { sentence = Text("\(count) 个项目。") }
        return PageHeader(sentence: sentence, stats: [
            StripStat(id: 0, label: "项目", value: String(localized: "\(count) 个"), note: String(localized: "最多 \(ProjectStore.maxProjects) 个")),
        ], width: width) {
            OrganizationTabs(model: model)
        } actions: { EmptyView() }
    }

    // MARK: Your projects

    private var listCard: some View {
        VStack(alignment: .leading, spacing: Design.Space.sm) {
            CardHeading(title: "我的项目", caption: Text("近 14 天"))
            if model.projects.isEmpty {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    Text("还没有项目").font(.body.weight(.semibold))
                    Text("项目是你在做的事，比如一个产品或一门课。添加后，Jev 会把每段时间归到对应的项目里。")
                        .font(.note).foregroundStyle(Design.ink2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, Design.Space.md)
            } else {
                ScrollView {
                    VStack(spacing: 2) { ForEach(model.projects) { row($0).zIndex(ProjectColorDot.lift($0, in: model)) } }
                }.scrollIndicators(.never)
            }
            if !model.settings.jevEnabled {
                Text("项目由 Jev 判断。在设置里打开 Jev 之后，才会自动把时间归到项目里。")
                    .font(.note).foregroundStyle(Design.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            addForm
        }
        .padding(Design.Space.card)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .designCard()
    }

    private func row(_ project: UserProject) -> some View {
        let time = hours.map { Format.duration($0[SessionProjectResolver.normalized(project.name)] ?? 0) } ?? "—"
        return HStack(spacing: Design.Space.md) {
            ProjectColorDot(model: model, project: project)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name).foregroundStyle(Design.ink).lineLimit(1)
                if !project.description.isEmpty {
                    Text(project.description).font(.note).foregroundStyle(Design.ink2).lineLimit(1).help(project.description)
                }
            }
            Spacer(minLength: 0)
            Text(verbatim: time).font(.body.monospacedDigit()).foregroundStyle(Design.ink2).refinedNumberMotion(time)
                .frame(width: 84, alignment: .trailing)
            Button { editing = project } label: { Image(systemName: "pencil").font(.note).foregroundStyle(Design.ink2) }
                .buttonStyle(.plain).help("编辑项目").accessibilityLabel("编辑项目")
        }
        .padding(.horizontal, Design.Space.sm).frame(height: 44)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: Design.Space.sm) {
            Text("添加项目").font(.body.weight(.semibold))
            HStack(spacing: Design.Space.sm) {
                TextField("名称", text: $name).textFieldStyle(.roundedBorder).frame(width: 160).onSubmit(add)
                TextField("说明（可不写）", text: $details).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("添加", action: add).buttonStyle(AccentButtonStyle(height: 28))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("说明会和名称一起发给 Jev，写得越具体，判断越准。").font(.note).foregroundStyle(Design.ink2)
            if let error { Text(error).font(.note).foregroundStyle(Design.alert) }
        }
        .padding(.top, Design.Space.sm)
    }

    private func add() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            try model.categoryStore.projects.add(name: name, description: details.trimmingCharacters(in: .whitespacesAndNewlines))
            name = ""
            details = ""
            error = nil
            model.projectsChanged()
        } catch {
            self.error = ProjectEditing.errorText(error)
        }
    }

    // MARK: Recommendations

    private var recommendations: some View {
        VStack(alignment: .leading, spacing: Design.Space.sm) {
            CardHeading(title: "推荐", caption: Text("来自最近 14 天的记录"))
            if let suggestions {
                if !suggestions.gate.isOpen {
                    Text("记录几天后会推荐你的项目").font(.body.weight(.semibold))
                    Text("至少记录 3 天、共 8 小时之后才会推荐。目前 \(suggestions.gate.days) 天，\(Format.duration(suggestions.gate.recorded))。")
                        .font(.note).foregroundStyle(Design.ink2).fixedSize(horizontal: false, vertical: true)
                } else if suggestions.candidates.isEmpty {
                    Text("最近没有新的项目线索。").foregroundStyle(Design.ink2)
                } else {
                    ScrollView {
                        VStack(spacing: 2) { ForEach(suggestions.candidates) { candidate($0) } }
                    }.scrollIndicators(.never)
                    Text("推荐只是线索，不会自动添加。").font(.note).foregroundStyle(Design.ink2)
                }
            } else {
                Text(verbatim: " ")
            }
            Spacer(minLength: 0)
        }
        .padding(Design.Space.card)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .designCard()
    }

    private func candidate(_ candidate: ProjectSuggester.Candidate) -> some View {
        HStack(spacing: Design.Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.name).foregroundStyle(Design.ink).lineLimit(1)
                Text(candidate.summary).font(.note).foregroundStyle(Design.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("添加") {
                do {
                    try model.categoryStore.projects.add(name: candidate.name, source: "suggested")
                    error = nil
                    model.projectsChanged()
                } catch { self.error = ProjectEditing.errorText(error) }
            }
            .buttonStyle(PillButtonStyle(height: 26, font: .note))
        }
        .padding(.horizontal, Design.Space.sm).padding(.vertical, Design.Space.sm)
    }

    // MARK: Loading

    /// Both passes run off the main actor and are cached by the model; the page shows what it has meanwhile.
    private func load() async {
        async let found = model.projectSuggestions()
        async let time = model.projectHours()
        suggestions = await found
        hours = await time
    }
}

/// Renames a project or changes its description; merges it into another, or removes it.
struct ProjectEditSheet: View {
    let model: AppModel
    let project: UserProject
    let done: () -> Void
    @State private var name = ""
    @State private var details = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑项目").font(.figure)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                TextField("说明：什么内容属于这个项目", text: $details, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                Text("改名或改说明后，Jev 会按新的内容重新判断最近 14 天。").font(.note).foregroundStyle(Design.ink2)
            }
            HStack {
                Menu("合并到…") {
                    ForEach(model.projects.filter { $0.id != project.id }) { other in
                        Button(other.name) { run { try model.categoryStore.projects.merge(project.id, into: other.id) } }
                    }
                }.menuStyle(.button).buttonStyle(PillButtonStyle()).fixedSize().disabled(model.projects.count < 2)
                Button("删除") { run { try model.categoryStore.projects.archive(project.id) } }
                    .buttonStyle(PillButtonStyle(tint: Design.alert))
                Spacer()
            }
            if let error { Text(error).font(.note).foregroundStyle(Design.alert) }
            HStack {
                Spacer()
                Button("取消", action: done).keyboardShortcut(.cancelAction)
                Button("保存") { run { try model.categoryStore.projects.update(id: project.id, name: name, description: details) } }
                    .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24).frame(width: 440)
        .onAppear { name = project.name; details = project.description }
    }

    private func run(_ change: () throws -> Void) {
        do {
            try change()
            model.projectsChanged()
            done()
        } catch {
            self.error = ProjectEditing.errorText(error)
        }
    }
}

/// A project's colour: a dot that opens the palette's eight colours. Picking one is stored at once and
/// every page follows. Another project's colour may be picked; the tooltip says who wears it.
struct ProjectColorDot: View {
    let model: AppModel
    let project: UserProject
    @State private var open = false
    #if DEBUG
    /// Capture hook: `TIMESINK_PREVIEW_COLOR_MENU=1` shows the first project's palette in place (a popover
    /// does not render in an offscreen capture).
    private static let previewOpen = ProcessInfo.processInfo.environment["TIMESINK_PREVIEW_COLOR_MENU"] != nil
    private var showsInPlace: Bool { Self.previewOpen && model.projects.first?.id == project.id }
    static func lift(_ project: UserProject, in model: AppModel) -> Double { previewOpen && model.projects.first?.id == project.id ? 1 : 0 }
    #else
    static func lift(_ project: UserProject, in model: AppModel) -> Double { 0 }
    #endif

    private var current: Int { project.colorIndex ?? ProjectPalette.preferredSlot(project.name) }

    var body: some View {
        Button { open.toggle() } label: {
            Circle().fill(Design.projectColor(current)).frame(width: 9, height: 9)
                .padding(8).contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(-8)
        .help("项目颜色").accessibilityLabel("项目颜色")
        .popover(isPresented: $open, arrowEdge: .bottom) { palette }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if showsInPlace {
                palette.background(Design.surface, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).stroke(Design.line))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3).fixedSize().offset(x: -8, y: 24)
            }
        }
        #endif
    }

    private var palette: some View {
        HStack(spacing: 6) {
            ForEach(0..<ProjectPalette.slots, id: \.self) { slot in
                let others = model.projects.filter { $0.id != project.id && ($0.colorIndex ?? ProjectPalette.preferredSlot($0.name)) == slot }.map(\.name)
                Button { pick(slot) } label: {
                    Circle().fill(Design.projectColor(slot)).frame(width: 20, height: 20)
                        .overlay { if slot == current { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Design.projectLabel(slot)) } }
                        .padding(3).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(others.isEmpty ? Text("没有其他项目用这个颜色") : Text("也用于：\(ListFormatter.localizedString(byJoining: others))"))
                .accessibilityLabel("颜色 \(slot + 1)")
                .accessibilityAddTraits(slot == current ? .isSelected : [])
            }
        }
        .padding(Design.Space.sm)
    }

    private func pick(_ slot: Int) {
        try? model.categoryStore.projects.setColor(id: project.id, index: slot)
        model.projectsChanged()
        open = false
    }
}
