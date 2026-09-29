import SwiftUI

struct RefinedRulesPane: View {
    let model: AppModel
    @State private var rows: [RuleRow] = []
    private var search: String { model.organizationSearch }
    @State private var error: String?
    @State private var pendingTitle: PendingTitleRule?
    @State private var showURL = false
    @State private var newPattern = ""
    @State private var newCategory = "softwareDev"
    @State private var dragged: String?
    private struct RuleRow: Identifiable {
        let id: String
        let type: String
        let pattern: String
        let scope: String
        let category: String
        let source: String
        let rank: Int
        let priority: Int
        let recordID: Int64?
        let seconds: TimeInterval
        var enabled: Bool
    }
    private var visible: [RuleRow] { rows.filter { search.isEmpty || ($0.pattern + $0.scope + (model.resolver.categoriesByID[$0.category]?.name ?? "")).localizedCaseInsensitiveContains(search) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("按优先级匹配；拖动可调整同一范围的标题规则顺序。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("标题规则…") { pendingTitle = .init(prefill: "", scopeKey: "", scopeLabel: "", categoryID: "softwareDev") }
                    Button("网址规则…") { showURL = true }
                } label: { Label("新建规则", systemImage: "plus") }.fixedSize()
            }.padding(14)
            HStack {
                Spacer()
                Text("\(visible.count) 条").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.bottom, 12)
            header
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { row in
                        rule(row).draggable(row.id) { Text(row.pattern).padding(10).background(RefinedStyle.panel) }
                            .dropDestination(for: String.self) { ids, _ in reorder(ids.first, before: row) }
                        Divider()
                    }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(12) }
        }.workspacePanel().task { load() }
        .onChange(of: model.dataEditVersion) { _, _ in load() }
        .sheet(item: $pendingTitle) { TitleRuleEditor(model: model, pending: $0) }
        .sheet(isPresented: $showURL) {
            VStack(alignment: .leading, spacing: 16) {
                Text("新建网址规则").font(.system(size: 17, weight: .semibold))
                TextField("网址包含，或 re: 正则表达式", text: $newPattern).textFieldStyle(.roundedBorder)
                Picker("归为", selection: $newCategory) { ForEach(model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { Text($0.name).tag($0.id) } }
                Text("仅检查记录中的网址；不访问网页。").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack { Spacer(); Button("取消") { showURL = false }; Button("添加规则", action: addURL).buttonStyle(.borderedProminent).disabled(TitleRuleInput.normalizedPattern(newPattern) == nil) }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(24).frame(width: 460)
        }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 16, height: 1)
            Text("类型").frame(width: 42, alignment: .leading)
            Text("条件").frame(maxWidth: .infinity, alignment: .leading)
            Text("归为").frame(width: 94, alignment: .leading)
            Text("今天命中").frame(width: 70, alignment: .trailing)
            Text("来源").frame(width: 32)
            Color.clear.frame(width: 30, height: 1)
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 28).background(.quaternary.opacity(0.45))
    }
    private func rule(_ row: RuleRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 16)
                .opacity(row.type == String(localized: "标题") && row.source == "user" ? 1 : 0)
            Text(row.type).font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 3).frame(width: 42).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            HStack(spacing: 3) {
                if !row.scope.isEmpty { Text(row.scope + " ·").foregroundStyle(.secondary) }
                Text(row.pattern)
            }.font(.system(size: 13)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(row.scope + " " + row.pattern)
            CategoryChip(category: model.resolver.categoriesByID[row.category]).frame(width: 94, alignment: .leading)
            Text(row.seconds == 0 ? "—" : Format.duration(row.seconds)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().frame(width: 70, alignment: .trailing)
            Text(row.source == "user" ? "你" : "内置").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 32)
            Toggle("启用规则", isOn: Binding(get: { row.enabled }, set: { setEnabled(row, $0) })).toggleStyle(.switch).controlSize(.mini).labelsHidden().frame(width: 30)
        }.padding(.horizontal, 14).frame(minHeight: 42).opacity(row.enabled ? 1 : 0.5)
            .contextMenu {
                if row.source == "user", row.type == String(localized: "标题") || row.type == String(localized: "网址") {
                    Button("删除规则", role: .destructive) { delete(row) }
                }
            }
    }
    private func load() {
        do {
            let disabled = try model.categoryStore.disabledRules()
            let today = model.rangedSpans(for: .today())
            let hits = today.reduce(into: [String: TimeInterval]()) { totals, item in
                if let key = model.resolver.matchingRuleKey(for: item.span) { totals[key, default: 0] += item.span.duration }
            }
            var result: [RuleRow] = []
            for rule in try model.categoryStore.titleRules() {
                result.append(.init(id: "title:\(rule.id ?? 0)", type: String(localized: "标题"), pattern: rule.pattern, scope: rule.scopeKey, category: rule.categoryID, source: rule.source, rank: rule.source == "user" ? 0 : 3, priority: rule.priority, recordID: rule.id, seconds: hits["title:\(rule.id ?? 0)", default: 0], enabled: rule.enabled))
            }
            for (domain, entry) in try model.categoryStore.domainMap() where entry.source == "user" {
                let key = "domain:" + domain
                result.append(.init(id: key, type: String(localized: "网站"), pattern: domain, scope: "", category: entry.categoryID, source: entry.source, rank: 1, priority: domain.count, recordID: nil, seconds: hits[key, default: 0], enabled: !disabled.contains(key)))
            }
            for rule in try model.categoryStore.urlRules() {
                let key = "url:\(rule.id ?? 0)"
                result.append(.init(id: key, type: String(localized: "网址"), pattern: rule.pattern, scope: "", category: rule.categoryID, source: rule.source, rank: rule.source == "user" ? 2 : 4, priority: rule.priority, recordID: rule.id, seconds: hits[key, default: 0], enabled: !disabled.contains(key)))
            }
            for (app, entry) in try model.categoryStore.appMap() {
                let key = "app:" + app
                result.append(.init(id: key, type: String(localized: "应用"), pattern: AppIcon.name(for: app), scope: "", category: entry.categoryID, source: entry.source, rank: 6, priority: 0, recordID: nil, seconds: hits[key, default: 0], enabled: !disabled.contains(key)))
            }
            rows = result.sorted {
                if $0.rank != $1.rank { return $0.rank < $1.rank }
                if $0.type == String(localized: "标题"), $0.scope.isEmpty != $1.scope.isEmpty { return !$0.scope.isEmpty }
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                if $0.type == String(localized: "标题") { return ($0.recordID ?? 0) > ($1.recordID ?? 0) }
                return $0.pattern.localizedStandardCompare($1.pattern) == .orderedAscending
            }
        } catch { self.error = String(localized: "规则暂时无法读取。") }
    }
    private func setEnabled(_ row: RuleRow, _ enabled: Bool) {
        perform {
            if row.type == String(localized: "标题"), let id = row.recordID { try model.categoryStore.setTitleRuleEnabled(id: id, enabled: enabled) }
            else { try model.categoryStore.setRuleEnabled(key: row.id, enabled: enabled) }
        }
    }
    private func delete(_ row: RuleRow) {
        guard let id = row.recordID else { return }
        perform {
            if row.type == String(localized: "标题") { try model.categoryStore.deleteTitleRule(id: id) }
            else { try model.categoryStore.deleteURLRule(id: id) }
        }
    }
    private func addURL() {
        guard let pattern = TitleRuleInput.normalizedPattern(newPattern) else { return }
        perform { try model.categoryStore.addUserURLRule(pattern: pattern, categoryID: newCategory, priority: 1000) }
        if error == nil { newPattern = ""; showURL = false }
    }
    private func reorder(_ id: String?, before target: RuleRow) -> Bool {
        guard let id, let source = rows.first(where: { $0.id == id }), source.type == String(localized: "标题"), target.type == String(localized: "标题"), source.source == "user", target.source == "user", source.scope == target.scope else { return false }
        var ordered = rows.filter { $0.type == String(localized: "标题") && $0.source == "user" && $0.scope == target.scope && $0.id != id }
        guard let index = ordered.firstIndex(where: { $0.id == target.id }) else { return false }
        ordered.insert(source, at: index)
        perform { try model.categoryStore.orderTitleRules(ordered.compactMap(\.recordID)) }
        return error == nil
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil; model.resolver.refresh(); model.dataChanged(); load() }
        catch { self.error = String(localized: "规则未保存：\(error.localizedDescription)") }
    }
}
