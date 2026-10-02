import SwiftUI

/// One unsure Jev verdict as the 待确认 list shows it.
struct ToConfirmRow: Identifiable, Equatable {
    var id: VerdictKey { verdict.key }
    let verdict: LowConfidenceVerdict
    /// The site, or the app when there is none.
    let label: String
    /// Title or file name, shortened.
    let detail: String
    let pickName: String
    let runnerUpName: String?

    static let detailLimit = 48

    /// Longest first. A pick whose category no longer exists is not listed:
    /// there is nothing to confirm.
    static func rows(_ verdicts: [LowConfidenceVerdict], categories: [String: Category]) -> [ToConfirmRow] {
        verdicts.sorted { $0.seconds > $1.seconds }.compactMap { v in
            guard let pick = categories[v.categoryID] else { return nil }
            let text = v.key.title.isEmpty ? v.key.document : v.key.title
            return ToConfirmRow(verdict: v, label: v.key.domain.isEmpty ? v.appName : v.key.domain,
                                detail: text.count > detailLimit ? text.prefix(detailLimit) + "…" : text,
                                pickName: pick.name, runnerUpName: categories[v.runnerUp]?.name)
        }
    }
}

/// 待确认: what Jev was unsure about in the current range. Confirming or
/// changing a verdict makes it the user's own.
struct ToConfirmCard: View {
    let model: AppModel
    @State private var rows: [ToConfirmRow] = []
    @State private var error: String?
    private struct LoadKey: Equatable { let version: Int; let range: DateRangeSelection }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeading(title: "待确认", caption: model.jev?.isEnabled == true && !rows.isEmpty ? Text("\(rows.count) 项 Jev 不太确定") : nil)
            if model.jev?.isEnabled != true {
                empty("Jev 没有开启。在设置 · 智能 里开启后，不确定的判断会列在这里。")
            } else if rows.isEmpty {
                empty("现在没有需要确认的内容。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { ForEach(rows) { row in line(row); Divider() } }
                }.scrollIndicators(.never).frame(maxHeight: 260)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
        }
        .padding(.horizontal, Design.Space.xl).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .designCard().revealOnce(index: 1)
        .pageTask(id: LoadKey(version: model.dataVersion, range: model.range)) { load() }
    }

    private func empty(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Design.ink3).padding(.vertical, 6)
    }

    private func line(_ row: ToConfirmRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !row.detail.isEmpty { Text(row.detail).font(.system(size: 12)).foregroundStyle(Design.ink3).lineLimit(1) }
                }
                (Text("Jev 倾向 \(row.pickName) \(Int((row.verdict.prob * 100).rounded()))%")
                    + (row.runnerUpName.map { Text(" · 其次 \($0) \(Int((row.verdict.runnerUpProb * 100).rounded()))%") } ?? Text(verbatim: "")))
                    .font(.system(size: 11)).foregroundStyle(Design.ink2).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Format.duration(row.verdict.seconds, compact: true)).font(.num(12)).foregroundStyle(Design.ink2)
            Button("确认") { set(row, row.verdict.categoryID, .none) }.buttonStyle(PillButtonStyle(height: 24, font: .system(size: 11)))
            Menu {
                picks(row, rule: .none)
                Divider()
                if !row.verdict.key.domain.isEmpty { Menu("改为并存为网站规则") { picks(row, rule: .domain) } }
                Menu("改为并存为应用规则") { picks(row, rule: .app) }
            } label: { Text("改分类") }
                .menuStyle(.button).buttonStyle(PillButtonStyle(height: 24, font: .system(size: 11))).fixedSize()
        }.frame(minHeight: 44)
    }

    private func picks(_ row: ToConfirmRow, rule: JevService.SavedRule) -> some View {
        ForEach(model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { category in
            Button(category.name) { set(row, category.id, rule) }
        }
    }

    private func set(_ row: ToConfirmRow, _ categoryID: String, _ rule: JevService.SavedRule) {
        do {
            try model.jev?.setVerdict(row.verdict.key, categoryID: categoryID, rule: rule)
            rows.removeAll { $0.id == row.id }
        } catch { self.error = String(localized: "没能保存：\(error.localizedDescription)") }
    }

    private func load() {
        guard let jev = model.jev, jev.isEnabled else { rows = []; return }
        do {
            rows = ToConfirmRow.rows(try jev.lowConfidenceVerdicts(in: model.range.interval), categories: model.resolver.categoriesByID)
            error = nil
        } catch { self.error = String(localized: "暂时无法读取。") }
    }
}
