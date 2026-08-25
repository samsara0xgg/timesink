import SwiftUI
import os

private let titleRuleEditorLogger = Logger(subsystem: "com.alllllenshi.TimeSink", category: "titleRuleEditor")

/// Input for `TitleRuleEditor`, shared by `ActivityListView`'s right-click
/// path and `RulesSettingsPane`'s "+ 新建标题规则…" button.
struct PendingTitleRule: Identifiable {
    var id: String { "\(scopeKey)|\(prefill)" }
    /// 预填关键词文本（右键 = 完整标题；新建 = 空）。
    var prefill: String
    /// 右键 = 行的 domain/bundleID；新建默认 ""。
    var scopeKey: String
    /// 展示用（"仅 youtube.com" / "所有活动"）。
    var scopeLabel: String
    var categoryID: String
}

/// Pure validation/normalization for the editor's keyword field, kept free of
/// any view state so it's directly unit-testable.
enum TitleRuleInput {
    /// Splits `raw` on 逗号/顿号/竖线/换行, trims each piece, drops empties.
    /// Any surviving keyword shorter than 2 characters rejects the whole
    /// input (tier-0 has no undo, so a short pattern is a historically
    /// documented false-positive magnet). A `re:` prefix is kept whole and
    /// must compile via `NSRegularExpression` (an empty body -- `"re:"`
    /// alone -- is also rejected, since `Classifier.titleMatches` treats an
    /// empty regex as never-matching). Returns the pattern to store
    /// (`|`-joined keywords, or the `re:` string verbatim), or `nil` if
    /// invalid.
    nonisolated static func normalizedPattern(_ raw: String) -> String? {
        if raw.hasPrefix("re:") {
            let body = String(raw.dropFirst(3))
            guard !body.isEmpty else { return nil }
            guard (try? NSRegularExpression(pattern: body)) != nil else { return nil }
            return raw
        }

        let separators = CharacterSet(charactersIn: ",，、|\n")
        let pieces = raw.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !pieces.isEmpty else { return nil }
        guard pieces.allSatisfy({ $0.count >= 2 }) else { return nil }
        return pieces.joined(separator: "|")
    }

    /// Counts items whose scope (`span.domain ?? span.appBundleID`) matches
    /// `scopeKey` (empty = global, matches everything) and whose title
    /// matches `pattern` via `Classifier.titleMatches` -- used for the
    /// editor's live "影响 N 项" preview and the Rules pane's today-hit
    /// column.
    nonisolated static func affected(items: [CategorizedSpan], pattern: String, scopeKey: String) -> (count: Int, seconds: TimeInterval) {
        var count = 0
        var seconds: TimeInterval = 0
        for item in items {
            let itemScope = item.span.domain ?? item.span.appBundleID
            guard Classifier.scopeMatches(ruleScopeKey: scopeKey, scopeKey: itemScope) else { continue }
            guard let title = item.span.title, Classifier.titleMatches(pattern: pattern, title: title) else { continue }
            count += 1
            seconds += item.span.duration
        }
        return (count, seconds)
    }
}

/// Sheet for creating/editing a user title rule: a keyword field (normalized
/// via `TitleRuleInput.normalizedPattern`), a scope picker, a category
/// picker, and a live "影响 N 项" preview computed from `model.rangedSpans()`.
/// Saving calls `upsertUserTitleRule` -> `resolver.refresh()` ->
/// `model.dataChanged()`, matching `ActivityRowView.reassign`'s write-path
/// shape.
struct TitleRuleEditor: View {
    let model: AppModel
    let pending: PendingTitleRule

    @Environment(\.dismiss) private var dismiss

    @State private var keywordText: String
    @State private var scopeKey: String
    @State private var categoryID: String
    @State private var duplicateMessage: String?

    init(model: AppModel, pending: PendingTitleRule) {
        self.model = model
        self.pending = pending
        _keywordText = State(initialValue: pending.prefill)
        _scopeKey = State(initialValue: pending.scopeKey)
        _categoryID = State(initialValue: pending.categoryID)
    }

    private var sortedCategories: [Category] {
        model.resolver.categoriesByID.values.sorted { $0.sortOrder < $1.sortOrder }
    }

    private var normalizedPattern: String? {
        TitleRuleInput.normalizedPattern(keywordText)
    }

    private var affectedPreview: (count: Int, seconds: TimeInterval) {
        guard let pattern = normalizedPattern else { return (0, 0) }
        return TitleRuleInput.affected(items: model.rangedSpans(), pattern: pattern, scopeKey: scopeKey)
    }

    var body: some View {
        Form {
            Section {
                TextField("关键词", text: $keywordText)
                    .onChange(of: keywordText) { _, _ in duplicateMessage = nil }
                Text("多个关键词用逗号分隔；`re:` 前缀为正则")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // The scoped option only makes sense when `pending` actually
                // carries a scope (the right-click path); the "+ 新建标题
                // 规则…" path starts with an empty scopeKey/scopeLabel, which
                // would otherwise duplicate the "所有活动" option's "" tag.
                Picker("范围", selection: $scopeKey) {
                    if !pending.scopeKey.isEmpty {
                        Text("仅 \(pending.scopeLabel)").tag(pending.scopeKey)
                    }
                    Text("所有活动").tag("")
                }
                .pickerStyle(.radioGroup)

                Picker("分类", selection: $categoryID) {
                    ForEach(sortedCategories, id: \.id) { category in
                        Text(category.name).tag(category.id)
                    }
                }
            }

            Section {
                let preview = affectedPreview
                Text("将影响当前范围内 \(preview.count) 项 · \(Format.duration(preview.seconds))")
                    .foregroundStyle(.secondary)
                if let duplicateMessage {
                    Text(duplicateMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("取消") { dismiss() }
                    Button("保存") { save() }
                        .disabled(normalizedPattern == nil)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 360)
        .padding()
    }

    /// Pre-checks for a builtin collision (`upsertUserTitleRule` silently
    /// no-ops in that case -- see its doc comment) before writing, so the
    /// user gets an explicit message instead of a save that appears to
    /// succeed but changed nothing.
    private func save() {
        guard let pattern = normalizedPattern else { return }
        let collidesWithBuiltin = (try? model.categoryStore.titleRules())?.contains {
            $0.source == "builtin"
                && $0.scopeKey == scopeKey
                && $0.pattern.caseInsensitiveCompare(pattern) == .orderedSame
        } ?? false
        guard !collidesWithBuiltin else {
            duplicateMessage = "与内置规则重复，可在规则面板中启用/停用该内置规则"
            return
        }

        do {
            try model.categoryStore.upsertUserTitleRule(pattern: pattern, scopeKey: scopeKey, categoryID: categoryID)
            model.resolver.refresh()
            model.dataChanged()
            dismiss()
        } catch {
            titleRuleEditorLogger.error("upsertUserTitleRule failed for \(pattern, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
