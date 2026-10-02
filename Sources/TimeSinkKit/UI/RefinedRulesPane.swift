import SwiftUI

struct RefinedRulesPane: View {
    let model: AppModel
    /// Show only the rules that file under this category.
    var categoryFilter: String?
    var onClearFilter: (() -> Void)?
    @State private var rows: [RuleRow] = []
    @State private var hits: [String: TimeInterval] = [:]
    private var search: String { model.organizationSearch }
    @State private var error: String?
    @State private var urlError: String?
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
        var seconds: TimeInterval
        var enabled: Bool
        /// What a person reads: an app's name rather than its bundle ID.
        var scopeLabel = ""
        var displayPattern: String { pattern.hasPrefix("re:") ? pattern : pattern.replacingOccurrences(of: "|", with: String(localized: "、")) }
    }

    /// A URL rule is one substring (or `re:` expression) tested against the
    /// whole URL -- unlike a title rule, a comma is part of it, not a list.
    static func urlPattern(_ text: String) -> String? {
        let pattern = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.hasPrefix("re:") {
            let body = String(pattern.dropFirst(3))
            return !body.isEmpty && (try? NSRegularExpression(pattern: body)) != nil ? pattern : nil
        }
        return pattern.count >= 3 ? pattern : nil
    }
    private var chipWidth: CGFloat { RefinedStyle.chipWidth(for: model.resolver.categoriesByID) }
    private var visible: [RuleRow] { rows.filter { (categoryFilter == nil || $0.category == categoryFilter) && (search.isEmpty || ($0.pattern + $0.scope + (model.resolver.categoriesByID[$0.category]?.name ?? "")).localizedCaseInsensitiveContains(search)) } }
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
                if let categoryFilter, let onClearFilter {
                    Button { onClearFilter() } label: {
                        HStack(spacing: 4) {
                            Text("只看 \(model.resolver.categoriesByID[categoryFilter]?.name ?? "")")
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                    }.buttonStyle(PillButtonStyle(height: 24, font: .system(size: 11)))
                }
                Text("\(visible.count) 条").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.bottom, 12)
            header
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { row in
                        // Only user title rules have an order to change.
                        if isOrderable(row) {
                            rule(row).draggable(row.id) { Text(row.displayPattern).padding(10).background(RefinedStyle.panel) }
                                .dropDestination(for: String.self) { ids, _ in reorder(ids.first, onto: row) }
                        } else {
                            rule(row)
                        }
                        Divider()
                    }
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(12) }
        }.workspacePanel().task { load(); loadHits() }
        .onPageChange(of: model.dataEditVersion) { load(); loadHits() }
        .onPageChange(of: model.dataVersion) { loadHits() }
        .sheet(item: $pendingTitle) { TitleRuleEditor(model: model, pending: $0) }
        .sheet(isPresented: $showURL) {
            VStack(alignment: .leading, spacing: 16) {
                Text("新建网址规则").font(.system(size: 17, weight: .semibold))
                TextField("网址包含，或 re: 正则表达式", text: $newPattern).textFieldStyle(.roundedBorder)
                Picker("归为", selection: $newCategory) { ForEach(model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { Text($0.name).tag($0.id) } }
                Text("仅检查记录中的网址；不访问网页。至少 3 个字符。").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { newPattern = ""; urlError = nil; showURL = false }.keyboardShortcut(.cancelAction)
                    Button("添加规则", action: addURL).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(Self.urlPattern(newPattern) == nil)
                }
                if let urlError { Text(urlError).foregroundStyle(.red) }
            }.padding(24).frame(width: 460)
        }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Text("启用").frame(width: 28, alignment: .leading)
            Color.clear.frame(width: 16, height: 1)
            Text("类型").frame(width: 56, alignment: .leading)
            Text("条件").frame(maxWidth: .infinity, alignment: .leading)
            Text("归为").frame(width: chipWidth, alignment: .leading)
            Text("近 7 天").frame(width: 84, alignment: .trailing)
            Text("来源").frame(width: 48)
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 28).background(.quaternary.opacity(0.45))
    }
    private func rule(_ row: RuleRow) -> some View {
        HStack(spacing: 10) {
            Toggle(String(localized: "启用规则：\(row.displayPattern)"), isOn: Binding(get: { row.enabled }, set: { setEnabled(row, $0) })).toggleStyle(.checkbox).controlSize(.small).labelsHidden().frame(width: 28, alignment: .leading)
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.tertiary).frame(width: 16)
                .opacity(row.type == String(localized: "标题") && row.source == "user" ? 1 : 0)
            Text(row.type).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).padding(.vertical, 3).padding(.horizontal, 4)
                .frame(minWidth: 42).background(.quaternary, in: RoundedRectangle(cornerRadius: 5)).frame(width: 56, alignment: .leading)
            HStack(spacing: 3) {
                if !row.scopeLabel.isEmpty { Text(row.scopeLabel + " ·").foregroundStyle(.secondary) }
                Text(row.displayPattern)
            }.font(.system(size: 13)).foregroundStyle(row.enabled ? .primary : .secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).help(row.scopeLabel + " " + row.displayPattern)
            CategoryChip(category: model.resolver.categoriesByID[row.category]).lineLimit(1).frame(width: chipWidth, alignment: .leading)
            Text(row.seconds == 0 ? "—" : Format.duration(row.seconds, compact: true)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit().frame(width: 84, alignment: .trailing)
            Text(row.source == "user" ? "你" : "内置").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(width: 48)
        }.padding(.horizontal, 14).frame(minHeight: 42)
            .contextMenu {
                if isOrderable(row) {
                    Button("上移", systemImage: "arrow.up") { move(row, by: -1) }
                    Button("下移", systemImage: "arrow.down") { move(row, by: 1) }
                    Divider()
                }
                if row.source == "user" {
                    if row.recordID != nil { Button("删除规则", systemImage: "trash", role: .destructive) { delete(row) } }
                    else { Button("删除并恢复默认", role: .destructive) { perform { try model.categoryStore.removeUserMapping(key: row.id) } } }
                }
            }
    }
    /// Seven days of time credited to each rule key, worked out off the main
    /// thread from a snapshot of the rules.
    private func loadHits() {
        let interval = DateRangeSelection(kind: .last7, anchor: Date()).interval
        let store = model.spanStore, snapshot = model.resolver.snapshot()
        Task {
            let result = await Task.detached(priority: .utility) { () -> [String: TimeInterval] in
                guard let spans = try? store.spans(overlapping: interval) else { return [:] }
                var totals: [String: TimeInterval] = [:]
                for span in spans {
                    let seconds = min(span.end, interval.end).timeIntervalSince(max(span.start, interval.start))
                    if seconds > 0, let key = snapshot.matchingRuleKey(for: span) { totals[key, default: 0] += seconds }
                }
                return totals
            }.value
            hits = result
            rows = rows.map { var row = $0; row.seconds = result[row.id, default: 0]; return row }
        }
    }
    private func load() {
        do {
            let disabled = try model.categoryStore.disabledRules()
            let hits = self.hits
            var result: [RuleRow] = []
            for rule in try model.categoryStore.titleRules() {
                let scopeLabel = rule.scopeKey.isEmpty || NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.scopeKey) == nil
                    ? rule.scopeKey : AppIcon.name(for: rule.scopeKey)
                result.append(.init(id: "title:\(rule.id ?? 0)", type: String(localized: "标题"), pattern: rule.pattern, scope: rule.scopeKey, category: rule.categoryID, source: rule.source, rank: rule.source == "user" ? 0 : 3, priority: rule.priority, recordID: rule.id, seconds: hits["title:\(rule.id ?? 0)", default: 0], enabled: rule.enabled, scopeLabel: scopeLabel))
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
            error = nil
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
        guard let pattern = Self.urlPattern(newPattern) else { return }
        do {
            try model.categoryStore.addUserURLRule(pattern: pattern, categoryID: newCategory, priority: 1000)
            model.resolver.refresh(); model.dataChanged()
            newPattern = ""; urlError = nil; showURL = false
        } catch { urlError = String(localized: "规则未保存：\(error.localizedDescription)") }
    }
    private func isOrderable(_ row: RuleRow) -> Bool { row.type == String(localized: "标题") && row.source == "user" }
    /// Dropping moves a rule to the target's place: below it when dragged
    /// down, above it when dragged up, so every position is reachable.
    private func reorder(_ id: String?, onto target: RuleRow) -> Bool {
        guard let id, id != target.id, let source = rows.first(where: { $0.id == id }),
              isOrderable(source), isOrderable(target) else { return false }
        guard source.scope == target.scope else {
            error = String(localized: "标题规则只能在同一个应用或网站的范围内调整顺序。")
            return false
        }
        var ordered = rows.filter { isOrderable($0) && $0.scope == target.scope }
        guard let from = ordered.firstIndex(where: { $0.id == id }), let to = ordered.firstIndex(where: { $0.id == target.id }) else { return false }
        ordered.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        perform { try model.categoryStore.orderTitleRules(ordered.compactMap(\.recordID)) }
        return error == nil
    }
    private func move(_ row: RuleRow, by offset: Int) {
        var ordered = rows.filter { isOrderable($0) && $0.scope == row.scope }
        guard let from = ordered.firstIndex(where: { $0.id == row.id }), ordered.indices.contains(from + offset) else { return }
        ordered.swapAt(from, from + offset)
        perform { try model.categoryStore.orderTitleRules(ordered.compactMap(\.recordID)) }
    }
    /// `dataChanged()` bumps `dataEditVersion`, whose observer reloads the list.
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil; model.resolver.refresh(); model.dataChanged() }
        catch { self.error = String(localized: "规则未保存：\(error.localizedDescription)") }
    }
}
