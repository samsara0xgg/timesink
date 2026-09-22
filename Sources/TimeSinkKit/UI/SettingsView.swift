import SwiftUI

/// Settings window: six tabs — 通用 (idle threshold, login item, permission
/// status), 分类 (edit the 12 taxonomy categories), 规则 (URL and title
/// classification rules, switched via a segmented picker), 未分类
/// (last-30-days spans still resolving to "uncategorized"), 智能分类
/// (optional OpenAI-compatible LLM classification fallback), 预算 (category
/// daily budgets, warn threshold, daily summary, focus-block lists). Opens
/// via ⌘, from the main window or the menu bar's SettingsLink (`TimeSinkApp`'s
/// `Settings` scene). `@Bindable model` so `TabView(selection:)` can bind
/// directly to `model.settingsTab` — notification routing
/// (`.settingsBudget`) jumps this from outside the view.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettingsPane(model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            CategoriesSettingsPane(model: model)
                .tabItem { Label("分类", systemImage: "tag") }
                .tag(SettingsTab.categories)
            RulesSettingsPane(model: model)
                .tabItem { Label("规则", systemImage: "list.bullet.rectangle") }
                .tag(SettingsTab.rules)
            UncategorizedSettingsPane(model: model)
                .tabItem { Label("未分类", systemImage: "questionmark.circle") }
                .tag(SettingsTab.uncategorized)
            LLMSettingsPane(model: model)
                .tabItem { Label("智能分类", systemImage: "sparkles") }
                .tag(SettingsTab.llm)
            BudgetSettingsPane(model: model)
                .tabItem { Label("预算", systemImage: "chart.pie") }
                .tag(SettingsTab.budget)
            AccountSettingsPane(model: model)
                .tabItem { Label("账号", systemImage: "person.crop.circle") }
                .tag(SettingsTab.account)
        }
        .frame(width: 560, height: 420)
    }
}
