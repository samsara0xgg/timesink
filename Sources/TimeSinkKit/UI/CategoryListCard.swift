import SwiftUI

/// 分类: every category with its 投入程度 (-2 to +2) and the last seven days'
/// time. A click picks the category for the rules table beside it.
struct CategoryListCard: View {
    let model: AppModel
    let seconds: [String: TimeInterval]
    @Binding var selected: String?
    @State private var categories: [Category] = []
    @State private var ruleCounts: [String: Int] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeading(title: "分类", caption: Text("点一个只看它的规则"))
            HStack(spacing: 10) {
                Spacer()
                Text("投入程度").frame(width: 92, alignment: .center)
                Text("近 7 天").frame(width: 56, alignment: .trailing)
            }.font(.system(size: 11)).foregroundStyle(Design.ink3).padding(.horizontal, 8).padding(.top, 4)
            ScrollView {
                VStack(spacing: 2) { ForEach(categories, id: \.id) { row($0) } }
            }.scrollIndicators(.never)
            Text("投入程度 +1 以上的算投入。今天页的投入时间、趋势页的评分都按这个算，改了会一起变。")
                .font(.system(size: 11)).foregroundStyle(Design.ink3).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
        }
        .padding(.horizontal, Design.Space.xl).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .designCard()
        .task { load() }
        .onPageChange(of: model.dataEditVersion) { load() }
    }

    private func row(_ category: Category) -> some View {
        let on = selected == category.id
        let color = RefinedStyle.category(category.id, hex: category.colorHex)
        return HStack(spacing: 10) {
            Button {
                withAnimation(Design.motion(Design.settle, reduced: reduceMotion)) { selected = on ? nil : category.id }
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 9, height: 9)
                    Text(category.name).font(.system(size: 13, weight: on ? .bold : .regular)).lineLimit(1)
                    Text(ruleCounts[category.id, default: 0] > 0 ? "\(ruleCounts[category.id, default: 0])" : "")
                        .font(.num(11)).foregroundStyle(Design.ink3)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            scale(category, color: color)
            Text(seconds[category.id].map { Format.duration($0) } ?? "—").font(.num(12)).foregroundStyle(Design.ink2)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Design.rowHover : .clear))
    }

    /// Five steps, -2 to +2: filled up to the chosen one. +1 and above count as focus.
    private func scale(_ category: Category, color: Color) -> some View {
        HStack(spacing: 3) {
            ForEach(-2...2, id: \.self) { level in
                Button { set(category, level) } label: {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(level <= category.productivity ? color : Design.track)
                        .frame(width: 14, height: 8 + CGFloat(level + 2) * 2)
                        .frame(height: 16, alignment: .bottom).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .frame(width: 92)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(category.name)的投入程度"))
        .accessibilityValue(Text(category.productivity > 0 ? "+\(category.productivity)" : "\(category.productivity)"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(category, min(2, category.productivity + 1))
            case .decrement: set(category, max(-2, category.productivity - 1))
            @unknown default: break
            }
        }
        .help(Self.label(category.productivity))
    }

    private func set(_ category: Category, _ level: Int) {
        guard level != category.productivity, let index = categories.firstIndex(where: { $0.id == category.id }) else { return }
        var updated = category
        updated.productivity = level
        do {
            try model.categoryStore.updateCategory(updated)
            withAnimation(Design.motion(Design.press, reduced: reduceMotion)) { categories[index] = updated }
            // The same two calls the settings pane makes: no classification
            // depends on productivity, so no memo is dropped.
            model.resolver.refreshCategories()
            model.categoryMetadataChanged()
        } catch {}
    }

    private static func label(_ level: Int) -> String {
        switch level {
        case -2: return String(localized: "非常分心")
        case -1: return String(localized: "分心")
        case 0: return String(localized: "中性")
        case 1: return String(localized: "投入")
        default: return String(localized: "非常投入")
        }
    }

    private func load() {
        categories = ((try? model.categoryStore.allCategories()) ?? []).filter { $0.id != "uncategorized" }.sorted { $0.sortOrder < $1.sortOrder }
        var counts: [String: Int] = [:]
        for rule in (try? model.categoryStore.titleRules()) ?? [] { counts[rule.categoryID, default: 0] += 1 }
        for rule in (try? model.categoryStore.urlRules()) ?? [] { counts[rule.categoryID, default: 0] += 1 }
        for entry in ((try? model.categoryStore.domainMap()) ?? [:]).values where entry.source == "user" { counts[entry.categoryID, default: 0] += 1 }
        for entry in ((try? model.categoryStore.appMap()) ?? [:]).values where entry.source == "user" { counts[entry.categoryID, default: 0] += 1 }
        ruleCounts = counts
    }
}
