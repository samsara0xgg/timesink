import SwiftUI

/// Rules for the category editor that do not depend on the view.
enum CategoryEditing {
    /// Why a category cannot be added now, or nil when it can.
    static func addBlocker(assignableCount: Int) -> String? {
        assignableCount >= CategoryStore.maxCategories
            ? String(localized: "最多 \(CategoryStore.maxCategories) 个分类，先合并或删除一个。") : nil
    }

    /// A name is usable when it is not blank and no other category has it.
    static func nameIsValid(_ name: String, among categories: [Category], excluding id: String?) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !categories.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static func errorText(_ error: Error) -> String {
        switch error as? CategoryStore.CategoryError {
        case .limitReached: return String(localized: "最多 \(CategoryStore.maxCategories) 个分类，先合并或删除一个。")
        case .notFound: return String(localized: "找不到这个分类。")
        case .cannotRemove: return String(localized: "未分类不能删除。")
        case .sameCategory: return String(localized: "请选择另一个分类。")
        case nil: return error.localizedDescription
        }
    }
}

/// Adds a category (`category == nil`) or edits one: name, colour,
/// description, 投入程度, 分心 flag; merges it into another or deletes it,
/// moving what was in it to a category the user picks.
struct CategoryEditSheet: View {
    let model: AppModel
    let category: Category?
    let done: () -> Void

    @State private var name = ""
    @State private var color = Color.gray
    @State private var details = ""
    @State private var productivity = 0
    @State private var distracting = false
    @State private var all: [Category] = []
    @State private var target = ""
    @State private var confirmingRemoval = false
    @State private var error: String?

    private var others: [Category] { all.filter { $0.id != category?.id } }
    private var canSave: Bool { CategoryEditing.nameIsValid(name, among: all, excluding: category?.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(category == nil ? "新建分类" : "编辑分类").font(.figure)
            HStack(spacing: 10) {
                ColorPicker("颜色", selection: $color, supportsOpacity: false).labelsHidden()
                TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("说明：什么内容属于这里", text: $details, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                Text("说明会和名称一起发给 Jev，写得越具体，判断越准。").font(.note).foregroundStyle(Design.ink2)
            }
            Picker("投入程度", selection: $productivity) {
                ForEach((-2...2).reversed(), id: \.self) { Text($0 > 0 ? "+\($0)" : "\($0)").tag($0) }
            }.pickerStyle(.segmented)
            Toggle("会打断工作（计入分心）", isOn: $distracting)
            if let category, !confirmingRemoval { removal(for: category) }
            if confirmingRemoval, let category { removalConfirm(for: category) }
            if let error { Text(error).font(.body).foregroundStyle(Design.alert) }
            HStack {
                Spacer()
                Button("取消", action: done).keyboardShortcut(.cancelAction)
                Button(category == nil ? "添加" : "保存", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(24).frame(width: 440)
        .onAppear(perform: load)
    }

    private func removal(for category: Category) -> some View {
        HStack {
            Menu("合并到…") {
                ForEach(others, id: \.id) { other in Button(other.name) { remove(category, into: other.id) } }
            }.fixedSize()
            Spacer()
            Button("删除…", role: .destructive) { confirmingRemoval = true }
        }
    }

    private func removalConfirm(for category: Category) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("它的内容改归到", selection: $target) {
                ForEach(others, id: \.id) { Text($0.name).tag($0.id) }
            }
            Text("规则、已确认的判断、限额和专注拦截都会一起移过去。这一步不能撤销。").font(.note).foregroundStyle(Design.ink2)
            HStack {
                Button("不删了") { confirmingRemoval = false }
                Button("删除「\(category.name)」", role: .destructive) { remove(category, into: target) }.disabled(target.isEmpty)
            }
        }
        .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func load() {
        all = ((try? model.categoryStore.allCategories()) ?? []).filter { $0.id != "uncategorized" }
        // Uncategorized is a fair home for what a deleted category held.
        if let uncategorized = (try? model.categoryStore.allCategories())?.first(where: { $0.id == "uncategorized" }) { all.append(uncategorized) }
        target = others.first?.id ?? ""
        guard let category else { color = Color(hex: "#5E8CF0"); return }
        name = category.name; color = Color(hex: category.colorHex); details = category.description
        productivity = category.productivity; distracting = category.distracting
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = "#" + color.toHex()
        do {
            if var edited = category {
                edited.name = name; edited.colorHex = hex; edited.description = details
                edited.productivity = productivity; edited.distracting = distracting
                try model.categoryStore.updateCategory(edited)
            } else {
                try model.categoryStore.addCategory(name: name, colorHex: hex, description: details,
                                                    productivity: productivity, distracting: distracting)
            }
            changed()
        } catch { self.error = CategoryEditing.errorText(error) }
    }

    private func remove(_ category: Category, into id: String) {
        do {
            try model.categoryStore.mergeCategory(category.id, into: id, settings: model.settings)
            changed()
        } catch { self.error = CategoryEditing.errorText(error) }
    }

    /// Every category edit changes what Jev is asked, and a merge or delete
    /// changes what spans resolve to.
    private func changed() {
        model.resolver.refresh()
        model.jev?.nudge()
        model.dataChanged()
        done()
    }
}

extension Category: Identifiable {}
