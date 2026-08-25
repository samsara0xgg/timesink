# TimeSink P1 第二批 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付交互稿定义的第二批六块：B1 标题规则、C2 统计 2.0、C3 活动 2.0、C4 预算/提醒/专注、菜单栏时间文本、C1+ 仪表盘 hover 下钻与点击深入。

**Architecture:** 聚焦组件 + 最小基础设施（spec 方案二）：新增 Notifier / BudgetEngine+BudgetMonitor / FocusSessionController / PanelHost / CalendarStore / EntityParser 六个组件与一次 v4 迁移，其余直挂现有 AppModel/视图。分类仍为读时计算，`AppModel.rangedSpans` 仍是唯一取数漏斗；span 表 schema 与索引全批冻结。

**Tech Stack:** Swift 6（strict concurrency）+ SwiftUI + GRDB 7 + Swift Charts + EventKit + UserNotifications + ScriptingBridge。XCTest。零新第三方依赖。

**Spec:** `docs/superpowers/specs/2026-08-24-timesink-p1-batch2-design.md`（本 plan 从它论证；执行者两者都要读）。交互验收 normative 来源：「TimeSink 交互稿」Artifact `https://claude.ai/code/artifact/ef355ee7-6a7b-471e-92c4-aca063f6a45e` 的「交互总表」。

## Global Constraints

- 基线 main @ `4044955`（含 p0-batch1，75/75 测试绿；执行前以 `swift test` 实测为准）。
- Swift 6 strict concurrency；最低 macOS 14；唯一第三方依赖 GRDB（新增系统框架仅 EventKit / UserNotifications）。
- **span 表 schema 与索引冻结**：任何改动 span 表或 `SpanStore.overlapSQL` 的方案都是错的；`DatabaseTests.testOverlapQueryPlanUsesEndIndex` 与 `testV3IndexesEndAndDropsUnusedIndexes` 必须原样通过。
- `swift test` / `swift run` 全程**绝不可触碰** `UNUserNotificationCenter.current()` 或 EventKit 授权调用：无 bundle 进程会抛不可捕获的 ObjC 异常（实测）。门控条件一律 `Bundle.main.bundleIdentifier == "com.alllllenshi.TimeSink"`。
- 显式用户操作直接 `model.dataChanged()`，绝不走 1.5s 引擎防抖（AppModel.swift:110-118 的纪律）。搜索、专注倒计时**不得**触发 `dataChanged()`。
- 测试惯例：XCTest；共享 `ts()` / `sample()` 助手在 `SpanBuilderTests.swift:4-9`（复用，勿重定义）；DB fixture 一律 `AppDatabase.openInMemory()`；纯逻辑写成 `nonisolated static` internal（不能 `private`，`@testable` 看不见 private）。
- UI 文案中文、无 emoji；沿用系统标准动画；新权限一律可选，不进 `OnboardingView.canFinish`。
- 每个 Task 结束：`swift build && swift test` 全绿再 commit；commit message 遵循现有 `feat:`/`fix:`/`docs:` 风格。

## 执行模式

与 p0-batch1 相同：单 worktree（执行时经 superpowers:using-git-worktrees 创建，分支名 `p1-batch2`），**顺序**子代理逐 Task 实现，每个 Task 完成后跑 Ultracode 对抗验证（多 agent 审查该 Task diff，Important 及以上发现修完才进下一个 Task）；全部 Task 完成后做全分支终审 + 修复波，然后（用户确认后）合并 main、`make install`、生产库冒烟。

## 文件结构总览

新建：
- `Sources/TimeSinkKit/Core/Notifier.swift` — Notifying 协议 + SystemNotifier/NoopNotifier + NotificationRoute
- `Sources/TimeSinkKit/Core/BudgetStore.swift` / `FocusSessionStore.swift` — v4 新表的 store
- `Sources/TimeSinkKit/Core/EntityParser.swift` — 展示层实体解析（纯函数）
- `Sources/TimeSinkKit/Stats/BudgetEngine.swift` — 预算等级纯函数 + BudgetMonitor 评估壳
- `Sources/TimeSinkKit/Tracking/CalendarStore.swift` — EventKit actor + CalendarEvent 值类型
- `Sources/TimeSinkKit/Tracking/FocusSessionController.swift` — 专注状态机 + 拦截逻辑
- `Sources/TimeSinkKit/Tracking/ChromeBlocker.swift` — Chrome 标签重定向（独立 SBApplication）
- `Sources/TimeSinkKit/UI/PermissionRow.swift` — 共享权限行视图
- `Sources/TimeSinkKit/UI/TitleRuleEditor.swift` — B1 规则创建/编辑 sheet
- `Sources/TimeSinkKit/UI/BudgetSettingsPane.swift` — 设置·预算 pane
- `Sources/TimeSinkKit/UI/FocusViews.swift` — 弹出层专注配置/进行态 + HUD 内容
- `Sources/TimeSinkKit/UI/PanelHost.swift` — hover 下钻 NSPanel 宿主
- `Sources/TimeSinkKit/UI/DrillDownViews.swift` — 七个下钻子窗内容视图
- 测试新文件：`TitleRuleTests.swift`、`StatsRangeTests.swift`、`EntityParserTests.swift`、`CalendarMeetingTests.swift`、`BudgetTests.swift`、`FocusSessionTests.swift`

修改（职责见各 Task）：Permissions.swift、OnboardingView.swift、SettingsPanes.swift、SettingsView.swift、AppDatabase.swift、Records.swift、CategoryStore.swift、SettingsStore.swift、Classifier.swift、CategoryResolver.swift、ActivityListView.swift、ActivitiesView.swift、TimelineView.swift、DateRangeSelection.swift、MainWindow.swift、AppModel.swift、Aggregator.swift、Format.swift、StatsModel.swift、StatsView.swift、Cards.swift、MenuBarDashboard.swift、TrackerEngine.swift、TimeSinkApp.swift、packaging/Info.plist、Package.swift。

---

### Task 1: Permissions 重构（PermissionState + 共享 PermissionRow）

先行任务：后续日历/通知权限都挂在这套形状上，先把两份手写三态 UI 收敛。

**Files:**
- Modify: `Sources/TimeSinkKit/Tracking/Permissions.swift`
- Create: `Sources/TimeSinkKit/UI/PermissionRow.swift`
- Modify: `Sources/TimeSinkKit/UI/SettingsPanes.swift`（GeneralSettingsPane 权限区）
- Modify: `Sources/TimeSinkKit/UI/OnboardingView.swift`
- Test: `Tests/TimeSinkKitTests/PermissionStateTests.swift`（新建）

**Interfaces:**
- Produces: `public enum PermissionState: Equatable, Sendable { case granted, denied, notDetermined, unavailable(String) }`；`Permissions.chromeState(from: OSStatus) -> PermissionState`（nonisolated static 纯函数）；`Permissions.accessibilityState(prompt:) -> PermissionState`、`Permissions.chromeAutomationState(ask:) -> PermissionState`；视图 `PermissionRow(title:explanation:state:actionTitle:action:)`（explanation 可 nil，行内紧凑形态供设置页用）。
- 现有 `accessibilityGranted(prompt:)` / `chromeAutomationStatus(ask:)` **保留不动**（TrackerEngine.swift:314 调用后者）。

- [ ] **Step 1: 写失败测试**（纯映射，无需 MainActor）

```swift
import XCTest
@testable import TimeSinkKit

final class PermissionStateTests: XCTestCase {
    func testChromeStateMapping() {
        XCTAssertEqual(Permissions.chromeState(from: 0), .granted)          // noErr
        XCTAssertEqual(Permissions.chromeState(from: -600),
                       .unavailable("Chrome 未运行"))                        // procNotFound
        XCTAssertEqual(Permissions.chromeState(from: -1743), .denied)       // errAEEventNotPermitted
        XCTAssertEqual(Permissions.chromeState(from: -1744), .notDetermined) // errAEEventWouldRequireUserConsent
    }
}
```

- [ ] **Step 2: 跑测试确认编译失败**（`swift test --filter PermissionStateTests`，期望 `chromeState` 未定义）

- [ ] **Step 3: 实现**。`Permissions.swift` 加：

```swift
public enum PermissionState: Equatable, Sendable {
    case granted, denied, notDetermined
    case unavailable(String)
}

extension Permissions {
    /// 纯映射，可测：AEDeterminePermissionToAutomateTarget 的 OSStatus → 状态。
    /// -1744 = errAEEventWouldRequireUserConsent（从未询问过）。
    public nonisolated static func chromeState(from status: OSStatus) -> PermissionState {
        switch status {
        case noErr: return .granted
        case -600: return .unavailable("Chrome 未运行")
        case -1744: return .notDetermined
        default: return .denied
        }
    }

    @MainActor public static func accessibilityState(prompt: Bool) -> PermissionState {
        accessibilityGranted(prompt: prompt) ? .granted : .denied
    }
    @MainActor public static func chromeAutomationState(ask: Bool) -> PermissionState {
        chromeState(from: chromeAutomationStatus(ask: ask))
    }
}
```

`PermissionRow.swift`：一个视图两种形态——`compact == true`（设置页行：圆点 + 名 + 状态字 + 按钮，对照现有 `accessibilityRow` 的布局）与 `compact == false`（Onboarding 卡片：加说明文字与圆角底，对照现有 `PermissionCard`）。状态渲染统一：granted→绿/"已授权"、denied→红/"未授权"、notDetermined→红/"未授权"、unavailable(msg)→灰/msg。按钮在 granted 时 disabled。

```swift
struct PermissionRow: View {
    let title: String
    var explanation: String? = nil
    let state: PermissionState
    var actionTitle = "去授权"
    let action: () -> Void
    var compact = true
    // body: compact ? 单行 HStack : 卡片 VStack；圆点/状态色由 state 派生
}
```

- [ ] **Step 4: 替换两处手写块**。`GeneralSettingsPane`：`@State accessibilityGranted/chromeStatus` 改为 `@State axState: PermissionState = .denied` / `chromeState: PermissionState = .notDetermined`，`accessibilityRow`/`chromeRow`/`chromeStatusText`/`chromeStatusColor` 四个成员删除，权限 Section 变两个 `PermissionRow`（动作闭包保留原打开系统设置 URL / `ask: true` 逻辑）。`OnboardingView`：`PermissionCard` 结构体删除，两张卡换 `PermissionRow(compact: false)`；`canFinish` 语义不变：`axState == .granted && (chromeState == .granted || chromeState == .unavailable("Chrome 未运行"))` —— 为避免字符串比较，给 `PermissionState` 加 `var isUnavailable: Bool`。2s 轮询逻辑保留。

- [ ] **Step 5: 全量测试 + 提交**。`swift test` 全绿（75+1）。`git commit -m "refactor: unify permission status into PermissionState + shared PermissionRow"`

### Task 2: Notifier 协议与系统通知接线

**Files:**
- Create: `Sources/TimeSinkKit/Core/Notifier.swift`
- Modify: `Sources/TimeSinkKit/App/TimeSinkApp.swift`（delegate）
- Test: `Tests/TimeSinkKitTests/NotifierTests.swift`（新建，只测 Noop/Spy 与 route 编码）

**Interfaces:**
- Produces:

```swift
public enum NotificationRoute: String, Sendable {
    case settingsBudget   // 预算通知 → 设置·预算
    case statsToday       // 每日小结 → 统计·今天
    case activitiesToday  // 专注结束 → 活动·今天
}

@MainActor
public protocol Notifying: AnyObject {
    func requestAuthorization() async -> Bool
    func authorizationState() async -> PermissionState
    /// id 用于同类覆盖（如 "budget.entertainment"）；route 编入 userInfo["route"]。
    func post(id: String, title: String, body: String, route: NotificationRoute?)
}
```

- `SystemNotifier`（真实现）与 `NoopNotifier`（无 bundle 环境 / 测试）。工厂：`NotifierFactory.make() -> any Notifying`，按 `Bundle.main.bundleIdentifier == "com.alllllenshi.TimeSink"` 选择——这是崩溃门，不是风格。
- `TimeSinkAppDelegate` 新增：`applicationDidFinishLaunching` 里（同 bundle 门控）设 `UNUserNotificationCenter.current().delegate = self`；`willPresent` 返回 `[.banner, .list]`（app 前台也出横幅）；`didReceive` 解析 `userInfo["route"]` 调 `onRoute?(route)`（`var onRoute: ((NotificationRoute) -> Void)?`，Task 11 接线）。
- Consumes: Task 1 的 `PermissionState`。

- [ ] **Step 1: 失败测试**——`NoopNotifier` 永远拒绝且不崩；`SpyNotifier`（测试文件内定义，后续 BudgetTests 复用，故放测试 target 顶层）记录 post 调用：

```swift
import XCTest
@testable import TimeSinkKit

@MainActor
final class SpyNotifier: Notifying {
    var authorized = true
    var posted: [(id: String, title: String, body: String, route: NotificationRoute?)] = []
    func requestAuthorization() async -> Bool { authorized }
    func authorizationState() async -> PermissionState { authorized ? .granted : .denied }
    func post(id: String, title: String, body: String, route: NotificationRoute?) {
        posted.append((id, title, body, route))
    }
}

final class NotifierTests: XCTestCase {
    @MainActor func testNoopNeverAuthorizes() async {
        let n = NoopNotifier()
        let ok = await n.requestAuthorization()
        XCTAssertFalse(ok)
        let state = await n.authorizationState()
        XCTAssertEqual(state, .denied)
        n.post(id: "x", title: "t", body: "b", route: nil)  // 不崩即通过
    }
    @MainActor func testFactoryReturnsNoopWithoutBundle() {
        // swift test 无 bundle id，必须拿到 Noop——这是整条崩溃门的回归测试
        XCTAssertTrue(NotifierFactory.make() is NoopNotifier)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**，然后实现 `Notifier.swift`。`SystemNotifier` 关键点：**不在存储属性初始化里碰 `UNUserNotificationCenter.current()`**（惰性在方法体内取）；`requestAuthorization` 用 `options: [.alert, .sound]`；`post` 构造 `UNMutableNotificationContent`（title/body/userInfo `["route": route.rawValue]`），`UNNotificationRequest(identifier: id, content: content, trigger: nil)`，错误只 `Logger` 记录。`import UserNotifications` 只出现在这个文件。

- [ ] **Step 3: delegate 接线**。`TimeSinkAppDelegate` 改为继承 `NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate`；`applicationDidFinishLaunching(_:)` 内 `guard Bundle.main.bundleIdentifier == "com.alllllenshi.TimeSink" else { return }` 再设 delegate。delegate 回调不在主线程——用 `MainActor.assumeIsolated` 之前必须先 hop：实现为 nonisolated 方法内 `Task { @MainActor in self.onRoute?(route) }`。

- [ ] **Step 4: 全量测试 + 提交**。`git commit -m "feat: Notifying protocol with bundle-gated SystemNotifier and notification routing"`

### Task 3: 迁移 v4 + 新记录与 store

**Files:**
- Modify: `Sources/TimeSinkKit/Core/AppDatabase.swift`（v3 块后注册 v4）
- Modify: `Sources/TimeSinkKit/Core/Records.swift`（TitleRule / Budget / FocusSession / BudgetAlertRow）
- Modify: `Sources/TimeSinkKit/Core/CategoryStore.swift`（titleRule CRUD）
- Create: `Sources/TimeSinkKit/Core/BudgetStore.swift`、`Sources/TimeSinkKit/Core/FocusSessionStore.swift`
- Modify: `Sources/TimeSinkKit/Core/SettingsStore.swift`（新标量键）
- Modify: `Sources/TimeSinkKit/Categorization/Taxonomy.swift`（内置标题种子数组）
- Test: `Tests/TimeSinkKitTests/DatabaseTests.swift` 追加 + `Tests/TimeSinkKitTests/TitleRuleTests.swift`（store 部分）

**Interfaces（后续 Task 依赖的确切签名）:**

```swift
// Records.swift
public struct TitleRule: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "titleRule"
    public var id: Int64?
    public var pattern: String    // 竖线连接关键词组，或整串 "re:" 前缀正则
    public var scopeKey: String   // "" = 全局；否则 domain 或 bundleID（同 span.domain ?? appBundleID）
    public var categoryID: String
    public var priority: Int      // 默认 0；仅同层内 tiebreak
    public var source: String     // "user" | "builtin"
    public var enabled: Bool
    public var createdAt: Date
    public init(id: Int64? = nil, pattern: String, scopeKey: String = "",
                categoryID: String, priority: Int = 0, source: String,
                enabled: Bool = true, createdAt: Date = Date())
}
public struct Budget: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "budget"
    public var categoryID: String
    public var dailySeconds: Int
    public var enabled: Bool
    public init(categoryID: String, dailySeconds: Int, enabled: Bool = true)
}
public struct FocusSession: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "focusSession"
    public var id: Int64?
    public var start: Date
    public var end: Date          // 开始即 = start，随心跳推进
    public var plannedSeconds: Int
    public var appBlocks: Int
    public var siteBlocks: Int
    public var completed: Bool
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// CategoryStore 追加
public func titleRules() throws -> [TitleRule]                       // 全量，含 disabled（设置页用）
public func upsertUserTitleRule(pattern: String, scopeKey: String, categoryID: String) throws
public func deleteTitleRule(id: Int64) throws                        // 仅 user 行调用方保证
public func setTitleRuleEnabled(id: Int64, enabled: Bool) throws

