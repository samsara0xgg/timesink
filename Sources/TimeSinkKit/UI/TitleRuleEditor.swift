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
    /// Trims `raw` as a whole first (so a stray leading/trailing space never
    /// hides a `re:` prefix from the check below, nor survives into a
    /// keyword's regex body). Then: a `re:` prefix is kept whole -- its body
    /// is separately trimmed, must be >= 2 characters (same floor as a
    /// keyword, and the same rationale: tier-0 has no undo), must compile
    /// via `NSRegularExpression`, and must NOT match the empty string (a
    /// body like `"a?"` or `"|"` matches every title, empty or not -- just
    /// as dangerous as the bare `"re:"` case). Otherwise splits on
    /// 逗号/顿号/竖线/换行, trims each piece, drops empties; any surviving
    /// keyword shorter than 2 characters rejects the whole input; keywords
    /// are then deduped case-insensitively, first occurrence wins (matches
    /// the matcher's own case-insensitive substring semantics, and keeps a
    /// duplicate like "lecture, Lecture" from producing a duplicate chip).
    /// Returns the pattern to store (`|`-joined keywords, or the `re:`
    /// string with its trimmed body), or `nil` if invalid.
    nonisolated static func normalizedPattern(_ raw: String) -> String? {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedRaw.hasPrefix("re:") {
            let body = String(trimmedRaw.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count >= 2,
                  let regex = try? NSRegularExpression(pattern: body, options: [.caseInsensitive]) else { return nil }
            guard regex.firstMatch(in: "", options: [], range: NSRange(location: 0, length: 0)) == nil else { return nil }
            return "re:\(body)"
        }

        let separators = CharacterSet(charactersIn: ",，、|\n")  // l10n: data
        let pieces = trimmedRaw.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !pieces.isEmpty else { return nil }
        guard pieces.allSatisfy({ $0.count >= 2 }) else { return nil }

        var seen = Set<String>()
        var deduped: [String] = []
        for piece in pieces where seen.insert(piece.lowercased()).inserted {
            deduped.append(piece)
        }
        return deduped.joined(separator: "|")
    }

    /// Counts items whose scope (`span.domain ?? span.appBundleID`) matches
    /// `scopeKey` (empty = global, matches everything) and whose title
    /// matches `pattern` -- used for the editor's live "影响 N 项" preview
    /// (recomputed on every keystroke) and the Rules pane's today-hit
    /// column. Builds one `CompiledTitleRule` up front and reuses it across
    /// every item instead of calling the uncompiled `Classifier.titleMatches`
    /// per item, which re-splits `|`-keywords (and, for a `re:` pattern,
    /// recompiles the `NSRegularExpression`) on every single call --
    /// measured 302ms/50k for keywords and 114ms/50k for regex recompilation
    /// alone (matches `ClassificationContext`'s own precompilation
    /// rationale, see its doc comment).
    nonisolated static func affected(items: [CategorizedSpan], pattern: String, scopeKey: String) -> (count: Int, seconds: TimeInterval) {
        let compiled = CompiledTitleRule(TitleRule(pattern: pattern, scopeKey: scopeKey, categoryID: "", source: "user"))
        var count = 0
        var seconds: TimeInterval = 0
        for item in items {
            let itemScope = item.span.domain ?? item.span.appBundleID
            guard Classifier.scopeMatches(ruleScopeKey: scopeKey, scopeKey: itemScope) else { continue }
            guard let title = item.span.title else { continue }
            guard compiled.matches(title: title, loweredTitle: title.lowercased()) else { continue }
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

    /// "影响 N 项", recomputed behind `pendingPreview` rather than read
    /// straight out of `body`. As a computed property this scanned every span
    /// in the current range on every keystroke, since each character
    /// re-evaluates `body` -- measured at 53-62 ms per pass, which is exactly
    /// the visible per-character stutter when the range is 本月 or 近30天.
    @State private var affectedPreview: (count: Int, seconds: TimeInterval) = (0, 0)
    @State private var pendingPreview: Task<Void, Never>?

    /// Long enough to swallow a burst of typing, short enough that the count
    /// still feels attached to the field. Same trailing-debounce shape as
    /// `CategoryEditRow.scheduleDebouncedRefresh` and `ActivitiesView`'s
    /// search recompute.
    private static let previewDebounce: Duration = .milliseconds(250)

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

    /// The keyword chips `normalizedPattern` would actually store, shown
    /// live under the field so a title that splits into several broad
    /// keywords (e.g. right-click-prefilled "React Docs | Next.js" ->
    /// "React Docs"/"Next.js") is visible before Save rather than a
    /// surprise afterward. A `re:` pattern renders as one chip; invalid
    /// input renders none (matching the disabled Save button).
    private var previewChips: [String] {
        guard let pattern = normalizedPattern else { return [] }
        return pattern.hasPrefix("re:") ? [pattern] : pattern.split(separator: "|").map(String.init)
    }

    /// Restarts the trailing debounce; the scan itself runs once the user
    /// stops. Cancelling first means a burst of keystrokes costs one pass,
    /// not one per character.
    private func schedulePreview() {
        pendingPreview?.cancel()
        pendingPreview = Task { @MainActor in
            try? await Task.sleep(for: Self.previewDebounce)
            guard !Task.isCancelled else { return }
            recomputePreview()
        }
    }

    private func recomputePreview() {
        guard let pattern = normalizedPattern else {
            affectedPreview = (0, 0)
            return
        }
        affectedPreview = TitleRuleInput.affected(
            items: model.rangedSpans(), pattern: pattern, scopeKey: scopeKey)
    }

    var body: some View {
        Form {
            Section {
                TextField("关键词", text: $keywordText)
                    .onChange(of: keywordText) { _, _ in
                        duplicateMessage = nil
                        schedulePreview()
                    }
                Text("多个关键词用逗号分隔；`re:` 前缀为正则")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !previewChips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(previewChips, id: \.self) { chip in
                                Text(chip)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            }
                        }
                    }
                }
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
                .onChange(of: scopeKey) { _, _ in
                    duplicateMessage = nil
                    // A single discrete choice, not a keystroke stream: run it
                    // straight away so the count does not lag a click.
                    pendingPreview?.cancel()
                    recomputePreview()
                }

                Picker("分类", selection: $categoryID) {
                    ForEach(sortedCategories, id: \.id) { category in
                        Text(category.name).tag(category.id)
                    }
                }
                .onChange(of: categoryID) { _, _ in duplicateMessage = nil }
            }

            Section {
                Text("将影响当前范围内 \(affectedPreview.count) 项 · \(Format.duration(affectedPreview.seconds))")
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
        // The right-click path opens with `pending.prefill` already in the
        // field, so the count has to be right before the first keystroke.
        .onAppear { recomputePreview() }
        .onDisappear { pendingPreview?.cancel() }
    }

    /// Pre-checks for a builtin collision (`upsertUserTitleRule` silently
    /// no-ops in that case -- see its doc comment) before writing, so the
    /// user gets an explicit message instead of a save that appears to
    /// succeed but changed nothing. The pre-check read itself is treated as
    /// fail-closed: if `titleRules()` throws, we cannot tell whether a
    /// collision exists, so the save is blocked (not silently allowed to
    /// proceed into the no-op) and the sheet stays open with a message.
    private func save() {
        guard let pattern = normalizedPattern else { return }

        let existingRules: [TitleRule]
        do {
            existingRules = try model.categoryStore.titleRules()
        } catch {
            duplicateMessage = String(localized: "无法校验是否与内置规则冲突，请重试")
            titleRuleEditorLogger.error("titleRules() failed before save: \(String(describing: error), privacy: .public)")
            return
        }

        let collidesWithBuiltin = existingRules.contains {
            $0.source == "builtin"
                && $0.scopeKey == scopeKey
                && $0.pattern.caseInsensitiveCompare(pattern) == .orderedSame
        }
        guard !collidesWithBuiltin else {
            duplicateMessage = String(localized: "与内置规则重复，可在规则面板中启用/停用该内置规则")
            return
        }

        do {
            try model.categoryStore.upsertUserTitleRule(pattern: pattern, scopeKey: scopeKey, categoryID: categoryID)
            model.resolver.refresh()
            model.dataChanged()
            dismiss()
        } catch {
            duplicateMessage = String(localized: "保存失败，请重试")
            titleRuleEditorLogger.error("upsertUserTitleRule failed for \(pattern, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