// BudgetStore（public final class BudgetStore: Sendable，init(_ writer: any DatabaseWriter)）
public func budgets() throws -> [Budget]
public func setBudget(categoryID: String, dailySeconds: Int) throws  // upsert，enabled 保持/置 true
public func setEnabled(categoryID: String, enabled: Bool) throws
public func deleteBudget(categoryID: String) throws                  // 连带删该类 budgetAlert 行
public func alertKinds(categoryID: String, day: String) throws -> Set<String>
public func noteAlert(categoryID: String, day: String, kind: String) throws  // INSERT ... DO NOTHING
public func pruneAlerts(before day: String) throws                   // day 字符串比较（同长同格式，字典序=时间序）

// FocusSessionStore（同款类骨架）
@discardableResult public func start(at date: Date, plannedSeconds: Int) throws -> FocusSession
public func heartbeat(id: Int64, end: Date) throws
public func finish(id: Int64, end: Date, appBlocks: Int, siteBlocks: Int, completed: Bool) throws
public func sessions(overlapping interval: DateInterval) throws -> [FocusSession]

// SettingsStore 追加（键名 = 属性名；全部标量字符串，惯例照 llmEnabled 那组）
budgetWarnPercent: Int（默认 20）/ setBudgetWarnPercent
dailySummaryEnabled: Bool（默认 false）/ setDailySummaryEnabled
dailySummaryHour: Int（默认 19）/ setDailySummaryHour
lastSummaryDay: String?（默认 nil）/ setLastSummaryDay
menuBarTextEnabled: Bool（默认 true）/ setMenuBarTextEnabled
focusDurationMinutes: Int（默认 25）/ setFocusDurationMinutes
focusAppBlockEnabled: Bool（默认 true）/ setFocusAppBlockEnabled
focusSiteBlockEnabled: Bool（默认 true）/ setFocusSiteBlockEnabled
focusBlockedApps: [String]（逗号 join/split，默认 []）/ setFocusBlockedApps
focusBlockedCategories: [String]（同上）/ setFocusBlockedCategories
calendarOverlayEnabled: Bool（默认 false）/ setCalendarOverlayEnabled
```

- [ ] **Step 1: 失败测试**（DatabaseTests 追加）：

```swift
func testV4CreatesTablesAndSeedsTitleRules() throws {
    let db = try makeDB()
    let tables = try db.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    for t in ["titleRule", "budget", "budgetAlert", "focusSession"] {
        XCTAssertTrue(tables.contains(t), "missing table \(t)")
    }
    let store = CategoryStore(db)
    let seeds = try store.titleRules()
    XCTAssertEqual(seeds.filter { $0.source == "builtin" }.count, 2)
    XCTAssertTrue(seeds.contains { $0.pattern == "lecture|course|教程|课程|讲座" && $0.categoryID == "learning" })
    XCTAssertTrue(seeds.contains { $0.pattern == "pull request|merge request|PR #" && $0.categoryID == "softwareDev" })
}
func testV4DoesNotTouchSpanIndexes() throws {
    // 与 testV3IndexesEndAndDropsUnusedIndexes 同一组断言，证明 v4 没动 span
    let db = try AppDatabase.openInMemory()
    let names = try db.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'span'")
    }
    XCTAssertTrue(names.contains("span_on_end"))
    XCTAssertTrue(names.contains("span_on_start"))
}
func testUpgradeFromV3PreservesData() throws {
    // 现有测试全测全新库；这是唯一的升级路径测试
    let db = try DatabaseQueue()
    try AppDatabase.migrator.migrate(db, upTo: "v3")
    let spanStore = SpanStore(db)
    let catStore = CategoryStore(db)
    _ = try spanStore.insert(Span(start: ts(0), end: ts(100), appBundleID: "a",
                                  appName: "A", title: "t", url: nil, domain: nil))
    try catStore.addUserURLRule(pattern: "mysite.com", categoryID: "news", priority: 1000)
    try AppDatabase.migrator.migrate(db)  // v3 → v4
    XCTAssertEqual(try spanStore.spans(overlapping: DateInterval(start: ts(0), end: ts(200))).count, 1)
    XCTAssertTrue(try catStore.urlRules().contains { $0.pattern == "mysite.com" })
    XCTAssertEqual(try catStore.titleRules().filter { $0.source == "builtin" }.count, 2)
}
func testBudgetAlertCompositePKAndPrune() throws {
    let db = try makeDB()
    let store = BudgetStore(db)
    try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
    try store.noteAlert(categoryID: "entertainment", day: "2026-08-24", kind: "warn")
    try store.noteAlert(categoryID: "entertainment", day: "2026-08-24", kind: "warn")  // 重复无效
    XCTAssertEqual(try store.alertKinds(categoryID: "entertainment", day: "2026-08-24"), ["warn"])
    try store.noteAlert(categoryID: "entertainment", day: "2026-05-01", kind: "limit")
    try store.pruneAlerts(before: "2026-08-01")
    XCTAssertEqual(try store.alertKinds(categoryID: "entertainment", day: "2026-05-01"), [])
    XCTAssertEqual(try store.alertKinds(categoryID: "entertainment", day: "2026-08-24"), ["warn"])
}
func testFocusSessionLifecycle() throws {
    let db = try makeDB()
    let store = FocusSessionStore(db)
    let s = try store.start(at: ts(0), plannedSeconds: 1500)
    XCTAssertNotNil(s.id)
    XCTAssertEqual(s.end, ts(0))          // 开始即落盘，end = start
    try store.heartbeat(id: s.id!, end: ts(30))
    try store.finish(id: s.id!, end: ts(1500), appBlocks: 1, siteBlocks: 2, completed: true)
    let hits = try store.sessions(overlapping: DateInterval(start: ts(0), end: ts(2000)))
    XCTAssertEqual(hits.count, 1)
    XCTAssertTrue(hits[0].completed)
    XCTAssertEqual(hits[0].siteBlocks, 2)
}
func testTitleRuleUpsertIsIdempotent() throws {
    let db = try makeDB()
    let store = CategoryStore(db)
    try store.upsertUserTitleRule(pattern: "lecture", scopeKey: "youtube.com", categoryID: "learning")
    try store.upsertUserTitleRule(pattern: "lecture", scopeKey: "youtube.com", categoryID: "writing")
    let rules = try store.titleRules().filter { $0.source == "user" }
    XCTAssertEqual(rules.count, 1)                    // 不复制 addUserURLRule 的裸 INSERT 缺陷
    XCTAssertEqual(rules[0].categoryID, "writing")    // upsert 更新分类
}
func testNewSettingsAccessors() throws {
    let db = try makeDB()
    let s = SettingsStore(db)
    XCTAssertEqual(s.budgetWarnPercent, 20)
    XCTAssertFalse(s.dailySummaryEnabled)
    XCTAssertEqual(s.dailySummaryHour, 19)
    XCTAssertTrue(s.menuBarTextEnabled)
    XCTAssertEqual(s.focusDurationMinutes, 25)
    XCTAssertEqual(s.focusBlockedApps, [])
    s.setFocusBlockedApps(["com.tencent.xinWeChat", "com.hnc.Discord"])
    XCTAssertEqual(s.focusBlockedApps, ["com.tencent.xinWeChat", "com.hnc.Discord"])
}
```

- [ ] **Step 2: 跑测试确认失败**（表不存在 / 方法未定义）

- [ ] **Step 3: 实现 v4 迁移**（AppDatabase.swift v3 块之后、`return migrator` 之前；建表用 v1 的 DSL，播种用 v2 的 execute 惯例）：

```swift
migrator.registerMigration("v4") { db in
    try db.create(table: "titleRule") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("pattern", .text).notNull()
        t.column("scopeKey", .text).notNull().defaults(to: "")
        t.column("categoryID", .text).notNull().references("category")
        t.column("priority", .integer).notNull().defaults(to: 0)
        t.column("source", .text).notNull()
        t.column("enabled", .boolean).notNull().defaults(to: true)
        t.column("createdAt", .datetime).notNull()
        t.uniqueKey(["pattern", "scopeKey"])
    }
    try db.create(table: "budget") { t in
        t.column("categoryID", .text).primaryKey().references("category")
        t.column("dailySeconds", .integer).notNull()
        t.column("enabled", .boolean).notNull().defaults(to: true)
    }
    try db.create(table: "budgetAlert") { t in
        t.column("categoryID", .text).notNull()
        t.column("day", .text).notNull()       // 本地日历 "YYYY-MM-DD"，绝不用 UTC Date
        t.column("kind", .text).notNull()      // "warn" | "limit"
        t.primaryKey(["categoryID", "day", "kind"])
    }
    try db.create(table: "focusSession") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("start", .datetime).notNull().indexed()
        t.column("end", .datetime).notNull()
        t.column("plannedSeconds", .integer).notNull()
        t.column("appBlocks", .integer).notNull().defaults(to: 0)
        t.column("siteBlocks", .integer).notNull().defaults(to: 0)
        t.column("completed", .boolean).notNull().defaults(to: false)
    }
    for rule in Taxonomy.builtinTitleRules {
        try db.execute(
            sql: "INSERT INTO titleRule (pattern, scopeKey, categoryID, priority, source, enabled, createdAt) VALUES (?, '', ?, 0, 'builtin', 1, ?)",
            arguments: [rule.pattern, rule.categoryID, Date()]
        )
    }
}
```

`Taxonomy.swift` 加（保守清单，宁缺毋滥——tier-4 全局规则，误杀面必须小）：

```swift
/// Builtin titleRule seed rows, seeded by migration v4. Global scope.
/// Deliberately tiny: a global title substring reclassifies every matching
/// activity across all apps and sites -- only ship phrases that are
/// near-unambiguous.
public static let builtinTitleRules: [(pattern: String, categoryID: String)] = [
    ("lecture|course|教程|课程|讲座", "learning"),
    ("pull request|merge request|PR #", "softwareDev"),
]
```

- [ ] **Step 4: Records + store 实现**。照 Interfaces 块签名。要点：`upsertUserTitleRule` 用 `INSERT ... ON CONFLICT(pattern, scopeKey) DO UPDATE SET categoryID = excluded.categoryID, source = 'user', enabled = 1`（`setUserDomain` 同款惯例）；`BudgetStore.deleteBudget` 同一事务里 `DELETE FROM budget WHERE categoryID = ?` + `DELETE FROM budgetAlert WHERE categoryID = ?`；`FocusSessionStore.sessions(overlapping:)` SQL `SELECT * FROM span... ` 不对——是 `SELECT * FROM focusSession WHERE start < ? AND end > ?`（新表自己的查询，与 span 冻结无关）；所有方法 `throws`（CategoryStore 惯例，不学 SettingsStore 吞错）。SettingsStore 数组编码：`focusBlockedApps` 用 `values.joined(separator: ",")`，读取 `split(separator: ",").map(String.init).filter { !$0.isEmpty }`（bundle id 与 categoryID 均不含逗号）。

- [ ] **Step 5: 全量测试 + 提交**。注意 `testUpgradeFromV3PreservesData` 用了 `AppDatabase.migrator.migrate(db, upTo: "v3")`——GRDB 7 支持 `migrate(_:upTo:)`，如签名不符按 GRDB 7.11 实际 API 调整（`try migrator.migrate(db, upTo: "v3")`）。`git commit -m "feat: migration v4 -- titleRule/budget/budgetAlert/focusSession tables, builtin title seeds, new stores"`

### Task 4: B1 分类链——标题层接入 Classifier

**Files:**
- Modify: `Sources/TimeSinkKit/Categorization/Classifier.swift`
- Modify: `Sources/TimeSinkKit/Categorization/CategoryResolver.swift`
- Modify: `Tests/TimeSinkKitTests/ClassifierTests.swift`（helper 扩参 + 既有 9 个调用点加 `title:`）
- Test: `Tests/TimeSinkKitTests/TitleRuleTests.swift`（分类层部分追加）

**Interfaces:**
- `ClassificationContext` 加 `public var titleRules: [TitleRule]`（memberwise init 加参数，**带默认 `[]`** 以最小化测试改动——ClassifierTests.ctx 直接调用它）。context 里只放 enabled 行（resolver 过滤），链内不再查 enabled。
- `Classifier.categoryID` 新签名（title **无默认值**，强制所有调用点表态）：

```swift
public static func categoryID(
    appBundleID: String, url: String?, domain: String?,
    title: String?, context: ClassificationContext
) -> String
```

- 新纯函数：`Classifier.matches(pattern: String, in text: String) -> Bool`（现有 `matches(_:url:)` 的语义抽取，原方法改为一行转发保住 public 签名）；`Classifier.titleMatches(pattern: String, title: String) -> Bool`（`re:` 前缀→整串正则；否则拆 `|` 任一非空关键词子串命中）；`Classifier.scopeMatches(_ rule: TitleRule, scopeKey: String) -> Bool`（`rule.scopeKey.isEmpty || rule.scopeKey == scopeKey`）。
- 合并后的优先级链（**同步更新 Classifier.swift:23-35 的文档注释**，它是权威规范）：
  1. user titleRule（scoped 优先）
  2. user domain 后缀覆盖（现有 tier 1）
  3. user urlRule
  4. builtin titleRule 种子
  5. builtin urlRule
  6. curated 后缀 → 7. seed 后缀 → 8. appMap（url==nil）→ 9. llm 精确 → "uncategorized"
- `CategoryResolver.refresh()`：加载 `titleRules().filter(\.enabled)`，排序 = scoped 在前 > priority 降序 > id 降序（新规则优先）；`categoryID(for span:)` 传 `title: span.title`——这一行让所有下游读者自动标题感知。
- Consumes: Task 3 的 `TitleRule` 与 `categoryStore.titleRules()`。

- [ ] **Step 1: 失败测试**（TitleRuleTests 追加分类层用例；helper 仿 ClassifierTests 风格）：

```swift
extension TitleRuleTests {
    private func trCtx(titleRules: [TitleRule] = [], domains: [String: DomainEntry] = [:],
                       rules: [URLRule] = []) -> ClassificationContext {
        ClassificationContext(domainMap: domains, appMap: [:], urlRules: rules, titleRules: titleRules)
    }
    private func tr(_ pattern: String, _ cat: String, scope: String = "",
                    source: String = "user", id: Int64? = nil) -> TitleRule {
        TitleRule(id: id, pattern: pattern, scopeKey: scope, categoryID: cat, source: source)
    }

    func testUserTitleRuleBeatsUserDomainAndBuiltinURLRule() {
        // 经典场景：youtube.com 整体娱乐（user domain + builtin urlRule 双重压制下），讲座标题仍归学习
        let c = trCtx(
            titleRules: [tr("lecture", "learning", scope: "youtube.com")],
            domains: ["youtube.com": .init(categoryID: "entertainment", source: "user")],
            rules: [URLRule(id: nil, pattern: "youtube.com/watch", categoryID: "entertainment", priority: 200, source: "builtin")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "com.google.Chrome",
            url: "https://youtube.com/watch?v=1", domain: "youtube.com",
            title: "MIT Lecture 3 - YouTube", context: c), "learning")
    }
    func testScopedRuleDoesNotFireElsewhere() {
        let c = trCtx(titleRules: [tr("lecture", "learning", scope: "youtube.com")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "b",
            url: "https://bilibili.com/v", domain: "bilibili.com",
            title: "lecture 42", context: c), "uncategorized")
    }
    func testGlobalRuleFiresOnNativeApp() {
        // 无 url/domain 的原生应用 span：scopeKey 落到 bundleID，全局规则也要命中
        let c = trCtx(titleRules: [tr("教程", "learning")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "com.apple.Preview",
            url: nil, domain: nil, title: "SwiftUI 教程.pdf", context: c), "learning")
    }
    func testNilTitleFallsThroughFree() {
        let c = trCtx(titleRules: [tr("lecture", "learning")],
                      domains: ["x.com": .init(categoryID: "socialMedia", source: "seed")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "b",
            url: "https://x.com/", domain: "x.com", title: nil, context: c), "socialMedia")
    }
    func testUserURLRuleBeatsBuiltinTitleSeed() {
        let c = trCtx(
            titleRules: [tr("course", "learning", source: "builtin")],
            rules: [URLRule(id: nil, pattern: "udemy.com", categoryID: "entertainment", priority: 1000, source: "user")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "b",
            url: "https://udemy.com/course/x", domain: "udemy.com",
            title: "My course", context: c), "entertainment")
    }
    func testBuiltinTitleSeedBeatsBuiltinURLRule() {
        let c = trCtx(
            titleRules: [tr("pull request", "softwareDev", source: "builtin")],
            rules: [URLRule(id: nil, pattern: "example.com", categoryID: "news", priority: 100, source: "builtin")])
        XCTAssertEqual(Classifier.categoryID(appBundleID: "b",
            url: "https://example.com/pr/1", domain: "example.com",
            title: "Fix span clipping — Pull Request #42", context: c), "softwareDev")
    }
    func testPipeKeywordGroupAnyHit() {
        XCTAssertTrue(Classifier.titleMatches(pattern: "lecture|course|教程", title: "线性代数教程 第3讲"))
        XCTAssertTrue(Classifier.titleMatches(pattern: "lecture|course|教程", title: "CS540 Course Home"))
        XCTAssertFalse(Classifier.titleMatches(pattern: "lecture|course|教程", title: "Weekend Vlog"))
    }
    func testRegexTitlePattern() {
        XCTAssertTrue(Classifier.titleMatches(pattern: #"re:PR #\d+"#, title: "Fix bug PR #42"))
        XCTAssertFalse(Classifier.titleMatches(pattern: #"re:PR #\d+"#, title: "PR # pending"))
    }
    func testScopedRuleSortsBeforeUnscoped() {
        // 同为 user 层：scoped 的更具体，先命中
        let scoped = tr("news", "learning", scope: "ycombinator.com", id: 1)
        let global = tr("news", "news", id: 2)
        let c = trCtx(titleRules: [scoped, global])   // resolver 排序后的顺序
        XCTAssertEqual(Classifier.categoryID(appBundleID: "b",
            url: "https://ycombinator.com/news", domain: "ycombinator.com",
            title: "Hacker news daily", context: c), "learning")
    }
}
```

- [ ] **Step 2: 跑测试确认编译失败**（签名不匹配）

- [ ] **Step 3: 实现链**。`categoryID` 体内（完整新顺序，早退保零成本）：

```swift
let scopeKey = domain ?? appBundleID

// 0. 用户标题规则 -- 最高层：比域名覆盖更具体的用户意图（spec §5 裁定，
//    反转旧 spec「不做标题匹配」的记录，ADR 见 vault decisions/）
if let title, !title.isEmpty {
    for r in context.titleRules where r.source == "user"
        && scopeMatches(r, scopeKey: scopeKey) && titleMatches(pattern: r.pattern, title: title) {
        return r.categoryID
    }
}
// 1. 用户域名覆盖（原 tier 1，注释保留）
if let domain, let categoryID = suffixMatch(domain: domain, source: "user", context: context) {
    return categoryID
}
// 2. 用户 URL 规则（原单循环拆两遍：数组已 user-first 排序，两个 where 循环零成本）
if let url {
    for rule in context.urlRules where rule.source == "user" && matches(rule, url: url) {
        return rule.categoryID
    }
}
// 3. 内置标题种子
if let title, !title.isEmpty {
    for r in context.titleRules where r.source != "user"
        && scopeMatches(r, scopeKey: scopeKey) && titleMatches(pattern: r.pattern, title: title) {
        return r.categoryID
    }
}
// 4. 内置 URL 规则
if let url {
    for rule in context.urlRules where rule.source != "user" && matches(rule, url: url) {
        return rule.categoryID
    }
}
// 5-9. curated / seed / appMap / llm / uncategorized（原样）
```

`titleMatches` / `matches(pattern:in:)` / `scopeMatches` 全部 `public static`（`nonisolated` 语境下 enum static 已可测）。resolver 排序闭包：

```swift
let titleRules = try categoryStore.titleRules().filter(\.enabled).sorted { lhs, rhs in
    let lhsScoped = !lhs.scopeKey.isEmpty, rhsScoped = !rhs.scopeKey.isEmpty
    if lhsScoped != rhsScoped { return lhsScoped }
    if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
    return (lhs.id ?? 0) > (rhs.id ?? 0)    // 新规则优先（交互稿语义）
}
```

既有 ClassifierTests 的 9 个 `Classifier.categoryID(...)` 调用点逐个加 `title: nil,`（在 `context:` 前）。

- [ ] **Step 4: 全量测试**——重点确认既有 9 个分类测试语义不变、EXPLAIN 回归不动。**提交** `git commit -m "feat: B1 title-rule tiers in Classifier -- user titles above domain overrides, builtin seeds between rule layers"`

### Task 5: B1 UI——右键创建 + 规则面板标题模式

**Files:**
- Create: `Sources/TimeSinkKit/UI/TitleRuleEditor.swift`
- Modify: `Sources/TimeSinkKit/UI/ActivityListView.swift`（Level-3 行抽取 + 上下文菜单 + sheet 宿主）
- Modify: `Sources/TimeSinkKit/UI/SettingsPanes.swift`（RulesSettingsPane 分段两模式）
- Test: `Tests/TimeSinkKitTests/TitleRuleTests.swift`（校验/关键词规整部分追加）

**Interfaces:**
- `TitleRuleEditor` sheet 的输入模型（`ActivityListView` 与 `RulesSettingsPane` 共用）：

```swift
struct PendingTitleRule: Identifiable {
    var id: String { "\(scopeKey)|\(prefill)" }
    var prefill: String          // 预填关键词文本（右键 = 完整标题；新建 = 空）
    var scopeKey: String         // 右键 = 行的 domain/bundleID；新建默认 ""
    var scopeLabel: String       // 展示用（"仅 youtube.com" / "所有活动"）
    var categoryID: String
}
```

- 纯校验/规整函数（editor 文件内，internal `enum TitleRuleInput`）：

```swift
/// 输入按 逗号/顿号/竖线/换行 切分为关键词，逐个 trim，去空；
/// 任一关键词 trim 后 < 2 字符 → nil（tier-0 无撤销，短模式是历史级误杀）；
/// "re:" 前缀整串保留并要求 NSRegularExpression 可编译。
/// 返回入库 pattern（竖线 join）或 nil（非法）。
static func normalizedPattern(_ raw: String) -> String?
```

- Produces: 活动页 Level-3 标题行右键「始终把此标题归为…」→ sheet；确认后 `upsertUserTitleRule` → `resolver.refresh()` → `dataChanged()`（直接调，写路径照 `ActivityRowView.reassign` 形状，do/catch 记 `activityListLogger`）。
- Consumes: Task 3 store CRUD、Task 4 的 `titleMatches`（影响预览复用它）。

- [ ] **Step 1: 失败测试**：

```swift
func testNormalizedPattern() {
    XCTAssertEqual(TitleRuleInput.normalizedPattern("lecture, course，教程"), "lecture|course|教程")
    XCTAssertEqual(TitleRuleInput.normalizedPattern("  pull request  "), "pull request")
    XCTAssertNil(TitleRuleInput.normalizedPattern("a"))            // 单关键词过短
    XCTAssertNil(TitleRuleInput.normalizedPattern("ok, a"))        // 任一关键词过短即整体拒绝
    XCTAssertNil(TitleRuleInput.normalizedPattern(""))
    XCTAssertNil(TitleRuleInput.normalizedPattern("re:"))
    XCTAssertNil(TitleRuleInput.normalizedPattern("re:[unclosed"))  // 正则必须可编译
    XCTAssertEqual(TitleRuleInput.normalizedPattern(#"re:PR #\d+"#), #"re:PR #\d+"#)
}
func testAffectedCount() {
    let items = [
        CategorizedSpan(span: Span(start: ts(0), end: ts(600), appBundleID: "c", appName: "C",
            title: "MIT Lecture 3", url: "https://youtube.com/watch", domain: "youtube.com"), categoryID: "entertainment"),
        CategorizedSpan(span: Span(start: ts(600), end: ts(900), appBundleID: "c", appName: "C",
            title: "Cat video", url: "https://youtube.com/watch", domain: "youtube.com"), categoryID: "entertainment"),
    ]
    let (count, seconds) = TitleRuleInput.affected(items: items, pattern: "lecture", scopeKey: "youtube.com")
    XCTAssertEqual(count, 1)
    XCTAssertEqual(seconds, 600)
}
```

`affected(items:pattern:scopeKey:) -> (count: Int, seconds: TimeInterval)`：对每个 item 取 `span.domain ?? span.appBundleID` 做 scope 检查 + `Classifier.titleMatches`，累计。

- [ ] **Step 2: 确认失败 → 实现 editor**。Sheet 内容（Form）：关键词 TextField（预填 `prefill`，帮助文字「多个关键词用逗号分隔；`re:` 前缀为正则」）、Scope Picker（两项：`仅 \(scopeLabel)` tag scopeKey / `所有活动` tag ""，右键路径默认 scoped——tier-0 爆炸半径纪律）、分类 Picker（`sortedCategories` 同款 computed）、实时影响行 `将影响当前范围内 N 项 · X`（`affected` 对 `model.rangedSpans()` 现算，输入变化即刷新）、取消/保存（保存 disabled 当 `normalizedPattern == nil`）。保存动作按 Interfaces 写路径。

- [ ] **Step 3: 活动页接线**。`ActivityRowView` 的 Level-3 `ForEach(row.titles)` 内容抽成 `TitleRowView`（持 model + 父 row + title），挂 `.contextMenu { Button("始终把此标题归为…") { ... } }`——设置宿主 `ActivityListView` 的 `@State private var pendingTitleRule: PendingTitleRule?` + `.sheet(item: $pendingTitleRule) { TitleRuleEditor(model: model, pending: $0) }`（sheet 必须挂在列表上，菜单本身是瞬态的）。菜单动作填充：`prefill = title.title == "(无标题)" ? "" : title.title`、`scopeKey = parent.id`、`scopeLabel = parent.label`。子行菜单与父行 DisclosureGroup 的既有菜单是否抢占**必须手动验证**（DisclosureGroup+List 的 contextMenu 优先级不显然）；若子行菜单不生效，改为在 TitleRowView 上再补一个行尾省略号按钮触发同一 sheet，验收表允许（右键或行尾菜单点）。
- [ ] **Step 4: 规则面板**。`RulesSettingsPane` 顶部加 `@State private var mode: RuleMode = .url` + segmented Picker（`enum RuleMode { case url, title }`）。`.title` 模式：List 行显示关键词 chips（`pattern.split(separator: "|")` 逐个 Capsule 文本）+ scope（空显示「全局」）+ 目标分类名 + 来源（内置/右键创建→统一显示「内置」/「用户」）+ 今日命中时长（对 `model.rangedSpans(for: .today())` 用 `TitleRuleInput.affected` 现算）；user 行垃圾桶删除（`deleteTitleRule`），builtin 行 Toggle 开关（`setTitleRuleEnabled`）；底部「+ 新建标题规则…」打开同一 editor（`PendingTitleRule(prefill: "", scopeKey: "", scopeLabel: "", categoryID: 首个分类)`）。所有变更走 refresh+dataChanged+reload（面板既有惯例）。`SettingsView.swift:3-8` 的 doc comment 更新提及标题规则。
- [ ] **Step 5: 全量测试 + 手动冒烟**（`swift run` 下右键→sheet→保存→列表即时改类）+ **提交** `git commit -m "feat: B1 title-rule creation from Activities context menu + Rules pane title mode"`

### Task 6: 菜单栏时间文本（常态 + 降级两态）

**Files:**
- Modify: `Sources/TimeSinkKit/App/TimeSinkApp.swift`（label 抽取）
- Modify: `Sources/TimeSinkKit/App/AppModel.swift`（menuTextEnabled 观察属性）
- Modify: `Sources/TimeSinkKit/UI/SettingsPanes.swift`（通用 pane 开关）

**Interfaces:**
- `AppModel` 加 `public var menuTextEnabled: Bool`（init 里从 `settings.menuBarTextEnabled` 读入；toggle 写它 + `settings.setMenuBarTextEnabled`——KV 非观察，必须镜像成 @Observable 属性）。
- `MenuBarLabel`（TimeSinkApp.swift 内新 struct）：文本 = `model.menuTitle`（**今日专注时长**——交互稿定案；`menuTitle` 语义本来就是 focus，勿用 `todayTotalTitle`），`.monospacedDigit()` 防抖动；`model.engine.chromeCaptureDegraded` 时图标换 `hourglass.badge.exclamationmark`（黄点降级态的 SF Symbol 等价物）；`menuTextEnabled == false` 时只留图标。专注倒计时态 Task 12 接入（本 Task 留 `// Task 12: focus countdown replaces text here` 是禁止的——不留 TODO，Task 12 自己改这里）。
- 关键约束：现有 `.onAppear` 引导块（appDelegate.engine 赋值 + onboarding 开窗）**必须原样保留在新 label 视图上**——它是启动钩子。

- [ ] **Step 1: 实现**：

```swift
} label: {
    MenuBarLabel(model: model)
        .onAppear {
            appDelegate.engine = model.engine
            if needsOnboarding { openWindow(id: "main") }
        }
}

struct MenuBarLabel: View {
    let model: AppModel
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.engine.chromeCaptureDegraded
                  ? "hourglass.badge.exclamationmark" : "hourglass")
            if model.menuTextEnabled {
                Text(model.menuTitle).monospacedDigit()
            }
        }
    }
}
```

通用 pane 第一个 Section 加 `Toggle("菜单栏显示今日专注时长", isOn: menuTextBinding)`，binding set 同时写 `model.menuTextEnabled` 与 `model.settings.setMenuBarTextEnabled`。
- [ ] **Step 2: 构建 + 手动验证**（`make install` 后菜单栏出现 `⏳ 3h 42m` 等宽文本；设置关掉后只留图标）——菜单栏渲染无法自动化测试，本 Task 按既有裁定（采集/系统层手动 QA）。`swift test` 全绿。**提交** `git commit -m "feat: menu bar label shows today focus time with settings toggle and degraded badge"`

### Task 7: C2 范围模型——week/month/custom + 环比原语 + Aggregator 上提

**Files:**
- Modify: `Sources/TimeSinkKit/App/DateRangeSelection.swift`
- Modify: `Sources/TimeSinkKit/UI/MainWindow.swift`（toolbar 特判 custom）
- Modify: `Sources/TimeSinkKit/App/AppModel.swift`（interval 重载 + LRU）
- Modify: `Sources/TimeSinkKit/Stats/Aggregator.swift`（三个上提 + weekday-hour 分桶）
- Modify: `Sources/TimeSinkKit/Stats/Format.swift`（durationDelta）
- Modify: `Sources/TimeSinkKit/UI/MenuBarDashboard.swift`（statics 改转发）
- Test: `Tests/TimeSinkKitTests/StatsRangeTests.swift`（新建）+ `AggregatorTests.swift` 追加 + `AppModelCacheTests.swift` 追加

**Interfaces:**

```swift
// DateRangeSelection
public enum Kind: String, CaseIterable { case day, week, month, last7, last30, custom }
public var customStart: Date?   // 仅 kind == .custom 读；startOfDay 规整
public var customEnd: Date?     // 含当天（interval.end = customEnd 的次日 0 点）
public var previousInterval: DateInterval   // week/month → 上一日历周期；其余 → 等长紧邻前窗
public var containsNow: Bool                // interval.contains(Date())
/// 周对齐钉死周一为一周之首（Monday=0 既有惯例），不随 locale。
// 内部：var mondayCalendar: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c }

// AppModel
public func rangedSpans(for interval: DateInterval) -> [CategorizedSpan]  // 新原语；原方法一行委托
// rangeCache 加 LRU：@ObservationIgnored private var cacheOrder: [String] = []，上限 8，超出逐出最旧

// Aggregator（原样上提，签名与 TodayDashboardModel 完全一致；后者留一行转发保测试不动）
public static func dailyPulses(items:categories:days:endingAt:calendar:) -> [Int?]
public static func clippedToElapsed(_ items:windowStart:elapsed:) -> [CategorizedSpan]
public static func streak(dailyPulses:threshold:) -> Int
/// 7x24 逐格 (pulse, seconds)，行序 Monday=0。供热力图。
public static func pulseByWeekdayHour(_ items: [CategorizedSpan], categories: [String: Category], calendar: Calendar) -> [[(pulse: Int?, seconds: TimeInterval)]]

// Format
public static func durationDelta(_ t: TimeInterval) -> String   // "+42m" / "-1h 3m"；MenuBarDashboard 的私有版删除改调这里
```

- [ ] **Step 1: 失败测试**（StatsRangeTests；日期用固定已知日构造，如 2026-08-24 是周一）：

```swift
import XCTest
@testable import TimeSinkKit

final class StatsRangeTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    func testWeekAlignsMonday() {
        let sel = DateRangeSelection(kind: .week, anchor: date(2026, 8, 27))  // 周四
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.weekday, from: sel.interval.start), 2)  // 周一
        XCTAssertEqual(cal.startOfDay(for: sel.interval.start), cal.startOfDay(for: date(2026, 8, 24)))
        XCTAssertEqual(sel.interval.duration, 7 * 86400, accuracy: 3700)      // 容 DST
    }
    func testMonthInterval() {
        let sel = DateRangeSelection(kind: .month, anchor: date(2026, 8, 15))
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.day, from: sel.interval.start), 1)
        XCTAssertEqual(cal.component(.month, from: sel.interval.start), 8)
    }
    func testMonthShiftLandsPreviousMonth() {
        var sel = DateRangeSelection(kind: .month, anchor: date(2026, 8, 31))
        sel.shift(-1)  // 8/31 回退一个月：日历分量步进，不是 -31 天
        XCTAssertEqual(Calendar.current.component(.month, from: sel.anchor), 7)
    }
    func testShiftNeverPassesToday() {
        var sel = DateRangeSelection(kind: .week, anchor: Date())
        sel.shift(1)
        XCTAssertLessThanOrEqual(Calendar.current.startOfDay(for: sel.anchor),
                                 Calendar.current.startOfDay(for: Date()))
    }
    func testCustomSingleDay() {
        var sel = DateRangeSelection(kind: .custom, anchor: date(2026, 8, 10))
        sel.customStart = date(2026, 8, 10); sel.customEnd = date(2026, 8, 10)
        XCTAssertEqual(sel.interval.duration, 86400, accuracy: 3700)
    }
    func testPreviousIntervalWeekIsPreviousCalendarWeek() {
        let sel = DateRangeSelection(kind: .week, anchor: date(2026, 8, 27))
        XCTAssertEqual(sel.previousInterval.end, sel.interval.start)
        XCTAssertEqual(sel.previousInterval.duration, sel.interval.duration, accuracy: 3700)
    }
    func testPreviousIntervalLast7IsEqualLengthPreceding() {
        let sel = DateRangeSelection(kind: .last7, anchor: date(2026, 8, 24))
        XCTAssertEqual(sel.previousInterval.end, sel.interval.start)
        XCTAssertEqual(sel.previousInterval.duration, sel.interval.duration)
    }
    func testLabelForNewKinds() {
        XCTAssertEqual(DateRangeSelection(kind: .week, anchor: Date()).label, "本周")
        XCTAssertEqual(DateRangeSelection(kind: .month, anchor: Date()).label, "本月")
    }
}
```

AggregatorTests 追加（复用其钉死 UTC 日历与 `mkSpan` fixture 风格）：`testPulseByWeekdayHourBuckets`（构造周一 10 点 1h softwareDev + 周一 11 点 30m entertainment，断言 [0][10] pulse=100 seconds=3600、[0][11] pulse=0）；`testLiftedHelpersStillBehave`（`Aggregator.streak([70,71,nil,80,90], threshold: 70) == 2` 等，数值照 TodayDashboardModelTests 既有断言风格）。AppModelCacheTests 追加 `testRangeCacheEvictsOldestBeyondCap`（塞 9 个不同 interval，断言第 1 个被逐出重查——以查询计数 fake spanStore 或以 `rangedSpans` 返回引用相等性判缓存命中，照该文件现有手法）。

- [ ] **Step 2: 确认失败 → 实现 DateRangeSelection**。`windowDays` 只对 day/last7/last30 有意义，week/month/custom 各自走 `mondayCalendar.dateInterval(of: .weekOfYear, for: anchor)` / `calendar.dateInterval(of: .month, for: anchor)` / customStart...customEnd+1d（nil 兜底为 anchor 当天）。`shift`：week 用 `.weekOfYear ±1`、month 用 `.month ±1`、custom 平移区间长度天数、其余原逻辑；防未来钳制统一保留。`label`：week → 本周/上周/「8月24日那周」，month → 本月/「7月」，custom → 「8月10日 – 8月16日」（复用 `monthDay`）。`previousInterval`：week/month 对 anchor 减一周期取同 kind interval；其余 `DateInterval(start: interval.start - interval.duration, end: interval.start)`。
- [ ] **Step 3: MainWindow toolbar**。`ForEach(Kind.allCases)` 改显式列表：day/week/month/last7/last30 仍是 Button（`label(for:)` 委托给 `DateRangeSelection.label` 的 kind 静态文案：今天/本周/本月/近 7 天/近 30 天）；`.custom` 单独渲染为 Button("自定义…") 弹 `.popover`：两个 `DatePicker`（displayedComponents: .date）+「应用」按钮，应用时构造 `DateRangeSelection(kind: .custom, anchor: end, customStart: start, customEnd: end)` 赋 `model.range`。
- [ ] **Step 4: AppModel interval 原语 + LRU**。原 `rangedSpans(for range:)` 变 `rangedSpans(for: range.interval)` 一行；新方法体 = 原实现（key 从 interval 算）+ LRU 维护（命中时把 key 移到队尾；插入后 `while cacheOrder.count > 8` 逐出队首）。`dataChanged()` 同步清 `cacheOrder`。
- [ ] **Step 5: Aggregator 上提 + Format.durationDelta**。三个函数**原样搬运**（bodies 不改），`TodayDashboardModel` 对应 statics 改为一行 `Aggregator.xxx(...)` 转发（`TodayDashboardModelTests` 原样通过 = 行为保持的证明）。`pulseByWeekdayHour` 实现：per (weekday(Monday=0), hour) 累积 `[String: TimeInterval]`（经 `split(by: .hour)`，weekday 用 `(weekday + 5) % 7` 既有惯例），再逐格 `Aggregator.pulse`。`MenuBarDashboard.durationDelta` 私有函数删除，调用点改 `Format.durationDelta`。
- [ ] **Step 6: 全量测试 + 提交** `git commit -m "feat: C2 range model -- week/month/custom kinds, previousInterval, interval-keyed LRU cache, aggregator lifts"`

### Task 8: C2 统计视图——摘要卡 delta、趋势线、热力图、布局重排

**Files:**
- Modify: `Sources/TimeSinkKit/UI/StatsModel.swift`
- Modify: `Sources/TimeSinkKit/UI/Cards.swift`（FocusTimeCard、delta 参数、ScoreTrendCard、HeatmapCard）
- Modify: `Sources/TimeSinkKit/UI/StatsView.swift`（布局 + 页内范围分段控件）
- Test: `Tests/TimeSinkKitTests/StatsRangeTests.swift` 追加（delta 语义）

**Interfaces:**
- `StatsModel` 新增字段：`focus: TimeInterval`、`totalDelta/focusDelta: TimeInterval?`、`pulseDelta: Int?`、`scoreTrend: [Int?]`（30 项，尾 = 今天）、`trendStreak: Int`、`heatmap: [[(pulse: Int?, seconds: TimeInterval)]]`（7x24）。
- `recompute(model:forceHeavy:)`：轻部分（现有 + focus + deltas）每次跑；重部分（trend + heatmap，共用同一次 `rangedSpans(for: DateRangeSelection(kind: .last30, anchor: Date()))` 取数——与菜单栏 streak 同缓存键，近零成本）套 `refreshStreakIfDayChanged` 同款门控：`@ObservationIgnored private var lastHeavyDay: Date?`，force 或跨天才重算。StatsView 的 onAppear/range 变化传 `forceHeavy: true`，dataVersion 传 `false`。既有调用点签名变化就地更新。
- Delta 语义（spec §6 裁定，逐字执行）：`prev = model.rangedSpans(for: model.range.previousInterval)`；`range.containsNow` 时时长类用 `Aggregator.clippedToElapsed(prev, windowStart: previousInterval.start, elapsed: Date() - interval.start)`，分数 delta 用未裁 prev；prev 为空 → 三个 delta 全 nil（卡片不显示 chip）。
- 卡片：`TotalTimeCard`/`ProductivityScoreCard` 加 `var delta: ...? = nil` 默认参数（不破坏既有调用）；新 `FocusTimeCard(focus:delta:)` 镜像 TotalTimeCard；`ScoreTrendCard(trend:streak:onSelectDay:)`——LineMark+PointMark、`RuleMark(y: .value("阈值", 70))` 虚线、`.chartOverlay` + `onContinuousHover` 最近点十字浮层（本地 @State hoverIndex + `.annotation`）、点击回调 `onSelectDay(Date)`（index → 今天-29+index 天）由 StatsView 接 `model.range = DateRangeSelection(kind: .day, anchor: day)`；`HeatmapCard(cells:)`——**手绘** `Grid` 168 格（`DayTimelineView` 手绘先例：Swift Charts 的逐 mark `.help()` 不可靠），格色 `scoreColor(pulse).opacity(...)`、`seconds < 900` 降透明 + `.help("周二 10 时 · 样本不足")`，正常格 `.help("周二 10 时 · 平均分 82")`，行标 周一…周日、列标 0/6/12/18/23，卡题注「近 30 天」。
- StatsView 布局重排：ScrollView VStack 变四段——(1) 页内分段控件行（`Picker` segmented：今天/本周/本月 写 `model.range`，旁边「自定义…」按钮弹与 toolbar 同款 popover；控件与全局 toolbar 写同一状态，双向一致）；(2) 摘要行 HStack 三卡（Total/Score/Focus，高 110，带 delta chips）；(3) 趋势行 HStack（ScoreTrendCard 0.6 宽 + HeatmapCard 0.4 宽，高 220）；(4) 现有 profile Grid + StackedCategoryCard（`topRow` 里 TotalTimeCard/ProductivityScoreCard 两格换成两张 Profile 卡挪位后的 2x2 + stacked 双高保持；bottomRow donuts 不动）。目标：现有六张 profile/stacked/donut 卡全部保留，只是 Total/Score 升到摘要行。
- Consumes: Task 7 全部原语。

- [ ] **Step 1: 失败测试**（delta 语义为主，视图不测）：

Delta 语义不经视图、直接测纯管线（避免依赖「现在几点」的脆断言——把裁剪逻辑对固定时刻测）：

```swift
// StatsRangeTests 追加
func testDurationDeltaUsesClippedPreviousButPulseUsesFull() {
    let cal = Calendar.current
    let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
    let todayStart = cal.startOfDay(for: ts(200_000))
    let prevStart = cal.date(byAdding: .day, value: -1, to: todayStart)!
    // 昨天：0-4h softwareDev(+2)，18h-20h entertainment(-2)；今天走到 5h，产出 2h softwareDev
    let prev = [
        CategorizedSpan(span: Span(start: prevStart, end: prevStart.addingTimeInterval(4 * 3600),
            appBundleID: "x", appName: "X", title: nil, url: nil, domain: nil), categoryID: "softwareDev"),
        CategorizedSpan(span: Span(start: prevStart.addingTimeInterval(18 * 3600),
            end: prevStart.addingTimeInterval(20 * 3600),
            appBundleID: "y", appName: "Y", title: nil, url: nil, domain: nil), categoryID: "entertainment"),
    ]
    let elapsed: TimeInterval = 5 * 3600
    let clipped = Aggregator.clippedToElapsed(prev, windowStart: prevStart, elapsed: elapsed)
    // 裁剪后昨天只剩 0-4h 的 softwareDev：时长基准 4h，娱乐段被裁掉
    XCTAssertEqual(Aggregator.totalDuration(clipped.map(\.span)), 4 * 3600)
    // 分数基准用未裁全天：4h*100 + 2h*0 → (400+0)/6 ≈ 67
    let fullPulse = Aggregator.pulse(
        durationByCategory: Aggregator.durationByCategory(prev), categories: cats)
    XCTAssertEqual(fullPulse, 67)
}
```

StatsModel 的组装式断言（重算门控）：

```swift
// StatsRangeTests 追加
@MainActor func testHeavyRecomputeGatedByDay() throws {
    let db = try AppDatabase.openInMemory()
    let store = SpanStore(db)
    _ = try store.insert(Span(start: Date().addingTimeInterval(-3600), end: Date(),
                              appBundleID: "a", appName: "A", title: nil, url: nil, domain: nil))
    let catStore = CategoryStore(db)
    let model = AppModel(categoryStore: catStore, spanStore: store,
                         settings: SettingsStore(db),
                         resolver: CategoryResolver(categoryStore: catStore),
                         engine: TrackerEngine(spanStore: store, settings: SettingsStore(db)))
    let stats = StatsModel()
    stats.recompute(model: model, forceHeavy: true)
    let firstTrend = stats.scoreTrend
    XCTAssertEqual(firstTrend.count, 30)
    stats.scoreTrend = []                                  // 打标
    stats.recompute(model: model, forceHeavy: false)       // 同日非强制：不重算重部分
    XCTAssertEqual(stats.scoreTrend, [])
    stats.recompute(model: model, forceHeavy: true)        // 强制：重算
    XCTAssertEqual(stats.scoreTrend.count, 30)
}
```

- [ ] **Step 2: 确认失败 → 实现 StatsModel**（照 Interfaces）。`focus` 从既有 `byCategory` 一行得出（`Aggregator.focusTime`）。
- [ ] **Step 3: 实现三张新卡 + 布局重排**（照 Interfaces 描述；十字浮层文案 `8月19日 · 74 分`，无数据点显示 `无记录`）。
- [ ] **Step 4: 全量测试 + `make install` 手动过交互稿 C2 节**（范围切换联动、逐点悬停、点击跳日、热力图逐格浮层、样本不足降透明）。**提交** `git commit -m "feat: C2 stats 2.0 -- summary deltas, 30-day score trend, 7x24 productivity heatmap, in-page range control"`

### Task 9: C3 搜索 + 轻量实体展示

**Files:**
- Modify: `Sources/TimeSinkKit/App/AppModel.swift`（activitySearch）
- Modify: `Sources/TimeSinkKit/UI/ActivitiesView.swift`（filter 接入 recompute + searchable + 命中行 + 防抖）
- Create: `Sources/TimeSinkKit/Core/EntityParser.swift`
- Modify: `Sources/TimeSinkKit/UI/ActivityListView.swift`（reassignKey 改线 + 实体行徽注）
- Test: `Tests/TimeSinkKitTests/EntityParserTests.swift`（新建）+ `ActivitiesModelTests.swift` 追加

**Interfaces:**

```swift
// AppModel
public var activitySearch: String = ""

// ActivitiesModel（全部 nonisolated static internal）
static func normalizedQuery(_ raw: String) -> String?          // trim；空 → nil
static func matches(_ item: CategorizedSpan, query: String) -> Bool
    // 命中域：span.domain / span.appName / span.title / span.url，大小写不敏感子串，短路
static func filter(_ items: [CategorizedSpan], query: String?) -> [CategorizedSpan]
// recompute 首行变：
//   let all = model.rangedSpans()
//   let query = Self.normalizedQuery(model.activitySearch)
//   let items = Self.filter(all, query: query)
//   matchCount = query == nil ? nil : items.count
//   matchSeconds = query == nil ? nil : Aggregator.totalDuration(items.map(\.span))
// 时间轴仍用未过滤 all（列表收窄，时间轴保持全天上下文——spec §7）
var matchCount: Int?; var matchSeconds: TimeInterval?

// EntityParser
public enum EntityParser {
    /// github/gitlab: /owner/repo（保留路径 denylist + ≥2 段 + 剥 query/fragment）；
    /// youtube: 仅 /@handle /channel/ /c/ /user/（watch 无频道信息，不伪造）；其余 nil。
    public static func entity(urlString: String, domain: String) -> (key: String, label: String)?
    static let reservedGitHubPaths: Set<String>  // settings login apps orgs notifications pulls issues marketplace sponsors explore topics codespaces new about features search
}

// ActivitiesModel.ActivityRow 加字段
let reassignKey: String   // 永远是 domain 或 bundleID —— setUserDomain/setUserApp 只吃这个
let isEntity: Bool        // 实体行右键菜单文案加「（整站）」后缀提示写的是 domain 级覆盖
// rows(for:) 从 private 升 internal（文件内注释 :162-165 已预告此惯例），分组键改
//   EntityParser.entity(...)?.key ?? span.domain ?? span.appBundleID
```

- [ ] **Step 1: 失败测试**：

```swift
final class EntityParserTests: XCTestCase {
    func testGitHubOwnerRepo() {
        let e = EntityParser.entity(urlString: "https://github.com/alllllenshi/timesink/pull/42?diff=split",
                                    domain: "github.com")
        XCTAssertEqual(e?.key, "github.com/alllllenshi/timesink")
        XCTAssertEqual(e?.label, "github.com / alllllenshi / timesink")
    }
    func testGitHubReservedAndBareOwner() {
        XCTAssertNil(EntityParser.entity(urlString: "https://github.com/settings/emails", domain: "github.com"))
        XCTAssertNil(EntityParser.entity(urlString: "https://github.com/login/oauth/authorize?state=xyz", domain: "github.com"))
        XCTAssertNil(EntityParser.entity(urlString: "https://github.com/samsara0xgg", domain: "github.com"))
    }
    func testYouTubeChannelOnlyExplicitPaths() {
        XCTAssertEqual(EntityParser.entity(urlString: "https://youtube.com/@3blue1brown/videos",
                                           domain: "youtube.com")?.key, "youtube.com/@3blue1brown")
        XCTAssertNil(EntityParser.entity(urlString: "https://youtube.com/watch?v=abc", domain: "youtube.com"))
    }
    func testOtherDomainsNil() {
        XCTAssertNil(EntityParser.entity(urlString: "https://arxiv.org/abs/1234.5678", domain: "arxiv.org"))
    }
}
// ActivitiesModelTests 追加
func testSearchMatchesAcrossFields() {
    let item = CategorizedSpan(span: Span(start: ts(0), end: ts(60), appBundleID: "c",
        appName: "Chrome", title: "Fix span clipping — Pull Request #42",
        url: "https://github.com/a/b/pull/42", domain: "github.com"), categoryID: "softwareDev")
    XCTAssertTrue(ActivitiesModel.matches(item, query: "pull request"))   // title 大小写不敏感
    XCTAssertTrue(ActivitiesModel.matches(item, query: "GITHUB.COM"))     // domain
    XCTAssertTrue(ActivitiesModel.matches(item, query: "chrome"))         // appName
    XCTAssertFalse(ActivitiesModel.matches(item, query: "youtube"))
}
func testFilterComposesAndNormalizes() {
    XCTAssertNil(ActivitiesModel.normalizedQuery("   "))
    XCTAssertEqual(ActivitiesModel.normalizedQuery(" Pull "), "Pull")
    let hit = CategorizedSpan(span: Span(start: ts(0), end: ts(60), appBundleID: "c",
        appName: "Chrome", title: "Pull Request #42", url: "https://github.com/a/b", domain: "github.com"),
        categoryID: "softwareDev")
    let miss = CategorizedSpan(span: Span(start: ts(60), end: ts(120), appBundleID: "m",
        appName: "Music", title: "Daily Mix", url: nil, domain: nil), categoryID: "entertainment")
    XCTAssertEqual(ActivitiesModel.filter([hit, miss], query: "pull").count, 1)
    XCTAssertEqual(ActivitiesModel.filter([hit, miss], query: nil).count, 2)
}
func testEntityRowKeepsDomainReassignKey() {
    let item = CategorizedSpan(span: Span(start: ts(0), end: ts(600), appBundleID: "c",
        appName: "Chrome", title: "PR", url: "https://github.com/alllllenshi/timesink/pull/1",
        domain: "github.com"), categoryID: "softwareDev")
    let rows = ActivitiesModel.rows(for: [item])
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].id, "github.com/alllllenshi/timesink")
    XCTAssertEqual(rows[0].reassignKey, "github.com")
    XCTAssertTrue(rows[0].isEntity)
}
```

- [ ] **Step 2: 确认失败 → 实现**。`EntityParser`：`URLComponents(string:)` 取 path 段（percent-decoded），github/gitlab 分支 `guard parts.count >= 2, !reservedGitHubPaths.contains(parts[0].lowercased())`；youtube 分支按四种前缀。`matches`：四字段依序 `localizedCaseInsensitiveContains`，nil 跳过。`rows(for:)` 分组键改造时同步维护 `reassignKey`（domain ?? bundleID）与 label（实体命中时 `"\(domain) / \(owner) / \(repo)"`）。
- [ ] **Step 3: UI 接线**。`ActivitiesView`：`.searchable(text: searchBinding, prompt: "搜索应用、网址、标题")`；`searchBinding` 写 `model.activitySearch`；新增 `.onChange(of: model.activitySearch)` → 防抖 recompute（`@State pendingSearch: Task<Void, Never>?`，`.day` 范围 0ms、其余 200ms sleep，照 AppModel.scheduleEngineDataChanged 的 Task 形状）。列表上方命中行：`activities.matchCount != nil` 时 `Text("命中 \(matchCount) 项 · 合计 \(Format.duration(matchSeconds))")` + 空态文案区分「没有命中的活动（隐身窗口与未授权时段无记录）」。`ActivityRowView.reassign` 改用 `row.reassignKey`；`row.isEntity` 时菜单 Button 文案 `"\(category.name)（整站）"`。
- [ ] **Step 4: 全量测试 + 提交** `git commit -m "feat: C3 search with live match totals + display-level entity grouping for github/gitlab/youtube"`

### Task 10: C3 日历叠加、会议标注与空闲豁免

**Files:**
- Create: `Sources/TimeSinkKit/Tracking/CalendarStore.swift`
- Modify: `Sources/TimeSinkKit/Tracking/Permissions.swift`（calendar 状态/请求）
- Modify: `Sources/TimeSinkKit/Tracking/TrackerEngine.swift`（isInMeetingProvider seam）
- Modify: `Sources/TimeSinkKit/App/AppModel.swift`（CalendarStore 持有 + 今日会议窗缓存 + seam 接线）
- Modify: `Sources/TimeSinkKit/App/TimeSinkApp.swift`（组装）
- Modify: `Sources/TimeSinkKit/UI/ActivitiesView.swift` / `TimelineView.swift`（事件车道 + 内联启用卡 + 会议徽注）
- Modify: `Sources/TimeSinkKit/UI/SettingsPanes.swift`（权限区 calendarRow）
- Modify: `packaging/Info.plist`（NSCalendarsFullAccessUsageDescription）+ `Package.swift`（EventKit）
- Test: `Tests/TimeSinkKitTests/CalendarMeetingTests.swift`（新建）+ `TrackerEngineTests.swift` 追加

**Interfaces:**

```swift
// CalendarStore.swift（EventKit 的唯一栖身处；import EventKit 只出现在此文件与 Permissions）
public struct CalendarEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var attendeeCount: Int
    public var isDeclined: Bool
    public var calendarTitle: String
    public var colorHex: String
    /// 纯谓词：非全天 && 未拒绝 && (2 人以上 || 标题命中会议词)。
    public var isMeeting: Bool
    /// 会议词：sync / 1:1 / standup / 组会 / 例会 / meeting（大小写不敏感）——internal static let meetingKeywords
}

public actor CalendarStore {
    public init()
    /// 当日事件（含跨日裁剪前的原始起止），按日缓存；排除 .birthday/.subscription 类型日历；
    /// 未授权返回 []。EKEvent → CalendarEvent 转换在 actor 内完成，EK 类型不越界。
    public func events(on day: Date) async -> [CalendarEvent]
    public func invalidateCache()   // .EKEventStoreChanged 时调（AppModel 注册观察）
}

// 纯函数（CalendarEvent 同文件，nonisolated static）
public enum MeetingTagger {
    /// 与任一 isMeeting 事件重叠 ≥ span 时长 50% 的 span id 集合 + 会议总秒数。
    /// 在合并前的原始 CategorizedSpan 上算（合并管线吞碎片，见 spec §7）。
    public static func tagged(items: [CategorizedSpan], events: [CalendarEvent])
        -> (spanIDs: Set<Int64>, seconds: TimeInterval)
    /// 现在时刻是否处于任一会议事件内（空闲豁免用）。
    public static func inMeeting(at date: Date, events: [CalendarEvent]) -> Bool
}

// Permissions 追加
@MainActor public static func calendarState() -> PermissionState
    // EKEventStore.authorizationStatus(for: .event)：.fullAccess→granted；.denied/.restricted/.writeOnly→denied；.notDetermined→notDetermined
@MainActor public static func requestCalendarAccess() async -> Bool
    // 必须先 guard Bundle.main.bundleIdentifier == "com.alllllenshi.TimeSink" else return false（崩溃门）

// TrackerEngine 追加 seam（既有四个 seam 旁）
var isInMeetingProvider: (() -> Bool)?
// tick 首行改：
//   let rawIdle = idleSecondsProvider?() ?? idleMonitor.idleSeconds()
//   let idleSeconds = (isInMeetingProvider?() == true) ? 0 : rawIdle
// 语义：会议期间空闲不触发 becameIdle（豁免空闲判定，交互稿 C3 注 1）；锁屏/睡眠仍照常挂起。

// AppModel 追加（**注入惯例**：本批所有新协作者一律 post-init 可选属性赋值，
// 不改 AppModel.init 签名——既有构造点（TimeSinkApp、AppModelCacheTests、Task 8 fixture）零改动，
// 且 bootstrap 期 refreshMenu 时它们为 nil，天然充当 didBootstrap 守卫）
public var calendarStore: CalendarStore?          // TimeSinkApp 组装后赋值
public var calendarOverlayEnabled: Bool           // settings 镜像观察属性（同 menuTextEnabled 模式）
@ObservationIgnored private var todayMeetingEvents: [CalendarEvent] = []
public func refreshCalendarWindows() async        // overlayEnabled && granted 时取今日事件存入缓存
public var isNowInMeeting: Bool                   // MeetingTagger.inMeeting(at: Date(), events: todayMeetingEvents)
// 接线（TimeSinkApp init）：engine.isInMeetingProvider = { [weak model] in model?.isNowInMeeting ?? false }
// 刷新时机：启动后、EKEventStoreChanged、每 5 分钟（AppModel 内 Task.sleep 循环，overlayEnabled 才跑）

// TimelineView 追加
struct TimelineEventBlock: Identifiable { let id: String; let title: String; let start: Date; let end: Date; let color: Color; let tooltip: String }
// DayTimelineView 加 init 参数 events: [TimelineEventBlock] = [], allDay: [String] = []
// 布局：容器 260pt；blockWidth 拆 55% 活动 / 40% 事件 + 5% 缝；事件块 = 日历色 15% 填充 + 1.5pt 描边圆角矩形 + .help；全天事件在 zoomControls 下方一条固定横排 chips
```

- Consumes: Task 1 `PermissionState`/`PermissionRow`；Task 3 `calendarOverlayEnabled` 设置键。

- [ ] **Step 1: 失败测试**：

```swift
final class CalendarMeetingTests: XCTestCase {
    private func ev(_ s: TimeInterval, _ e: TimeInterval, attendees: Int = 2, title: String = "Sync",
                    allDay: Bool = false, declined: Bool = false) -> CalendarEvent {
        CalendarEvent(id: UUID().uuidString, title: title, start: ts(s), end: ts(e),
                      isAllDay: allDay, attendeeCount: attendees, isDeclined: declined,
                      calendarTitle: "工作", colorHex: "#3478F6")
    }
    func testIsMeetingPredicate() {
        XCTAssertTrue(ev(0, 3600).isMeeting)                                   // 2 人
        XCTAssertTrue(ev(0, 3600, attendees: 0, title: "团队组会").isMeeting)   // 关键词
        XCTAssertFalse(ev(0, 3600, attendees: 0, title: "写代码").isMeeting)    // 单人非会议
        XCTAssertFalse(ev(0, 3600, allDay: true).isMeeting)                    // 全天排除
        XCTAssertFalse(ev(0, 3600, declined: true).isMeeting)                  // 已拒绝排除
    }
    func testTaggedRequiresHalfOverlap() {
        let meeting = ev(0, 1800)
        let inside = CategorizedSpan(span: Span(id: 1, start: ts(0), end: ts(1000), appBundleID: "z",
            appName: "zoom", title: nil, url: nil, domain: "zoom.us"), categoryID: "communication")
        let brushing = CategorizedSpan(span: Span(id: 2, start: ts(1700), end: ts(3500), appBundleID: "z",
            appName: "zoom", title: nil, url: nil, domain: "zoom.us"), categoryID: "communication")
        let r = MeetingTagger.tagged(items: [inside, brushing], events: [meeting])
        XCTAssertEqual(r.spanIDs, [1])          // brushing 重叠 100s < 1800s 的 50%
        XCTAssertEqual(r.seconds, 1000)
    }
    func testInMeetingWindow() {
        XCTAssertTrue(MeetingTagger.inMeeting(at: ts(100), events: [ev(0, 600)]))
        XCTAssertFalse(MeetingTagger.inMeeting(at: ts(700), events: [ev(0, 600)]))
        XCTAssertFalse(MeetingTagger.inMeeting(at: ts(100), events: [ev(0, 600, declined: true)]))
    }
}
// TrackerEngineTests 追加（沿用该文件既有 seam 驱动手法）
@MainActor func testMeetingExemptsIdleClose() throws {
    // engine 配 idleSecondsProvider = { 300 }（> 阈值 180）、isInMeetingProvider = { true }、
    // windowSampleProvider 喂固定 sample → tick 两次 → span 仍在延长（builder.current 不为 nil）
    // 再把 isInMeetingProvider 换 { false } → tick → becameIdle 关闭
}
```

- [ ] **Step 2: 确认失败 → 实现纯层**（CalendarEvent/isMeeting/MeetingTagger/engine seam），测试转绿。
- [ ] **Step 3: CalendarStore actor + Permissions + 打包**。EKEventStore 存 actor 属性（构造不触发授权）；`events(on:)`：`guard` 授权 fullAccess（经 nonisolated 读 `EKEventStore.authorizationStatus`）否则 []；`predicateForEvents(withStart: dayStart, end: dayStart+1d, calendars: nil)` → `events(matching:)` → 过滤日历类型 → 映射（attendeeCount = `event.attendees?.count ?? 0`；isDeclined 取 `event.attendees` 里 currentUser 的 participantStatus == .declined，取不到当前用户时 false；colorHex 从 `calendar.cgColor` 转换，复用 ColorHex 的转换思路）。`Package.swift` linkerSettings 加 `.linkedFramework("EventKit")`；Info.plist 在 NSAppleEventsUsageDescription 后加：

```xml
<key>NSCalendarsFullAccessUsageDescription</key>
<string>TimeSink 读取本机日历以在时间轴上叠加日程并自动标注会议时间，数据不出本机。</string>
```

（实测缺 key = 静默永久失败：授权回调 granted=false 且无提示——这行是功能的生死线，评审必须盯。）
- [ ] **Step 4: AppModel/App 组装 + UI**。照 Interfaces 接线。ActivitiesView 日历带位置三态：`calendarOverlayEnabled == false || calendarState == .notDetermined` → 启用卡（标题「日历叠加」+ 说明 + 「启用」按钮：`setCalendarOverlayEnabled(true)` + `await Permissions.requestCalendarAccess()` + 刷新）；`denied` → 引导卡（文案 + 「打开系统设置」按钮，URL `x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars`）；granted → 事件车道。事件加载：`ActivitiesModel` 加 `var calendarBlocks: [TimelineEventBlock]`、`var allDayTitles: [String]`、`var meetingSpanIDs: Set<Int64>`、`var meetingSeconds: TimeInterval`；`recompute` 保持同步读快照（`ActivitiesView` 上 `@State events: [CalendarEvent]` 经 `.task(id: model.range)` 异步取 `model.calendarStore.events(on:)` 后传入 recompute——recompute 不 async 化，既有 onChange 触发形状不动）。列表行会议徽注：`ActivityRow` 加 `hasMeeting: Bool`（该行任一 span id ∈ meetingSpanIDs），行尾加「会议」Capsule + `.help("由日历事件自动标注")`；列表顶部会议汇总行 `会议时间 X`（meetingSeconds > 0 时）。时间轴显示条件从 `range.kind == .day` 放宽为 `abs(range.interval.duration - 86400) < 7200`（custom 单日也显示——修交互稿遗留坑）。设置·通用权限区加 `PermissionRow(title: "日历", ...)`（granted/denied/notDetermined 状态 + 去授权动作 = 请求或开系统设置）。
- [ ] **Step 5: 全量测试 + `make install` 手动 QA**（授权弹窗出现、事件车道渲染、组会自动标注、拒绝后引导卡）。**注意日历迭代只能装包验证**（TCC 归因终端的坑，README:54 同款）。**提交** `git commit -m "feat: C3 calendar overlay with meeting tagging and idle exemption via EventKit actor"`

### Task 11: C4 预算引擎、每日小结与预算面板

**Files:**
- Create: `Sources/TimeSinkKit/Stats/BudgetEngine.swift`（纯函数 + BudgetMonitor）
- Modify: `Sources/TimeSinkKit/App/AppModel.swift`（monitor 挂载 + settingsTab/pendingRoute）
- Modify: `Sources/TimeSinkKit/App/TimeSinkApp.swift`（组装 + 路由消费）
- Create: `Sources/TimeSinkKit/UI/BudgetSettingsPane.swift`
- Modify: `Sources/TimeSinkKit/UI/SettingsView.swift`（第 6 个标签 + selection 绑定）
- Modify: `Sources/TimeSinkKit/UI/MenuBarDashboard.swift`（弹出层预算行）
- Test: `Tests/TimeSinkKitTests/BudgetTests.swift`（新建）

**Interfaces:**

```swift
public enum BudgetEngine {
    public enum Level: Int, Comparable, Sendable { case none = 0, warn = 1, limit = 2 }
    /// warnPercent = 剩余百分比阈值（20 = 剩 20% 时预警，即 spent >= 0.8 * limit）
    public static func level(spent: TimeInterval, limit: TimeInterval, warnPercent: Int) -> Level
    /// 本地日历 "YYYY-MM-DD"（String(format:) 拼 components，不用 DateFormatter——Sendable 惯例）
    public static func dayStamp(_ date: Date, calendar: Calendar) -> String
}

@MainActor
public final class BudgetMonitor {
    public init(budgetStore: BudgetStore, settings: SettingsStore, notifier: any Notifying)
    /// AppModel.refreshMenu() 尾部调用。byCategory 是它已算好的当天字典——零新查询。
    /// 每类每天 warn/limit 各至多一次：一次评估同时跨两级只发 limit；
    /// 先 post 成功再 noteAlert（先做事后盖戳，SeedImporter 惯例）。
    public func evaluate(byCategory: [String: TimeInterval], categories: [String: Category], now: Date)
    /// 同通道的每日小结：enabled && now >= 当日 dailySummaryHour 点 && lastSummaryDay != 今天
    /// → makeBody() 发通知（route .statsToday）→ setLastSummaryDay。锁屏错过 → 当天下次评估补发。
    public func evaluateSummary(now: Date, makeBody: () -> (title: String, body: String)?)
}
```

- 通知文案（交互稿逐字规范；X/Y 用 `Format.duration`）：
  - warn：title `\(分类名)还剩 \(Format.duration(limit - spent))`，body `今天已用 X / Y。到达上限前会再提醒一次。`，id `budget.warn.\(categoryID)`，route `.settingsBudget`
  - limit：title `\(分类名)已到今日上限`，body `已用 Y / Y。今天不会再提醒；上限可在设置中调整。`，id `budget.limit.\(categoryID)`，route `.settingsBudget`
  - summary：title `今日小结`，body `专注 A，生产力分 P（较昨日 ±D）。最高峰在 H1 – H2 时。`（AppModel 组装：focus/pulse 现成，昨日 delta 走 `Aggregator.clippedToElapsed` 口径与弹出层一致，峰值 = `profileByHourOfDay` 最大连续两小时窗）
- 组装与守卫：`TimeSinkApp.init` 构造 `BudgetStore`、`NotifierFactory.make()`、`BudgetMonitor`，**在 `AppModel` 构造之后**赋 `model.budgetMonitor = monitor`（AppModel 持 `public var budgetMonitor: BudgetMonitor?` 默认 nil）——bootstrap 期 `refreshMenu()` 时 monitor 尚为 nil，免费获得 didBootstrap 守卫（spec §8）。同处调用一次 `try? budgetStore.pruneAlerts(before: 90 天前 dayStamp)`。`AppModel.refreshMenu()` 尾部：

```swift
budgetMonitor?.evaluate(byCategory: byCategory, categories: resolver.categoriesByID, now: Date())
budgetMonitor?.evaluateSummary(now: Date()) { [weak self] in self?.makeDailySummary() }
```

- 路由消费：`AppModel` 加 `public var settingsTab: SettingsTab = .general`（`public enum SettingsTab: Hashable { case general, categories, rules, uncategorized, llm, budget }`）与 `public var pendingRoute: NotificationRoute?`。`TimeSinkApp` 给 `appDelegate.onRoute = { model.pendingRoute = $0 }`；`MenuBarLabel` 加 `.onChange(of: model.pendingRoute)`（label 常驻，是可靠观察点）消费：`.statsToday` → range=.today()+sidebar=.stats+openWindow("main")；`.activitiesToday` → 同理 activities；`.settingsBudget` → `model.settingsTab = .budget` + `openSettings()`（`@Environment(\.openSettings)`）；消费后置 nil。`SettingsView` 改 `TabView(selection: settingsTabBinding)` 各 tab `.tag(SettingsTab.xxx)`（需要 `@Bindable var model` 或手写 Binding）。
- 预算面板（BudgetSettingsPane，模型照 RulesSettingsPane 的 load/mutate/reload 惯例）：分类预算列表（每行：色点 + 名 + Toggle + `-`/`+` 步进 15 分钟（下限 15m）显示「每日上限 X」+ ✕ 删除）、「+ 添加分类预算…」Menu（列出未设预算的分类）、提前预警 Stepper（10/20/30%）、每日小结（Toggle + 整点 Stepper 0-23）、专注拦截应用（chips + 「编辑…」sheet：`NSWorkspace.shared.runningApplications` 过滤 `.activationPolicy == .regular` 的列表勾选 + 手输 bundle id 行，写 `setFocusBlockedApps`）、专注拦截网站分类（12 分类多选 chips，写 `setFocusBlockedCategories`）。**首次启用任一预算或打开小结时**：`Task { await notifier.requestAuthorization() }`（AppModel 暴露 `public var notifier: (any Notifying)?`，post-init 赋值——注入惯例见 Task 10）。`AppModel` 另加 `private func makeDailySummary() -> (title: String, body: String)?`（当天无 items 返回 nil）。
- 弹出层预算行：`TodayDashboardModel` 加 `var budgetRows: [(id: String, name: String, colorHex: String, spent: TimeInterval, limit: TimeInterval)]`（recompute 里 `try? model.budgetStore?...`——AppModel 持 `public var budgetStore: BudgetStore?`，post-init 赋值；enabled 预算按 spent/limit 比降序，取最紧的 2 条）；视图在 sparkline 与 Chrome 降级行之间插进度行（复用 categoryRow 的条形几何，右侧 `48m / 1h`），行下方小字 `剩 \(warnPercent)% 时提醒`。
- Consumes: Task 2 Notifying/route、Task 3 BudgetStore/settings 键、Task 7 `Format.durationDelta`。

- [ ] **Step 1: 失败测试**（BudgetTests；SpyNotifier 来自 NotifierTests 文件顶层）：

```swift
@MainActor
final class BudgetTests: XCTestCase {
    func testLevelThresholds() {
        XCTAssertEqual(BudgetEngine.level(spent: 0, limit: 3600, warnPercent: 20), .none)
        XCTAssertEqual(BudgetEngine.level(spent: 2879, limit: 3600, warnPercent: 20), .none)
        XCTAssertEqual(BudgetEngine.level(spent: 2880, limit: 3600, warnPercent: 20), .warn)   // 80%
        XCTAssertEqual(BudgetEngine.level(spent: 3600, limit: 3600, warnPercent: 20), .limit)
        XCTAssertEqual(BudgetEngine.level(spent: 100, limit: 0, warnPercent: 20), .none)       // 无效预算不炸
    }
    func testDayStampIsLocalCalendar() {
        let cal = Calendar.current
        let d = cal.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 0, minute: 5))!
        XCTAssertEqual(BudgetEngine.dayStamp(d, calendar: cal), "2026-08-24")  // 本地 0:05 不回滚昨天
    }
    func makeMonitor() throws -> (BudgetMonitor, BudgetStore, SpyNotifier, SettingsStore) {
        let db = try AppDatabase.openInMemory()
        let store = BudgetStore(db)
        let settings = SettingsStore(db)
        let spy = SpyNotifier()
        return (BudgetMonitor(budgetStore: store, settings: settings, notifier: spy), store, spy, settings)
    }
    func testWarnFiresOnceThenLimitOnce() throws {
        let (m, store, spy, _) = try makeMonitor()
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        m.evaluate(byCategory: ["entertainment": 3000], categories: cats, now: ts(0))
        m.evaluate(byCategory: ["entertainment": 3100], categories: cats, now: ts(60))   // 不重发
        XCTAssertEqual(spy.posted.count, 1)
        XCTAssertTrue(spy.posted[0].id.hasPrefix("budget.warn"))
        m.evaluate(byCategory: ["entertainment": 3700], categories: cats, now: ts(120))
        XCTAssertEqual(spy.posted.count, 2)
        XCTAssertTrue(spy.posted[1].id.hasPrefix("budget.limit"))
    }
    func testJumpingBothThresholdsFiresOnlyLimit() throws {
        let (m, store, spy, _) = try makeMonitor()
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        m.evaluate(byCategory: ["entertainment": 4000], categories: cats, now: ts(0))
        XCTAssertEqual(spy.posted.count, 1)
        XCTAssertTrue(spy.posted[0].id.hasPrefix("budget.limit"))
    }
    func testDisabledBudgetSilent() throws {
        let (m, store, spy, _) = try makeMonitor()
        try store.setBudget(categoryID: "entertainment", dailySeconds: 3600)
        try store.setEnabled(categoryID: "entertainment", enabled: false)
        let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        m.evaluate(byCategory: ["entertainment": 9999], categories: cats, now: ts(0))
        XCTAssertTrue(spy.posted.isEmpty)
    }
    func testSummaryFiresOnceAfterHourAndStamps() throws {
        let (m, _, spy, settings) = try makeMonitor()
        settings.setDailySummaryEnabled(true)
        settings.setDailySummaryHour(19)
        let cal = Calendar.current
        let before = cal.date(bySettingHour: 18, minute: 59, second: 0, of: Date())!
        let after = cal.date(bySettingHour: 19, minute: 1, second: 0, of: Date())!
        m.evaluateSummary(now: before) { ("今日小结", "x") }
        XCTAssertTrue(spy.posted.isEmpty)
        m.evaluateSummary(now: after) { ("今日小结", "x") }
        XCTAssertEqual(spy.posted.count, 1)
        XCTAssertEqual(settings.lastSummaryDay, BudgetEngine.dayStamp(after, calendar: cal))
        m.evaluateSummary(now: after.addingTimeInterval(600)) { ("今日小结", "x") }
        XCTAssertEqual(spy.posted.count, 1)     // 当天不重发
    }
    func testNilSummaryBodySkipsWithoutStamping() throws {
        let (m, _, spy, settings) = try makeMonitor()
        settings.setDailySummaryEnabled(true)
        let now = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: Date())!
        m.evaluateSummary(now: now) { nil }     // 当天无数据 → 不发不盖戳
        XCTAssertTrue(spy.posted.isEmpty)
        XCTAssertNil(settings.lastSummaryDay)
    }
}
```

授权与盖戳的裁定（executor 照此实现，不再纠结）：`evaluate`/`evaluateSummary` 不查询授权状态（同步函数无法 await）；post 后即盖戳。未授权期间系统静默丢弃通知、事件不补发——接受此简化，spec §8 的「被拒后设置里显示引导」是唯一的用户可见恢复路径。

- [ ] **Step 2: 确认失败 → 实现 BudgetEngine + BudgetMonitor**（照 Interfaces 与裁定）。
- [ ] **Step 3: 组装 + 面板 + 弹出层行 + 路由**（照 Interfaces）。
- [ ] **Step 4: 全量测试 + `make install` 手动 QA**：设个 15m 娱乐预算刷 B 站触发预警/上限通知、点通知落设置·预算、19:00 小结（把 hour 临时调到下一整点验证）。**提交** `git commit -m "feat: C4 budgets -- engine, monitor on refreshMenu, daily summary, budget pane, popover budget row, notification routing"`

### Task 12: C4 专注会话——状态机、软/硬拦截、HUD、拦截页、时间轴区块

本批最大任务。内部仍按「纯逻辑 TDD → 系统副作用手动 QA」分层。

**Files:**
- Create: `Sources/TimeSinkKit/Tracking/FocusSessionController.swift`
- Create: `Sources/TimeSinkKit/Tracking/ChromeBlocker.swift`
- Create: `Sources/TimeSinkKit/UI/FocusViews.swift`（弹出层配置/进行态 + HUD 内容视图 + HUD 窗口控制器）
- Modify: `Sources/TimeSinkKit/Tracking/TrackerEngine.swift`（focusInterceptor seam）
- Modify: `Sources/TimeSinkKit/App/AppModel.swift`（`public var focusStore: FocusSessionStore?` / `public var focus: FocusSessionController?`，post-init 赋值，注入惯例同 Task 10）
- Modify: `Sources/TimeSinkKit/App/TimeSinkApp.swift`（组装、终止关会话、timesink:// 处理）
- Modify: `Sources/TimeSinkKit/UI/MenuBarDashboard.swift`（开始专注按钮 + 配置/进行态切换）
- Modify: `Sources/TimeSinkKit/UI/ActivitiesView.swift` / `TimelineView.swift`（专注区块）
- Modify: `packaging/Info.plist`（CFBundleURLTypes: timesink）
- Test: `Tests/TimeSinkKitTests/FocusSessionTests.swift`（新建）+ `TrackerEngineTests.swift` 追加

**Interfaces:**

```swift
// FocusSessionController.swift
/// per-app 隐藏冷却 + 5 分钟放行，纯值类型（ChromeThrottle 同款可测形状）
public struct FocusBlockPolicy: Sendable {
    public var cooldown: TimeInterval = 10
    public var allowance: TimeInterval = 300
    private var lastHidden: [String: Date] = [:]
    private var allowedUntil: [String: Date] = [:]
    public init()
    public mutating func shouldHide(_ key: String, at date: Date) -> Bool
        // 未被放行 && 距上次隐藏 >= cooldown；true 时记录 lastHidden
    public mutating func allow(_ key: String, at date: Date)        // allowedUntil[key] = date + allowance
    public func isAllowed(_ key: String, at date: Date) -> Bool
}

@MainActor @Observable
public final class FocusSessionController {
    public struct Running: Equatable {
        public var id: Int64
        public var start: Date
        public var plannedSeconds: Int
        public var blockedApps: Set<String>
        public var blockedCategories: Set<String>
    }
    public private(set) var running: Running?
    public private(set) var remaining: TimeInterval = 0
    public private(set) var appBlocks = 0
    public private(set) var siteBlocks = 0

    // 注入（TimeSinkApp 组装）：
    public var notifier: (any Notifying)?
    public var categoryForDomain: ((_ domain: String, _ url: String?) -> String)?   // 包 resolver
    public var hideApp: ((String) -> Void)?        // 生产 = NSRunningApplication 查找 + hide()（轮询 isHidden，不信返回值）
    public var redirectChrome: ((String) -> Bool)? // 生产 = ChromeBlocker.setActiveTabURL
    public var showHUD: ((_ appName: String, _ hideCount: Int) -> Void)?
    public var onFinish: ((_ completed: Bool, _ appBlocks: Int, _ siteBlocks: Int) -> Void)?  // 发结束通知 + 刷时间轴

    public init(store: FocusSessionStore, settings: SettingsStore)
    public func start(minutes: Int) throws     // 读 settings 的拦截清单快照进 Running；插库；起 1s UI timer；请通知权限（若未曾）
    public func finish(completed: Bool)        // 幂等；终写库；onFinish；清态
    /// 引擎每 tick 调（见 engine seam）。返回 true = 本 tick 不记录该 sample（拦截页）。
    public func intercept(sample: Sample, at now: Date) -> Bool
    public func allowDomain(_ domain: String)  // 拦截页「放行 5 分钟」
    public func keepFocusTapped(appKey: String, at now: Date)  // HUD 按钮；0.4s 内二连 = allow(appKey)
    // 内部：tick(now:) internal（1s timer 的薄壳）供测试注入时刻；30s 持久心跳（store.heartbeat）
    // 纯静态：nonisolated static func remainingSeconds(start:planned:now:) -> TimeInterval
}

// TrackerEngine 追加 seam：
var focusInterceptor: ((Sample, Date) -> Bool)?
// tick 里 sample guard 之后、Chrome 分支之前：
//   if focusInterceptor?(sample, now) == true { return }

// ChromeBlocker.swift（独立实例——绝不共享 ChromeSampler 的节流/backoff：拦截失败
// 冒充权限告警是 A2 修过的 bug 类型；也绝不把失败喂给 chromeBackoff）
@MainActor public final class ChromeBlocker {
    public init()
    /// 前台窗口活动标签重定向；写前必须先 sb.timeout = 60（60 tick = 1s，坑同 ChromeSampler:30）。
    @discardableResult public func setActiveTabURL(_ urlString: String) -> Bool
}

// 拦截页（FocusViews.swift 内 enum FocusBlockPage）
static func ensureWritten() -> URL   // Application Support/TimeSink/blocked.html，首次写入
static let pageMarkerTitle = "TimeSink 拦截页"
// HTML：深色居中卡片，标题「专注中，此站点已被拦截」，副行由 query 参数渲染（?domain=x&remaining=mm:ss，JS 读 location.search），
// 两个按钮：<a href="timesink://focus/back">返回工作</a>、<a href="timesink://focus/allow?domain=x">放行 5 分钟</a>
```

- 拦截决策（`intercept` 体内，顺序即语义）：
  1. `running == nil` → false。
  2. sample.url 以拦截页 file URL 前缀开头，或 windowTitle == pageMarkerTitle → **true**（拦截页自身不入库——统计污染门）。
  3. `settings.focusAppBlockEnabled` && sample.appBundleID ∈ blockedApps && policy.shouldHide → `hideApp?(bundleID)` + `appBlocks += 1` + `showHUD?(appName, appBlocks)` → false（隐藏前的残余采样如实记录）。
  4. `settings.focusSiteBlockEnabled` && appBundleID == Chrome && let domain = sample.url 派生（sample 已带 url；domain 用 `DomainParser.domain(from:)`）&& `categoryForDomain(domain, url)` ∈ blockedCategories && !policy.isAllowed(domain) → `redirectChrome?(blockPageURL + query)` 成功则 `siteBlocks += 1` → false。
  5. 非 Chrome 浏览器（bundleID ∈ {com.apple.Safari, org.mozilla.firefox, company.thebrowser.Browser, com.microsoft.edgemac}）且 siteBlock 开 → 每会话一次 `showHUD?(appName + "（无法拦截该浏览器的网站）", ...)` 降级提示 → false。
- `timesink://` 处理：`TimeSinkAppDelegate` 实现 `application(_:open:)`：`focus/back` → `blocker.setActiveTabURL("chrome://newtab")`（关标签的 AE 语义不稳，重定向新标签页是诚实降级，交互稿允许语义差异记入 QA 清单）；`focus/allow?domain=x` → `controller.allowDomain(x)` + back 同款重定向回原站？——**裁定**：放行后重定向到 `https://\(domain)`。Info.plist 加：

```xml
<key>CFBundleURLTypes</key>
<array><dict>
    <key>CFBundleURLName</key><string>com.alllllenshi.TimeSink</string>
    <key>CFBundleURLSchemes</key><array><string>timesink</string></array>
</dict></array>
```

- HUD（FocusViews.swift）：`FocusHUDController`（@MainActor，持一个 NSPanel：`styleMask [.nonactivatingPanel, .hudWindow]`、`level = .floating`、`collectionBehavior .canJoinAllSpaces`，右上角定位，NSHostingView 内容：`专注中 mm:ss · \(appName) 已被隐藏（第 n 次）` + 「坚持专注」「结束会话」按钮，4s 自动收起）。「坚持专注」调 `controller.keepFocusTapped`（0.4s 双击窗口判定在 controller 纯逻辑里）；「结束会话」调 `finish(completed: false)`。
- 弹出层（MenuBarDashboard）：`@State private var popoverMode: PopoverMode = .dashboard`（`enum PopoverMode { case dashboard, focusConfig }`）。常态底栏上方插全宽「开始专注」按钮（`model.focus?.running == nil` 时）→ `.focusConfig`：时长 chips（15/25/45/90，选中写 `setFocusDurationMinutes` 记忆）、应用/网站拦截两组 Toggle + chips 摘要（清单在设置·预算维护，此处只读展示 + 「编辑…」跳设置）、「开始 · N 分钟」/「取消」。`running != nil` 时整个弹出层顶部换进行态块：大倒计时（`controller.remaining` 走 controller 自己的 1s 观察路径，**不触 dataChanged**）、`已拦下 \(appBlocks + siteBlocks) 次分心`、被拦 chips、「结束会话」。菜单栏 label：`MenuBarLabel` 加分支——`model.focus?.running != nil` 时文本换 `mm:ss`（`Text(timerInterval:)` 或手排 remaining）并 `.foregroundStyle(.tint)`。
- 结束通知（onFinish 接线，TimeSinkApp 组装处）：completed → title `专注会话结束`，body `\(planned/60) 分钟完成，期间拦下 \(n) 次分心（\(site) 次网站 · \(app) 次应用）。`；手动结束 → body 前缀改 `提前结束，`。route `.activitiesToday`。同时 `model.dataChanged()` 一次让时间轴出区块（显式用户动作，允许直调）。
- 时间轴区块：`ActivitiesModel` 加 `var focusBlocks: [TimelineBlock]`（recompute 里 `try? model.focusStore?.sessions(overlapping: interval)` 映射；tooltip `专注 \(Format.duration(end-start)) · 拦下 n 次分心 · 期间分 P`，P = 对该区间 `Aggregator.clippedToElapsed` 裁剪当日 items 后 `Aggregator.pulse`）；`DayTimelineView` 加 `focusBlocks: [TimelineBlock] = []` 参数，渲染为虚线描边空心圆角矩形（`strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4,3]))`，tint 色，叠在活动列之上）。
- 终止路径：`applicationShouldTerminate` 在 `engine?.stop()` 后加 `focus?.finish(completed: false)`（appDelegate 加 `var focus: FocusSessionController?`；幂等——弹出层退出按钮已 stop 过引擎，finish 再次调用无害）。启动恢复：无需处理——库里 completed=false 的行 end 停在最后心跳，天然是「已结束」形态（spec §9 裁定）。
- Consumes: Task 2 Notifying、Task 3 FocusSessionStore/settings 键、Task 6 MenuBarLabel、Task 11 预算面板的清单编辑。

- [ ] **Step 1: 失败测试**（FocusSessionTests，纯逻辑全覆盖）：

```swift
final class FocusBlockPolicyTests: XCTestCase {
    func testCooldownGates() {
        var p = FocusBlockPolicy()
        XCTAssertTrue(p.shouldHide("a", at: ts(0)))
        XCTAssertFalse(p.shouldHide("a", at: ts(5)))    // 冷却内
        XCTAssertTrue(p.shouldHide("a", at: ts(11)))
        XCTAssertTrue(p.shouldHide("b", at: ts(5)))     // 键独立
    }
    func testAllowanceSuppressesAndExpires() {
        var p = FocusBlockPolicy()
        p.allow("a", at: ts(0))
        XCTAssertTrue(p.isAllowed("a", at: ts(299)))
        XCTAssertFalse(p.isAllowed("a", at: ts(301)))
        XCTAssertFalse(p.shouldHide("a", at: ts(100)))  // 放行期内不隐藏
    }
}
@MainActor
final class FocusSessionControllerTests: XCTestCase {
    func makeController() throws -> (FocusSessionController, FocusSessionStore, SettingsStore) { /* openInMemory */ }
    func testStartPersistsAndCountsDown() throws {
        let (c, store, settings) = try makeController()
        settings.setFocusBlockedApps(["com.hnc.Discord"])
        try c.start(minutes: 25)
        XCTAssertNotNil(c.running)
        XCTAssertEqual(c.running!.plannedSeconds, 1500)
        XCTAssertEqual(try store.sessions(overlapping: .init(start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(60))).count, 1)
        XCTAssertEqual(FocusSessionController.remainingSeconds(start: ts(0), planned: 1500, now: ts(100)), 1400)
    }
    func testInterceptSkipsBlockPageSample() throws {
        let (c, _, _) = try makeController()
        try c.start(minutes: 25)
        let s = Sample(timestamp: ts(0), appBundleID: "com.google.Chrome", appName: "Chrome",
                       windowTitle: FocusBlockPage.pageMarkerTitle, url: nil)
        XCTAssertTrue(c.intercept(sample: s, at: ts(0)))
    }
    func testInterceptHidesBlockedAppWithCooldown() throws {
        let (c, _, settings) = try makeController()
        settings.setFocusBlockedApps(["com.hnc.Discord"])
        var hidden: [String] = []
        c.hideApp = { hidden.append($0) }
        c.showHUD = { _, _ in }
        try c.start(minutes: 25)
        let s = Sample(timestamp: ts(0), appBundleID: "com.hnc.Discord", appName: "Discord", windowTitle: nil, url: nil)
        XCTAssertFalse(c.intercept(sample: s, at: ts(0)))   // 记录照常
        XCTAssertEqual(hidden, ["com.hnc.Discord"])
        _ = c.intercept(sample: s, at: ts(3))
        XCTAssertEqual(hidden.count, 1)                      // 冷却内不再 hide
        XCTAssertEqual(c.appBlocks, 1)
    }
    func testInterceptRedirectsBlockedCategoryDomain() throws {
        let (c, _, settings) = try makeController()
        settings.setFocusBlockedCategories(["entertainment"])
        c.categoryForDomain = { domain, _ in domain == "bilibili.com" ? "entertainment" : "misc" }
        var redirected: [String] = []
        c.redirectChrome = { redirected.append($0); return true }
        try c.start(minutes: 25)
        let s = Sample(timestamp: ts(0), appBundleID: "com.google.Chrome", appName: "Chrome",
                       windowTitle: "B 站", url: "https://bilibili.com/video/x")
        XCTAssertFalse(c.intercept(sample: s, at: ts(0)))
        XCTAssertEqual(redirected.count, 1)
        XCTAssertEqual(c.siteBlocks, 1)
        c.allowDomain("bilibili.com")
        _ = c.intercept(sample: s, at: ts(10))
        XCTAssertEqual(redirected.count, 1)                  // 放行期内不再重定向
    }
    func testDoubleTapKeepFocusAllows() throws {
        let (c, _, settings) = try makeController()
        settings.setFocusBlockedApps(["a"])
        try c.start(minutes: 25)
        c.keepFocusTapped(appKey: "a", at: ts(0))
        c.keepFocusTapped(appKey: "a", at: ts(0.3))          // 0.4s 内二连
        var hidden = 0
        c.hideApp = { _ in hidden += 1 }
        let s = Sample(timestamp: ts(1), appBundleID: "a", appName: "A", windowTitle: nil, url: nil)
        _ = c.intercept(sample: s, at: ts(1))
        XCTAssertEqual(hidden, 0)                             // 已放行
    }
    func testFinishIsIdempotentAndReportsCounts() throws {
        let (c, store, _) = try makeController()
        var finishes: [(Bool, Int, Int)] = []
        c.onFinish = { finishes.append(($0, $1, $2)) }
        try c.start(minutes: 25)
        c.finish(completed: true)
        c.finish(completed: true)
        XCTAssertEqual(finishes.count, 1)
        XCTAssertNil(c.running)
        let row = try store.sessions(overlapping: .init(start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(60)))[0]
        XCTAssertTrue(row.completed)
    }
}
// TrackerEngineTests 追加
@MainActor func testFocusInterceptorSkipsRecording() throws {
    // engine.focusInterceptor = { _, _ in true } + windowSampleProvider 喂 sample
    // → tick 后 builder.current 仍 nil（未 ingest）
}
```

- [ ] **Step 2: 确认失败 → 实现 FocusBlockPolicy + FocusSessionController 纯层**（不含 HUD/blocker 生产实现），测试全绿。1s UI timer 照 TrackerEngine 的 `Timer + MainActor.assumeIsolated` 形状；timer 薄壳只调 `tick(now: Date())`；`tick` 内更新 remaining、每 30s `store.heartbeat`、归零 `finish(completed: true)`。
- [ ] **Step 3: 生产副作用实现**。`hideApp` 生产闭包（TimeSinkApp 组装处）：`NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.hide()`——不检查返回值（实测撒谎），不轮询重试（冷却已限频）。ChromeBlocker 照 Interfaces（`@objc fileprivate protocol` 声明可写 `URL`，`extension SBObject`）。FocusBlockPage HTML 写入 + timesink:// delegate 处理。HUD 控制器。engine seam 一行。
- [ ] **Step 4: UI**。弹出层三态、label 倒计时、时间轴 focusBlocks、结束通知接线、`applicationShouldTerminate` 关会话。
- [ ] **Step 5: 全量测试 + `make install` 手动 QA**（完整闭环：配置 → 开始 → 切 Discord 被隐藏 + HUD → Chrome 开 B 站被重定向 → 拦截页两按钮 → 倒计时归零 → 结束通知 → 活动页虚线区块 + 悬停）。**提交** `git commit -m "feat: C4 focus sessions -- state machine, app soft-block with HUD, Chrome category hard-block with local block page, timeline blocks"`

### Task 13: C1+ 仪表盘 hover 下钻与点击深入

**Files:**
- Create: `Sources/TimeSinkKit/UI/PanelHost.swift`
- Create: `Sources/TimeSinkKit/UI/DrillDownViews.swift`
- Modify: `Sources/TimeSinkKit/UI/MenuBarDashboard.swift`（悬停面接线 + 点击路由）
- Modify: `Sources/TimeSinkKit/App/AppModel.swift`（导航助手）
- Test: `Tests/TimeSinkKitTests/TodayDashboardModelTests.swift` 追加（分数构成纯函数）

**Interfaces:**

```swift
// AppModel 导航助手（弹出层与通知路由共用）
public func openStats(range: DateRangeSelection)      // range + sidebar 赋值；开窗由调用方 openWindow
public func openActivities(category: String?, range: DateRangeSelection)

// TodayDashboardModel 追加纯函数（下钻内容的数据）
/// 分数构成：每分类 (name, colorHex, seconds, points, weightedShare)，按贡献降序。
nonisolated static func scoreContributions(byCategory: [String: TimeInterval], categories: [String: Category])
    -> [(id: String, name: String, colorHex: String, seconds: TimeInterval, points: Double, share: Double)]

// PanelHost.swift
@MainActor final class PanelHost {
    /// anchorFrame 为屏幕坐标；取不到宿主窗口时 show 返回 false —— 调用方落到
    /// 弹出层内展开的降级实现（spec §10 允许的替代验收）。
    @discardableResult func show<Content: View>(_ content: Content, near anchorFrame: CGRect) -> Bool
    func scheduleClose(after delay: TimeInterval)   // 默认 0.25s；再次 show/hover 取消
    func cancelScheduledClose()
    func closeNow()
}
// 悬停接线模式（MenuBarDashboard 内私有 modifier）：
// .drillDown(host:) { DrillView(...) } = onHover(true → 0.15s 后 show，false → scheduleClose)
//   + GeometryReader 拿局部 frame + WindowAccessor（NSViewRepresentable 存 view.window）换屏幕坐标
// NSPanel 参数：nonactivatingPanel、.popUpMenu level、hidesOnDeactivate = false、
//   isFloatingPanel；弹出层 onDisappear → host.closeNow()（随弹出层关闭一并消失）
// 降级：WindowAccessor 拿不到 window（返回 false）→ @State expandedDrill: DrillKind? 就地展开同内容
```

七个悬停面 → 下钻内容（DrillDownViews.swift，全部只读现有数据，无新查询——数据源标注）：

| 悬停面 | 子窗内容 | 点击深入 |
|---|---|---|
| 分数环 | ScoreBreakdownView：`scoreContributions` 列表（色点+名+时长×权重→贡献），底行较昨日 | `openStats(range: .today())` + openWindow |
| 专注/总计行 | CompareBaseView：文案说明 Ruling 14 裁剪基准 + 昨日同时段值（dashboard 已算） | 同上 |
| 连续达标行 | StreakDotsView：30 天点阵（`Aggregator.dailyPulses` 复用缓存），≥70 实心 tint | `openStats(range: DateRangeSelection(kind: .last30, anchor: Date()))` |
| 分类行（每行） | CategoryDetailView：该分类今日逐小时条（today items 过滤后 `profileByHourOfDay`）+ Top5 子条目（domain/app） | `openActivities(category: id, range: .today())` |
| 24h 迷你图 | HourlyBigView：分类堆叠柱（`stackedSeries(bucket:.hour)`）+ 今天/近7天 segmented + 逐小时 `.help("14 时 · 34m · 分 78")` | 无（子窗即终点） |
| 预算行 | BudgetProgressView：全部启用预算进度条 | `model.settingsTab = .budget` + openSettings |
| （常态各行通用） | —— | 交互总表逐行照抄 |

- [ ] **Step 1: 失败测试**：

```swift
func testScoreContributions() {
    let cats = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
    let rows = TodayDashboardModel.scoreContributions(
        byCategory: ["softwareDev": 3600, "entertainment": 1800], categories: cats)
    XCTAssertEqual(rows[0].id, "softwareDev")                 // 贡献降序
    XCTAssertEqual(rows[0].points, 100)                       // +2 → 100
    XCTAssertEqual(rows[0].share, 3600.0/5400.0, accuracy: 0.001)
    XCTAssertEqual(rows[1].points, 0)                         // -2 → 0
}
```

- [ ] **Step 2: 确认失败 → 实现纯函数**，转绿。
- [ ] **Step 3: PanelHost + WindowAccessor + drillDown modifier + 七个内容视图**（照表）。先在真机验证 NSPanel 定位路径；`show` 返回 false 的降级路径必须真实现（不是空分支）：`expandedDrill` 状态在弹出层对应区块下方就地插入同一内容视图 + 「收起」。
- [ ] **Step 4: 点击路由接线**（表右列；分类行/分数环等 onTapGesture 与既有 hover 不冲突——按钮语义的行用 Button 包裹）。
- [ ] **Step 5: 全量测试 + `make install` 手动 QA**（七个悬停面逐个：出现/0.25s 收/子窗内悬停保持/弹出层关闭连带消失；点击深入逐行对交互总表）。**提交** `git commit -m "feat: C1+ dashboard drill-down subwindows (NSPanel with in-popover fallback) and click-through navigation"`

### Task 14: 收尾——文档、ADR、QA 清单、终审入口

**Files:**
- Modify: `docs/superpowers/specs/2026-08-23-timesink-design.md`（§5 修订注）
- Modify: `README.md`（新功能 + 新权限说明）
- Create: `~/Documents/Obsidian Vault/timesink/decisions/0001-title-rules-reversal.md`（vault ADR，不入 repo）
- Modify: `Sources/TimeSinkKit/UI/SettingsView.swift` 等处 doc comment 核对

**Steps:**

- [ ] **Step 1: 旧 spec 修订注**。`2026-08-23-timesink-design.md` 第 65 行段落末尾追加一句：`（2026-08-24 修订：p1-batch2 引入受限的「标题规则」层作为用户主导的例外通道——scoped 默认、最小长度校验、影响预览三重护栏；裁定与理由见 docs/superpowers/specs/2026-08-24-timesink-p1-batch2-design.md §5。）`
- [ ] **Step 2: ADR**（vault 惯例 `decisions/NNNN-<slug>.md`）：标题「标题规则反转」，记录：原裁定及理由 → 反转动因（youtube 讲座场景 + 交互稿）→ 三重护栏 → 影响面（tier-0 无撤销）。
- [ ] **Step 3: README**。权限表加 日历（可选）/ 通知（可选）两行及用途一句话；功能列表加预算/专注/统计 2.0/标题规则；开发注意事项加「日历与通知只能在 `make install` 后验证（TCC 归因）」。
- [ ] **Step 4: 手动 QA 清单**——交互稿「交互总表」逐行过一遍并记录结果到 `.superpowers/sdd/2026-08-24-timesink-p1-batch2/manual-qa.md`（表格：元素/手势/预期/实测/结论）。降级实现处（NSPanel→就地展开、返回工作→新标签页）如实标注。
- [ ] **Step 5: 全量验证**：`swift build -c release 2>&1 | grep -c warning`（期望 0）、`swift test`（全绿，记录总数）、`make install` + 生产库冒烟（v4 迁移在真实库上执行成功、既有数据完好、新表就位——`sqlite3` 查 `PRAGMA user_version`/`sqlite_master`）。
- [ ] **Step 6: 提交** `git commit -m "docs: batch-2 wrap-up -- spec revision note, README, manual QA record"`，随后进入全分支终审（执行模式一节）。

---

## Plan Self-Review 记录

- **Spec coverage**：spec §4→Task 3；§5→Task 4/5；§6→Task 7/8；§7→Task 9/10；§8→Task 11；§9→Task 12；§10→Task 6/13；§11→Task 1/11（面板）/10（打包）；§12 测试策略分散在各 Task Step 1；§13 风险各 Task 内联。交互稿「交互总表」= Task 14 QA 清单。无缺口。
- **类型一致性核对**：`Notifying.post(id:title:body:route:)` 在 Task 2/11/12 一致；`PendingTitleRule` 仅 Task 5 内部；`FocusSessionStore.finish(id:end:appBlocks:siteBlocks:completed:)` Task 3 定义、Task 12 使用；`Aggregator.clippedToElapsed` Task 7 上提、Task 8/11/12 引用；`PermissionState` Task 1 定义、Task 2/10 引用；`SettingsTab` Task 11 定义、Task 13 引用（`model.settingsTab = .budget`）。
- **已知松弛点**（刻意保留给 executor 的自由度，非 placeholder）：Task 8 Step 1 两个测试的具体注水数值、SwiftUI 视图的确切布局代码——行为验收以交互总表为准。
- **基线数字**：正文称 75/75 为执行前基线，第一个 Task 开始时以实测 `swift test` 输出为准刷新。
