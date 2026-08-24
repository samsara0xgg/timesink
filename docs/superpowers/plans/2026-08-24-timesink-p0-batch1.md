# TimeSink P0 + 第一批升级 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复四个 P0 缺陷（Chrome 缓存污染、退出丢数据、全表扫描、双实例双记），并落地第一批小投入高影响升级（A2 采集超时与降级、B3 分类修正学习与种子补全、D1 共享取数、C1 菜单栏仪表盘）。

**Architecture:** 全部改动落在现有分层内：Tracking（TrackerEngine/WindowSampler/ChromeSampler）、Core（AppDatabase 迁移/CategoryStore/AppModel 缓存）、Categorization（Classifier 后缀匹配/种子 overlay）、App/UI（生命周期 + 菜单栏 popover 重写）。不引入新依赖，不改数据模型字段。

**Tech Stack:** Swift 6 / SwiftPM / GRDB / SwiftUI + Swift Charts / XCTest。

**Spec:** 范围来自 TimeSink Next 预览稿（artifact `997ab74b-7e7a-48af-bfe1-668bb0b05f9c`）中用户选定的「P0 + 第一批」；每项技术方案来自 2026-08-24 的源码级分析（workflow `wf_4ac277aa-351`）。

## Global Constraints

- Swift 6 strict concurrency；UI 与引擎类保持 `@MainActor`，与现有代码一致。
- 不新增第三方依赖（Package.swift 只有 GRDB）。
- 注释风格与现有代码一致：说明「为什么/约束」，不写「做了什么」的流水注释；现有中文 UI 文案风格保持。
- 每个 Task 结束时 `swift test` 全绿（基线 51 个测试必须保持通过）再 commit。
- 测试用 XCTest（仓库现状），文件放 `Tests/TimeSinkKitTests/`，可复用已有的 `ts()` 时间助手（TrackerEngineTests.swift 中定义，同 target 共享）。
- 无 emoji；不写时间估算。
- Commit 信息格式沿用仓库惯例：`fix:` / `feat:` 前缀 + 一句话。

---

### Task 1: 生命周期修复（P0-2 退出丢数据 + P0-4 双实例/开发库隔离）

**Files:**
- Modify: `Sources/TimeSinkKit/App/TimeSinkApp.swift`
- Modify: `Sources/TimeSinkKit/Core/AppDatabase.swift:21-32`（defaultURL）
- Modify: `README.md:50-54`（开发模式说明）
- Test: `Tests/TimeSinkKitTests/DatabaseTests.swift`（追加）

**Interfaces:**
- Consumes: `TrackerEngine.stop()`（已存在，幂等：第二次 close 返回 nil）
- Produces: `AppDatabase.databaseFileName(bundleIdentifier: String?) -> String`（Task 无下游依赖，但保持 public 以便测试）

- [ ] **Step 1: 写失败测试（数据库文件名按 bundle 身份切换）**

在 `Tests/TimeSinkKitTests/DatabaseTests.swift` 追加：

```swift
func testDatabaseFileNameSplitsDevAndProd() {
    XCTAssertEqual(AppDatabase.databaseFileName(bundleIdentifier: "com.alllllenshi.TimeSink"),
                   "timesink.sqlite")
    XCTAssertEqual(AppDatabase.databaseFileName(bundleIdentifier: nil),
                   "timesink-dev.sqlite")
    XCTAssertEqual(AppDatabase.databaseFileName(bundleIdentifier: "com.example.other"),
                   "timesink-dev.sqlite")
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter DatabaseTests 2>&1 | tail -5`
Expected: 编译失败，`databaseFileName` 不存在。

- [ ] **Step 3: 实现 databaseFileName 并接入 defaultURL**

`AppDatabase.swift`，在 `defaultURL()` 上方加：

```swift
/// "timesink.sqlite" only when running as the installed bundle;
/// bare-executable runs (`swift run`, no bundle identifier) get
/// "timesink-dev.sqlite" so dev sessions can never pollute real data
/// even if the single-instance guard is bypassed.
public static func databaseFileName(bundleIdentifier: String?) -> String {
    bundleIdentifier == "com.alllllenshi.TimeSink" ? "timesink.sqlite" : "timesink-dev.sqlite"
}
```

`defaultURL()` 最后一行改为：

```swift
return dir.appendingPathComponent(databaseFileName(bundleIdentifier: Bundle.main.bundleIdentifier))
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter DatabaseTests 2>&1 | tail -5`
Expected: PASS。

- [ ] **Step 5: 单实例守卫 + 退出收尾**

`TimeSinkApp.swift`。文件顶部 import 已有 SwiftUI/GRDB/os，另需 AppKit（`NSRunningApplication`；SwiftUI 已传递 AppKit，显式 `import AppKit` 更清晰）。

`public init()` 开头（`setActivationPolicy` 之前）加单实例守卫：

```swift
// A second launch (e.g. installed app + `swift run` dev build with the
// same bundle id, or a double-open) would run a second 1s sampler into
// the same database and double-count every span -- hand off to the
// existing instance instead.
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0 != .current }
    if let existing = others.first {
        existing.activate()
        exit(0)
    }
}
```

在 `TimeSinkApp` 结构体外（同文件底部)加 delegate：

```swift
/// The menu-bar 退出 button is the only in-app quit path that stops the
/// engine; logout, shutdown, and Cmd-Q would otherwise skip `stop()` and
/// drop up to 30s of the in-progress span (spans younger than 30s vanish
/// entirely -- they are first written at their first heartbeat). Routing
/// every termination through the delegate closes that daily loss path.
final class TimeSinkAppDelegate: NSObject, NSApplicationDelegate {
    var engine: TrackerEngine?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { engine?.stop() }
        return .terminateNow
    }
}
```

`TimeSinkApp` 内加属性并接线：

```swift
@NSApplicationDelegateAdaptor(TimeSinkAppDelegate.self) private var appDelegate
```

菜单栏 label 的现有 `.onAppear`（launch hook）里加一行：

```swift
appDelegate.engine = model.engine
```

`MenuBarContent` 的退出按钮保持不变（`model.engine.stop()` 幂等，delegate 里再走一次无害）。

- [ ] **Step 6: README 开发模式说明更新**

`README.md` 开发一节（`swift run TimeSink` 说明段）追加一句：

```
开发模式（`swift run`）使用独立的数据库文件 `timesink-dev.sqlite`，与安装版的 `timesink.sqlite` 完全隔离，因此可以和安装版同时运行而不会重复计时。
```

- [ ] **Step 7: 全量测试 + 手工验证**

Run: `swift test 2>&1 | tail -3`
Expected: 全部通过（基线 51 + 新增 1）。

手工冒烟（可选，由主会话执行）：`swift build && .build/debug/TimeSink` 短暂运行后确认 `~/Library/Application Support/TimeSink/timesink-dev.sqlite` 被创建、主库未被写入。

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "fix: stop engine on every termination path; isolate dev DB and guard single instance"
```

---

### Task 2: 采集健壮性（P0-1 Chrome 缓存污染 + A2 超时与退避）

**Files:**
- Modify: `Sources/TimeSinkKit/Tracking/TrackerEngine.swift`
- Modify: `Sources/TimeSinkKit/Tracking/WindowSampler.swift:18-26`
- Modify: `Sources/TimeSinkKit/Tracking/ChromeSampler.swift:21-30`
- Test: `Tests/TimeSinkKitTests/TrackerEngineTests.swift`（追加）

**Interfaces:**
- Consumes: `ChromeSampler.TabInfo`、`ChromeThrottle`、`Permissions.chromeAutomationStatus(ask:)`（均已存在）
- Produces:
  - `struct ChromeFetchBackoff`（TrackerEngine.swift 内，internal）：`mutating func shouldAttempt(at: Date) -> Bool`、`mutating func noteSuccess()`、`mutating func noteFailure(at: Date)`、`var consecutiveFailures: Int`、`var isDegraded: Bool`
  - `TrackerEngine.chromeCaptureDegraded: Bool`（public private(set)，Task 5 的仪表盘会读）
  - 测试缝：`TrackerEngine.windowSampleProvider: (() -> Sample?)?`、`TrackerEngine.chromeTabProvider: (() -> ChromeSampler.TabInfo?)?`、`func tick(now: Date)` 改为 internal

- [ ] **Step 1: 写失败测试（退避逻辑 + 失败清缓存）**

`Tests/TimeSinkKitTests/TrackerEngineTests.swift` 追加两个测试类：

```swift
final class ChromeFetchBackoffTests: XCTestCase {
    func testFirstTwoFailuresDoNotDelay() {
        var b = ChromeFetchBackoff()
        XCTAssertTrue(b.shouldAttempt(at: ts(0)))
        b.noteFailure(at: ts(0))
        XCTAssertTrue(b.shouldAttempt(at: ts(1)))
        b.noteFailure(at: ts(1))
        XCTAssertTrue(b.shouldAttempt(at: ts(2)))
    }

    func testThirdFailureStartsExponentialDelay() {
        var b = ChromeFetchBackoff()
        b.noteFailure(at: ts(0)); b.noteFailure(at: ts(1)); b.noteFailure(at: ts(2))
        // 3 次失败后延迟 2s：3s 时仍在退避窗口内，4s 后放行
        XCTAssertFalse(b.shouldAttempt(at: ts(3)))
        XCTAssertTrue(b.shouldAttempt(at: ts(4.1)))
    }

    func testDelayCapsAt60Seconds() {
        var b = ChromeFetchBackoff()
        for i in 0..<20 { b.noteFailure(at: ts(Double(i))) }
        XCTAssertFalse(b.shouldAttempt(at: ts(20 + 59)))
        XCTAssertTrue(b.shouldAttempt(at: ts(19 + 61)))
    }

    func testSuccessResets() {
        var b = ChromeFetchBackoff()
        for i in 0..<6 { b.noteFailure(at: ts(Double(i))) }
        XCTAssertTrue(b.isDegraded)
        b.noteSuccess()
        XCTAssertFalse(b.isDegraded)
        XCTAssertTrue(b.shouldAttempt(at: ts(6)))
    }

    func testDegradedAfterFiveConsecutiveFailures() {
        var b = ChromeFetchBackoff()
        for i in 0..<4 { b.noteFailure(at: ts(Double(i))) }
        XCTAssertFalse(b.isDegraded)
        b.noteFailure(at: ts(4))
        XCTAssertTrue(b.isDegraded)
    }
}

@MainActor
final class TrackerEngineChromeCacheTests: XCTestCase {
    private func makeEngine() throws -> (TrackerEngine, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let store = SpanStore(db)
        let engine = TrackerEngine(spanStore: store, settings: SettingsStore(db))
        return (engine, store)
    }

    private func chromeSample(at date: Date) -> Sample {
        Sample(timestamp: date, appBundleID: "com.google.Chrome",
               appName: "Google Chrome", windowTitle: "AX Title", url: nil)
    }

    func testFetchFailureFallsBackToAXTitleInsteadOfStaleURL() throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { [self] in chromeSample(at: Date()) }

        // 先成功一次：缓存 github.com
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: "https://github.com/a/b", title: "PR #1", isIncognito: false)
        }
        engine.tick(now: ts(0))
        XCTAssertEqual(engine.latestSample?.url, "https://github.com/a/b")
        XCTAssertEqual(engine.latestSample?.windowTitle, "PR #1")

        // 再失败：不得沿用旧 URL，标题回退到 AX 标题
        engine.chromeTabProvider = { nil }
        engine.tick(now: ts(1))
        XCTAssertNil(engine.latestSample?.url)
        XCTAssertEqual(engine.latestSample?.windowTitle, "AX Title")
    }

    func testIncognitoStillSuppressesTitle() throws {
        let (engine, _) = try makeEngine()
        engine.windowSampleProvider = { [self] in chromeSample(at: Date()) }
        engine.chromeTabProvider = {
            ChromeSampler.TabInfo(url: nil, title: nil, isIncognito: true)
        }
        engine.tick(now: ts(0))
        XCTAssertNil(engine.latestSample?.url)
        XCTAssertNil(engine.latestSample?.windowTitle)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ChromeFetchBackoffTests 2>&1 | tail -5`
Expected: 编译失败，`ChromeFetchBackoff` 等不存在。

- [ ] **Step 3: 实现 ChromeFetchBackoff + tick 改造**

`TrackerEngine.swift`，在 `ChromeThrottle` 下方加：

```swift
/// Exponential backoff for Chrome tab fetches. The first two consecutive
/// failures retry freely (transient hiccups); from the third on, attempts
/// are spaced 2^(n-2) seconds apart (capped at 60s) so a persistently
/// failing target -- e.g. Automation permission revoked mid-run -- is not
/// hammered with a denied Apple Event every second forever. Five
/// consecutive failures flip `isDegraded` for UI surfacing.
struct ChromeFetchBackoff {
    private(set) var consecutiveFailures = 0
    private var lastFailure = Date.distantPast

    var isDegraded: Bool { consecutiveFailures >= 5 }

    func shouldAttempt(at date: Date) -> Bool {
        guard consecutiveFailures >= 3 else { return true }
        let delay = min(60, pow(2, Double(consecutiveFailures - 2)))
        return date.timeIntervalSince(lastFailure) >= delay
    }

    mutating func noteSuccess() {
        consecutiveFailures = 0
    }

    mutating func noteFailure(at date: Date) {
        consecutiveFailures += 1
        lastFailure = date
    }
}
```

TrackerEngine 内部状态改造：

1. 删掉 `private var cachedURL: String?` 和 `private var cachedTabTitle: String?`，换成：

```swift
/// Chrome tab capture state. `.none` (fetch failed / never fetched) must
/// leave the AX window title intact and carry no URL -- the pre-fix code
/// kept applying the last successful URL forever, misattributing days of
/// browsing to one stale domain once fetches started failing.
private enum ChromeTabState {
    case none
    case tab(url: String?, title: String?)
    case incognito
}
private var chromeTabState: ChromeTabState = .none
private var chromeBackoff = ChromeFetchBackoff()

/// Test seams: when set, replace the real AX / ScriptingBridge samplers.
var windowSampleProvider: (() -> Sample?)?
var chromeTabProvider: (() -> ChromeSampler.TabInfo?)?

/// True after 5 consecutive Chrome tab fetch failures while Chrome is
/// frontmost; cleared by the next success. Read by the menu bar dashboard.
public private(set) var chromeCaptureDegraded = false
```

2. `private func tick()` 改为 `func tick(now: Date = Date())`（internal，供测试注入时间；Timer 回调改为 `self?.tick()` 不变）。函数内 `let now = Date()` 删除（参数代替）。

3. tick 的 Chrome 分支整体替换为：

```swift
if sample.appBundleID == Self.chromeBundleID {
    if throttle.shouldFetch(title: sample.windowTitle, at: now),
       chromeBackoff.shouldAttempt(at: now) {
        let fetched = chromeTabProvider.map { $0() } ?? chromeSampler.activeTab()
        if let tab = fetched {
            throttle.noteFetched(title: sample.windowTitle, at: now)
            chromeBackoff.noteSuccess()
            chromeTabState = tab.isIncognito
                ? .incognito
                : .tab(url: tab.url, title: tab.title)
        } else {
            chromeBackoff.noteFailure(at: now)
            chromeTabState = .none
            if chromeBackoff.isDegraded,
               Permissions.chromeAutomationStatus(ask: false) != 0 {
                logger.error("Chrome capture degraded: automation likely revoked")
            }
        }
        chromeCaptureDegraded = chromeBackoff.isDegraded
    }
    switch chromeTabState {
    case .tab(let url, let title):
        sample.url = url
        sample.windowTitle = title
    case .incognito:
        sample.url = nil
        sample.windowTitle = nil
    case .none:
        break // keep the AX window title; classification degrades to app-level
    }
}
```

注意 `chromeTabProvider.map { $0() } ?? chromeSampler.activeTab()` 的语义：seam 存在且返回 nil 时结果是 nil（不落到真实 sampler）。

`Permissions.chromeAutomationStatus(ask:)` 的返回类型以 `Permissions.swift` 实际签名为准（tsprobe 输出显示 0 表示已授权），若为枚举/OSStatus 相应调整比较。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter 'ChromeFetchBackoffTests|TrackerEngineChromeCacheTests' 2>&1 | tail -5`
Expected: PASS。

- [ ] **Step 5: AX 与 ScriptingBridge 超时**

`WindowSampler.swift` `focusedWindowTitle`：

```swift
private func focusedWindowTitle(pid: pid_t) -> String? {
    let appRef = AXUIElementCreateApplication(pid)
    // AX attribute reads are synchronous Mach IPC into the target app; the
    // default messaging timeout is ~6s, so a beachballing frontmost app
    // would stall every 1s tick. 250ms is ample for a healthy app.
    AXUIElementSetMessagingTimeout(appRef, 0.25)
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &window) == .success,
          let win = window else { return nil }
    let winElement = win as! AXUIElement
    AXUIElementSetMessagingTimeout(winElement, 0.25)
    var title: CFTypeRef?
    guard AXUIElementCopyAttributeValue(winElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
    return title as? String
}
```

`ChromeSampler.swift` `activeTab()` 的 guard 后加：

```swift
// SBApplication.timeout is in ticks (1/60s). Default Apple Event reply
// timeout is about a minute; a hung Chrome would freeze the app that long.
(chrome as? SBApplication)?.timeout = 60
```

- [ ] **Step 6: 全量测试**

Run: `swift test 2>&1 | tail -3`
Expected: 全部通过。既有的 TrackerEngine 相关测试（ChromeThrottle/SuspensionState）不受影响。

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "fix: clear stale Chrome tab cache on fetch failure; add AX/SB timeouts and fetch backoff"
```

---

### Task 3: 数据层（P0-3 索引 + D1 共享取数缓存）

**Files:**
- Modify: `Sources/TimeSinkKit/Core/AppDatabase.swift`（v3 迁移）
- Modify: `Sources/TimeSinkKit/App/AppModel.swift`
- Test: `Tests/TimeSinkKitTests/DatabaseTests.swift`、`Tests/TimeSinkKitTests/AppModelCacheTests.swift`（新建）

**Interfaces:**
- Consumes: `SpanStore.spans(overlapping:)`、`CategoryResolver.categorized(_:)`（已存在）
- Produces:
  - v3 迁移：`span(end)` 索引存在，`span_on_appBundleID` / `span_on_domain` 移除
  - `AppModel.rangedSpans(for range: DateRangeSelection) -> [CategorizedSpan]` 从 private 变 public（Task 5 消费）
  - 语义变化：同一 (interval) 的重复调用在两次 `dataChanged()` 之间返回缓存

- [ ] **Step 1: 确认待删索引确实无消费者**

Run: `grep -rn "appBundleID = \|domain = \|WHERE appBundleID\|WHERE domain" Sources/ --include='*.swift'`
Expected: 无任何 SQL 以 appBundleID/domain 作为 WHERE 条件（唯一 SQL 查询入口是 `SpanStore.spans(overlapping:)` 和各 Store 的全表读）。若发现消费者，保留对应索引并在 commit message 里说明。

- [ ] **Step 2: 写失败测试（迁移后的索引形态）**

`DatabaseTests.swift` 追加：

```swift
func testV3IndexesEndAndDropsUnusedIndexes() throws {
    let db = try AppDatabase.openInMemory()
    let names = try db.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'span'")
    }
    XCTAssertTrue(names.contains("span_on_end"))
    XCTAssertTrue(names.contains("span_on_start"))
    XCTAssertFalse(names.contains("span_on_appBundleID"))
    XCTAssertFalse(names.contains("span_on_domain"))
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `swift test --filter DatabaseTests 2>&1 | tail -5`
Expected: FAIL（span_on_end 不存在）。

- [ ] **Step 4: 注册 v3 迁移**

`AppDatabase.swift` migrator 中 v2 之后：

```swift
migrator.registerMigration("v3") { db in
    // Every stats refresh runs `start < ? AND end > ?`; with only the
    // `start` index a window ending at "now" matches every historical row,
    // so the query is O(total history). `end > ?` is the selective
    // predicate for recent windows. appBundleID/domain were indexed in v1
    // but no query ever filters on them (all grouping happens in memory).
    try db.execute(sql: "CREATE INDEX span_on_end ON span(\"end\")")
    try db.execute(sql: "DROP INDEX IF EXISTS span_on_appBundleID")
    try db.execute(sql: "DROP INDEX IF EXISTS span_on_domain")
}
```

（`end` 是 SQLite 关键字，加引号。）

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter DatabaseTests 2>&1 | tail -5`
Expected: PASS。

- [ ] **Step 6: 写失败测试（AppModel 取数缓存）**

新建 `Tests/TimeSinkKitTests/AppModelCacheTests.swift`：

```swift
import XCTest
@testable import TimeSinkKit

@MainActor
final class AppModelCacheTests: XCTestCase {
    private func makeModel() throws -> (AppModel, SpanStore) {
        let db = try AppDatabase.openInMemory()
        let spanStore = SpanStore(db)
        let categoryStore = CategoryStore(db)
        let resolver = CategoryResolver(categoryStore: categoryStore)
        let settings = SettingsStore(db)
        let engine = TrackerEngine(spanStore: spanStore, settings: settings)
        let model = AppModel(categoryStore: categoryStore, spanStore: spanStore,
                             settings: settings, resolver: resolver, engine: engine)
        return (model, spanStore)
    }

    private func span(start: TimeInterval, end: TimeInterval) -> Span {
        Span(start: Date(timeIntervalSinceNow: start), end: Date(timeIntervalSinceNow: end),
             appBundleID: "com.test", appName: "Test", title: nil, url: nil, domain: nil)
    }

    func testRangedSpansIsCachedUntilDataChanged() throws {
        let (model, store) = try makeModel()
        try store.insert(span(start: -600, end: -300))

        XCTAssertEqual(model.rangedSpans().count, 1)

        // 缓存生效：绕过 dataChanged 直接插入，读到的仍是旧结果
        try store.insert(span(start: -200, end: -100))
        XCTAssertEqual(model.rangedSpans().count, 1)

        // dataChanged 失效缓存后读到新数据
        model.dataChanged()
        XCTAssertEqual(model.rangedSpans().count, 2)
    }
}
```

- [ ] **Step 7: 跑测试确认失败**

Run: `swift test --filter AppModelCacheTests 2>&1 | tail -5`
Expected: FAIL（第二个断言读到 2：当前无缓存，每次都查库）。

- [ ] **Step 8: 实现 AppModel 缓存并公开 rangedSpans(for:)**

`AppModel.swift`：

1. 加属性：

```swift
/// Memoizes categorized fetches between `dataChanged()` bumps. Three
/// consumers (StatsModel, ActivitiesModel, refreshMenu) re-query on every
/// dataVersion change with overlapping ranges; without this each bump
/// costs up to 4 identical full fetch+classify passes on the main actor.
private var rangeCache: [String: [CategorizedSpan]] = [:]
```

2. `private func rangedSpans(for range:)` 改为 public，实现改为：

```swift
public func rangedSpans(for range: DateRangeSelection) -> [CategorizedSpan] {
    let interval = range.interval
    let key = "\(interval.start.timeIntervalSinceReferenceDate)-\(interval.end.timeIntervalSinceReferenceDate)"
    if let cached = rangeCache[key] { return cached }
    do {
        let spans = try spanStore.spans(overlapping: interval)
        let clipped = spans.map { span -> Span in
            var s = span
            s.start = max(s.start, interval.start)
            s.end = min(s.end, interval.end)
            return s
        }
        let result = resolver.categorized(clipped)
        rangeCache[key] = result
        return result
    } catch {
        logger.error("rangedSpans failed: \(String(describing: error))")
        return []
    }
}
```

3. `dataChanged()` 开头清缓存：

```swift
public func dataChanged() {
    rangeCache.removeAll()
    refreshMenu()
    dataVersion += 1
}
```

失效路径核对：引擎写入走 `scheduleEngineDataChanged() -> dataChanged()`；用户重分类/设置修改按现有约定直接调 `dataChanged()`（AppModel.swift:99-101 注释）。两条路径都会清缓存。`range` 切换产生新 key，天然不命中旧缓存。

- [ ] **Step 9: 跑测试确认通过 + 全量**

Run: `swift test 2>&1 | tail -3`
Expected: 全部通过。

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "fix: index span(end) for range queries; memoize ranged fetches between data changes"
```

---

### Task 4: 分类修正（B3 用户后缀匹配 + curated 种子 overlay）

**Files:**
- Modify: `Sources/TimeSinkKit/Categorization/Classifier.swift`
- Modify: `Sources/TimeSinkKit/Core/CategoryStore.swift`（importCuratedDomains）
- Modify: `Sources/TimeSinkKit/Categorization/SeedImporter.swift`
- Create: `Sources/TimeSinkKit/Resources/seed_overlay.csv`
- Test: `Tests/TimeSinkKitTests/ClassifierTests.swift`（追加）、`Tests/TimeSinkKitTests/SeedImporterTests.swift`（追加）

**Interfaces:**
- Consumes: `ClassificationContext`、`DomainEntry`、`SeedImporter.parseCSV`（已存在）
- Produces:
  - 分类优先级变为：user（后缀匹配）> urlRules > curated（后缀匹配）> seed（后缀匹配）> app > llm > uncategorized
  - `CategoryStore.importCuratedDomains(_ pairs: [(domain: String, categoryID: String)]) throws`
  - 新 source 值 `"curated"`（domainCategory.source）

- [ ] **Step 1: 写失败测试**

`ClassifierTests.swift` 追加：

```swift
func testUserOverrideCoversSubdomains() {
    // 修正 youtube.com 后，m.youtube.com 也要命中用户层，
    // 且优先于任何 URL 规则和种子
    let c = ctx(
        domains: ["youtube.com": DomainEntry(categoryID: "learning", source: "user"),
                  "m.youtube.com": DomainEntry(categoryID: "entertainment", source: "seed")],
        rules: [rule("youtube.com", "entertainment", priority: 200)]
    )
    XCTAssertEqual(
        Classifier.categoryID(appBundleID: "com.google.Chrome",
                              url: "https://m.youtube.com/watch?v=x",
                              domain: "m.youtube.com", context: c),
        "learning")
}

func testCuratedBeatsSeedButNotURLRules() {
    let c = ctx(
        domains: ["vercel.com": DomainEntry(categoryID: "softwareDev", source: "curated"),
                  "example.com": DomainEntry(categoryID: "entertainment", source: "seed")],
        rules: [rule("vercel.com/pricing", "business", priority: 100)]
    )
    // curated 后缀命中
    XCTAssertEqual(
        Classifier.categoryID(appBundleID: "b", url: "https://app.vercel.com/x",
                              domain: "app.vercel.com", context: c),
        "softwareDev")
    // URL 规则仍优先于 curated
    XCTAssertEqual(
        Classifier.categoryID(appBundleID: "b", url: "https://vercel.com/pricing",
                              domain: "vercel.com", context: c),
        "business")
}

func testSingleLabelDomainMatchesExactly() {
    // localhost 只有一个 label，旧的 >=2 后缀循环永远走不进去
    let c = ctx(domains: ["localhost": DomainEntry(categoryID: "softwareDev", source: "curated")])
    XCTAssertEqual(
        Classifier.categoryID(appBundleID: "b", url: "http://localhost:3000/",
                              domain: "localhost", context: c),
        "softwareDev")
}
```

`SeedImporterTests.swift` 追加（curated 导入不覆盖 user）：

```swift
func testCuratedImportOverwritesSeedButNotUser() throws {
    let db = try AppDatabase.openInMemory()
    let store = CategoryStore(db)
    try store.importSeedDomains([("a.com", "entertainment"), ("b.com", "entertainment")])
    try store.setUserDomain("b.com", categoryID: "learning")

    try store.importCuratedDomains([("a.com", "softwareDev"), ("b.com", "softwareDev"),
                                    ("c.com", "softwareDev")])
    let map = try store.domainMap()
    XCTAssertEqual(map["a.com"], DomainEntry(categoryID: "softwareDev", source: "curated"))
    XCTAssertEqual(map["b.com"], DomainEntry(categoryID: "learning", source: "user"))
    XCTAssertEqual(map["c.com"], DomainEntry(categoryID: "softwareDev", source: "curated"))
}
```

（若 `DomainEntry` 不是 Equatable，改为分别断言 `categoryID` 与 `source` 字段。）

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter 'ClassifierTests|SeedImporterTests' 2>&1 | tail -5`
Expected: FAIL（新行为尚不存在；`importCuratedDomains` 未定义则为编译失败）。

- [ ] **Step 3: 实现 Classifier 改造**

`Classifier.swift`：`seedSuffixMatch` 泛化并调整优先级。`categoryID(...)` 主体改为：

```swift
// 1. user override -- suffix-aware, so correcting youtube.com also
//    covers m.youtube.com. Checked before URL rules: an explicit user
//    correction must beat every automatic tier.
if let domain, let categoryID = suffixMatch(domain: domain, source: "user", context: context) {
    return categoryID
}

if let url {
    for rule in context.urlRules where matches(rule, url: url) {
        return rule.categoryID
    }
}

// 2. curated overlay outranks the WhoTracks.me seed: the upstream data
//    has zero coverage of the dev/writing ecosystem and systematic
//    mislabels that the overlay corrects.
if let domain, let categoryID = suffixMatch(domain: domain, source: "curated", context: context) {
    return categoryID
}

if let domain, let categoryID = suffixMatch(domain: domain, source: "seed", context: context) {
    return categoryID
}

if url == nil, let entry = context.appMap[appBundleID] {
    return entry.categoryID
}

if let domain, let entry = context.domainMap[domain], entry.source == "llm" {
    return entry.categoryID
}

return "uncategorized"
```

`seedSuffixMatch` 替换为：

```swift
/// Exact match first (this is what lets single-label domains like
/// `localhost` match at all), then walks suffixes dropping leftmost
/// labels down to a minimum of 2 (`com` alone is never tried).
private static func suffixMatch(domain: String, source: String, context: ClassificationContext) -> String? {
    if let entry = context.domainMap[domain], entry.source == source {
        return entry.categoryID
    }
    var labels = domain.split(separator: ".").map(String.init)
    guard labels.count > 2 else { return nil }
    labels.removeFirst()
    while labels.count >= 2 {
        let candidate = labels.joined(separator: ".")
        if let entry = context.domainMap[candidate], entry.source == source {
            return entry.categoryID
        }
        labels.removeFirst()
    }
    return nil
}
```

顶部的优先级 doc comment（Classifier.swift:22-33）同步改写为新顺序。

- [ ] **Step 4: 实现 importCuratedDomains + SeedImporter 接线**

`CategoryStore.swift` 追加：

```swift
/// Imports the curated overlay. Overwrites seed-sourced rows (the overlay
/// exists to correct them) and its own previous rows, but never a user or
/// llm row.
public func importCuratedDomains(_ pairs: [(domain: String, categoryID: String)]) throws {
    try writer.write { db in
        let now = Date()
        for pair in pairs {
            try db.execute(
                sql: """
                INSERT INTO domainCategory (domain, categoryID, source, updatedAt)
                VALUES (?, ?, 'curated', ?)
                ON CONFLICT(domain) DO UPDATE SET
                    categoryID = excluded.categoryID,
                    source = 'curated',
                    updatedAt = excluded.updatedAt
                WHERE domainCategory.source IN ('seed', 'curated')
                """,
                arguments: [pair.domain, pair.categoryID, now]
            )
        }
    }
}
```

`SeedImporter.swift` `importIfNeeded` 末尾追加 overlay 段（结构与主种子一致，独立版本键）：

```swift
importOverlayIfNeeded(categoryStore: categoryStore, settings: settings)
```

并新增：

```swift
private static let overlayVersionSettingKey = "curatedSeedVersion"

/// Same version-gated import as the main seed, for `seed_overlay.csv`
/// (curated dev/writing/productivity domains the WhoTracks.me data lacks).
@MainActor
private static func importOverlayIfNeeded(categoryStore: CategoryStore, settings: SettingsStore) {
    guard let url = Bundle.module.url(forResource: "seed_overlay", withExtension: "csv"),
          let text = try? String(contentsOf: url, encoding: .utf8),
          let bundledVersion = parseVersion(text) else { return }
    let currentVersion = settings.get(overlayVersionSettingKey).flatMap(Int.init) ?? 0
    guard bundledVersion > currentVersion else { return }
    do {
        try categoryStore.importCuratedDomains(parseCSV(text))
        settings.set(overlayVersionSettingKey, String(bundledVersion))
    } catch {
        // Leave the version unset so the import retries next launch.
    }
}
```

- [ ] **Step 5: 编写 seed_overlay.csv**

`Sources/TimeSinkKit/Resources/seed_overlay.csv`（与 seed_domains.csv 同目录，Package.swift 的资源声明按目录处理无需改动；若资源是逐文件声明则同样方式加一行）。首行 `# version: 1`，内容为以下精选清单（完整收录，一行一条 `domain,categoryID`）：

```
# version: 1
localhost,softwareDev
127.0.0.1,softwareDev
github.io,softwareDev
githubusercontent.com,softwareDev
gitlab.com,softwareDev
bitbucket.org,softwareDev
sourcegraph.com,softwareDev
vercel.com,softwareDev
netlify.com,softwareDev
railway.app,softwareDev
render.com,softwareDev
fly.io,softwareDev
supabase.com,softwareDev
planetscale.com,softwareDev
neon.tech,softwareDev
cloudflare.com,softwareDev
console.aws.amazon.com,softwareDev
console.cloud.google.com,softwareDev
portal.azure.com,softwareDev
linear.app,softwareDev
huggingface.co,softwareDev
replicate.com,softwareDev
modal.com,softwareDev
wandb.ai,softwareDev
crates.io,softwareDev
docs.rs,softwareDev
npmjs.com,softwareDev
pypi.org,softwareDev
rubygems.org,softwareDev
pkg.go.dev,softwareDev
go.dev,softwareDev
rust-lang.org,softwareDev
python.org,softwareDev
swift.org,softwareDev
kotlinlang.org,softwareDev
typescriptlang.org,softwareDev
nodejs.org,softwareDev
deno.com,softwareDev
bun.sh,softwareDev
react.dev,softwareDev
nextjs.org,softwareDev
vuejs.org,softwareDev
svelte.dev,softwareDev
tailwindcss.com,softwareDev
developer.apple.com,softwareDev
developer.mozilla.org,softwareDev
web.dev,softwareDev
docker.com,softwareDev
kubernetes.io,softwareDev
terraform.io,softwareDev
grafana.com,softwareDev
prometheus.io,softwareDev
sentry.io,softwareDev
datadoghq.com,softwareDev
circleci.com,softwareDev
jenkins.io,softwareDev
codecov.io,softwareDev
jetbrains.com,softwareDev
replit.com,softwareDev
codesandbox.io,softwareDev
stackblitz.com,softwareDev
regex101.com,softwareDev
sqlitebrowser.org,softwareDev
leetcode.com,softwareDev
codeforces.com,softwareDev
kaggle.com,softwareDev
colab.research.google.com,softwareDev
stackoverflow.com,softwareDev
stackexchange.com,softwareDev
serverfault.com,softwareDev
superuser.com,softwareDev
arxiv.org,learning
openreview.net,learning
semanticscholar.org,learning
scholar.google.com,learning
jstor.org,learning
springer.com,learning
sciencedirect.com,learning
acm.org,learning
ieee.org,learning
nature.com,learning
coursera.org,learning
udemy.com,learning
edx.org,learning
khanacademy.org,learning
brilliant.org,learning
freecodecamp.org,learning
educative.io,learning
oreilly.com,learning
roadmap.sh,learning
wolframalpha.com,learning
desmos.com,learning
quizlet.com,learning
gradescope.com,learning
crowdmark.com,learning
prairielearn.org,learning
instructure.com,learning
piazza.com,learning
wikipedia.org,learning
notion.so,writing
obsidian.md,writing
overleaf.com,writing
hackmd.io,writing
typora.io,writing
craft.do,writing
grammarly.com,writing
figma.com,writing
canva.com,writing
sketch.com,writing
excalidraw.com,writing
docs.google.com,writing
mail.google.com,communication
outlook.live.com,communication
outlook.office.com,communication
teams.microsoft.com,communication
meet.google.com,communication
slack.com,communication
discord.com,communication
telegram.org,communication
web.whatsapp.com,communication
calendar.google.com,business
drive.google.com,business
dropbox.com,business
stripe.com,business
translate.google.com,utilities
deepl.com,utilities
claude.ai,utilities
chatgpt.com,utilities
chat.openai.com,utilities
gemini.google.com,utilities
perplexity.ai,utilities
poe.com,utilities
speedtest.net,utilities
1password.com,utilities
```

- [ ] **Step 6: 跑测试确认通过 + 全量**

Run: `swift test 2>&1 | tail -3`
Expected: 全部通过。特别确认既有 `ClassifierTests`（user 精确匹配、seed 后缀）不回归。

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: suffix-aware user overrides and curated seed overlay outranking WhoTracks.me data"
```

---

### Task 5: C1 菜单栏迷你仪表盘

**Files:**
- Create: `Sources/TimeSinkKit/UI/MenuBarDashboard.swift`
- Modify: `Sources/TimeSinkKit/App/TimeSinkApp.swift`（MenuBarContent 替换为新视图）
- Test: `Tests/TimeSinkKitTests/TodayDashboardModelTests.swift`（新建）

**Interfaces:**
- Consumes:
  - `AppModel.rangedSpans(for:) -> [CategorizedSpan]`（Task 3 公开，带缓存）
  - `Aggregator.durationByCategory/pulse/focusTime/totalDuration/profileByHourOfDay/split`
  - `TrackerEngine.chromeCaptureDegraded`（Task 2）
  - `DateRangeSelection.today()`、`Format.duration`
- Produces: `TodayDashboardModel`（internal）：`recompute(model: AppModel)`；纯函数 `static func streak(dailyPulses: [Int?], threshold: Int) -> Int` 与 `static func dailyPulses(items:categories:days:endingAt:calendar:) -> [Int?]`

设计对照：预览稿 C1 mockup，去掉预算行与专注按钮（属 C4）。保留：分数环 + 环比、专注/总时长 + 环比、连续达标、Top3 分类条、24h 迷你图、底部操作行；另加 Chrome 采集降级提示行（Task 2 的 `chromeCaptureDegraded`）。

- [ ] **Step 1: 写失败测试（streak 与 dailyPulses 纯函数）**

`Tests/TimeSinkKitTests/TodayDashboardModelTests.swift`：

```swift
import XCTest
@testable import TimeSinkKit

final class TodayDashboardModelTests: XCTestCase {
    func testStreakCountsTrailingDaysAtOrAboveThreshold() {
        // 数组末位是今天
        XCTAssertEqual(TodayDashboardModel.streak(dailyPulses: [60, 72, 75, 71], threshold: 70), 3)
        XCTAssertEqual(TodayDashboardModel.streak(dailyPulses: [72, 65], threshold: 70), 0)
        XCTAssertEqual(TodayDashboardModel.streak(dailyPulses: [], threshold: 70), 0)
        // 无数据的天（nil，例如没开机）终止连续
        XCTAssertEqual(TodayDashboardModel.streak(dailyPulses: [80, nil, 75, 80], threshold: 70), 2)
    }

    func testDailyPulsesSplitsAcrossDays() {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        // 昨天一段纯生产力（softwareDev, +2 -> 100 分），今天一段纯娱乐（-2 -> 0 分）
        let categories = Dictionary(uniqueKeysWithValues: Taxonomy.categories.map { ($0.id, $0) })
        let items = [
            CategorizedSpan(span: Span(start: todayStart.addingTimeInterval(-3600),
                                       end: todayStart.addingTimeInterval(-1800),
                                       appBundleID: "a", appName: "a", title: nil, url: nil, domain: nil),
                            categoryID: "softwareDev"),
            CategorizedSpan(span: Span(start: todayStart.addingTimeInterval(600),
                                       end: todayStart.addingTimeInterval(1200),
                                       appBundleID: "b", appName: "b", title: nil, url: nil, domain: nil),
                            categoryID: "entertainment"),
        ]
        let pulses = TodayDashboardModel.dailyPulses(
            items: items, categories: categories, days: 2, endingAt: now, calendar: calendar)
        XCTAssertEqual(pulses.count, 2)
        XCTAssertEqual(pulses[0], 100) // 昨天
        XCTAssertEqual(pulses[1], 0)   // 今天
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter TodayDashboardModelTests 2>&1 | tail -5`
Expected: 编译失败（TodayDashboardModel 不存在）。

- [ ] **Step 3: 实现 TodayDashboardModel**

`Sources/TimeSinkKit/UI/MenuBarDashboard.swift`（模型与视图同文件，视图见 Step 5）：

```swift
import SwiftUI
import Charts
import Observation

/// Data for the menu-bar popover dashboard: today's numbers, deltas vs
/// yesterday, the >=70 streak, top categories, and the hourly profile.
/// Mirrors the StatsModel pattern: one `recompute` from cached
/// `AppModel.rangedSpans(for:)` fetches, no DB access of its own.
@MainActor
@Observable
final class TodayDashboardModel {
    static let streakThreshold = 70
    private static let streakLookbackDays = 30

    var pulse: Int?
    var pulseDelta: Int?
    var focus: TimeInterval = 0
    var focusDelta: TimeInterval?
    var total: TimeInterval = 0
    var streakDays = 0
    var topCategories: [(id: String, name: String, colorHex: String, seconds: TimeInterval)] = []
    var maxCategorySeconds: TimeInterval = 0
    /// 24 entries, hours of tracked time per hour-of-day.
    var hourProfile: [Double] = Array(repeating: 0, count: 24)

    func recompute(model: AppModel) {
        let calendar = Calendar.current
        let categories = model.resolver.categoriesByID

        let today = model.rangedSpans(for: .today())
        let byCategory = Aggregator.durationByCategory(today)
        pulse = Aggregator.pulse(durationByCategory: byCategory, categories: categories)
        focus = Aggregator.focusTime(durationByCategory: byCategory, categories: categories)
        total = Aggregator.totalDuration(today.map(\.span))

        let yesterdayAnchor = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let yesterday = model.rangedSpans(for: DateRangeSelection(kind: .day, anchor: yesterdayAnchor))
        let yByCategory = Aggregator.durationByCategory(yesterday)
        let yPulse = Aggregator.pulse(durationByCategory: yByCategory, categories: categories)
        let yFocus = Aggregator.focusTime(durationByCategory: yByCategory, categories: categories)
        pulseDelta = zip2(pulse, yPulse).map { $0 - $1 }
        focusDelta = yesterday.isEmpty ? nil : focus - yFocus

        topCategories = byCategory
            .compactMap { id, seconds -> (String, String, String, TimeInterval)? in
                guard let c = categories[id] else { return nil }
                return (id, c.name, c.colorHex, seconds)
            }
            .sorted { $0.3 > $1.3 }
            .prefix(3)
            .map { $0 }
        maxCategorySeconds = topCategories.first?.seconds ?? 0

        var profile = Array(repeating: 0.0, count: 24)
        for (hour, seconds) in Aggregator.profileByHourOfDay(today, calendar: calendar) {
            profile[hour] = seconds / 3600.0
        }
        hourProfile = profile

        let lookback = model.rangedSpans(for: DateRangeSelection(kind: .last30, anchor: Date()))
        streakDays = Self.streak(
            dailyPulses: Self.dailyPulses(items: lookback, categories: categories,
                                          days: Self.streakLookbackDays,
                                          endingAt: Date(), calendar: calendar),
            threshold: Self.streakThreshold)
    }

    /// Per-day pulse over the trailing `days` days (last element = the day
    /// containing `endingAt`); nil for days with no tracked time.
    static func dailyPulses(items: [CategorizedSpan], categories: [String: Category],
                            days: Int, endingAt: Date, calendar: Calendar) -> [Int?] {
        var perDay: [Date: [String: TimeInterval]] = [:]
        for item in items {
            for part in Aggregator.split(item.span, by: .day, calendar: calendar) {
                perDay[part.bucketStart, default: [:]][item.categoryID, default: 0] += part.seconds
            }
        }
        let todayStart = calendar.startOfDay(for: endingAt)
        return (0..<days).reversed().map { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                  let byCategory = perDay[day] else { return nil }
            return Aggregator.pulse(durationByCategory: byCategory, categories: categories)
        }
    }

    /// Trailing run of days (ending at the array's last element) whose pulse
    /// is >= threshold. A nil (untracked) day breaks the run.
    static func streak(dailyPulses: [Int?], threshold: Int) -> Int {
        var count = 0
        for pulse in dailyPulses.reversed() {
            guard let pulse, pulse >= threshold else { break }
            count += 1
        }
        return count
    }
}

private func zip2<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
```

依赖说明：`DateRangeSelection(kind:anchor:)` 的公开构造已能直接表达「昨天」（`.day` + 昨日锚点）与「近 30 天」（`.last30` + 今天锚点），不新增任何 API。`streakLookbackDays` 常量保持 30，与 `.last30` 窗口一致。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter TodayDashboardModelTests 2>&1 | tail -5`
Expected: PASS。

- [ ] **Step 5: 实现仪表盘视图**

同文件追加视图。布局对照预览稿 C1（分数环 78pt、右侧两行 KPI、Top3 条形、24h 迷你图、底部操作行），全部系统材质与系统动效：

```swift
/// The menu-bar popover dashboard (preview C1). Replaces the old
/// three-line text dropdown.
struct MenuBarDashboardView: View {
    let model: AppModel
    @State private var dashboard = TodayDashboardModel()
    @State private var gaugeProgress: Double = 0
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                scoreGauge
                VStack(alignment: .leading, spacing: 4) {
                    kpiLine(value: Format.duration(dashboard.focus), label: "专注",
                            delta: dashboard.focusDelta.map(Self.durationDelta))
                    kpiLine(value: Format.duration(dashboard.total), label: "总计",
                            delta: dashboard.pulseDelta.map { Self.signed($0) + " 分" })
                    if dashboard.streakDays >= 2 {
                        Text("连续 \(dashboard.streakDays) 天保持 \(TodayDashboardModel.streakThreshold) 分以上")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
            }

            if !dashboard.topCategories.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(dashboard.topCategories, id: \.id) { entry in
                        categoryRow(entry)
                    }
                }
            }

            if dashboard.total > 0 {
                sparkline
            }

            if model.engine.chromeCaptureDegraded {
                Label("Chrome 网页读取已降级，请检查自动化权限", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Divider()
            HStack {
                Button("打开 TimeSink") { openWindow(id: "main") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Text("设置") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("退出") {
                    model.engine.stop()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { refresh() }
        .onChange(of: model.dataVersion) { refresh() }
    }

    private func refresh() {
        dashboard.recompute(model: model)
        let target = Double(dashboard.pulse ?? 0) / 100.0
        if reduceMotion {
            gaugeProgress = target
        } else {
            gaugeProgress = 0
            withAnimation(.spring(duration: 0.6)) { gaugeProgress = target }
        }
    }

    private var scoreGauge: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 7)
            Circle()
                .trim(from: 0, to: gaugeProgress)
                .stroke(Self.scoreColor(dashboard.pulse),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(dashboard.pulse.map(String.init) ?? "--")
                    .font(.title2.weight(.bold)).monospacedDigit()
                Text("生产力分").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 78, height: 78)
    }

    private func kpiLine(value: String, label: String, delta: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let delta {
                Text(delta)
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(delta.hasPrefix("-") ? Color.red : Color.green)
            }
        }
    }

    private func categoryRow(_ entry: (id: String, name: String, colorHex: String, seconds: TimeInterval)) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: entry.colorHex)).frame(width: 8, height: 8)
            Text(entry.name).font(.caption).frame(width: 60, alignment: .leading)
            GeometryReader { geo in
                let ratio = dashboard.maxCategorySeconds > 0
                    ? entry.seconds / dashboard.maxCategorySeconds : 0
                Capsule().fill(Color(hex: entry.colorHex))
                    .frame(width: max(4, geo.size.width * ratio))
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 6)
            Text(Format.duration(entry.seconds))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var sparkline: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("今日分布").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text("0 – 24 时").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Chart(Array(dashboard.hourProfile.enumerated()), id: \.offset) { hour, hours in
                AreaMark(x: .value("时", hour), y: .value("时长", hours))
                    .opacity(0.16)
                LineMark(x: .value("时", hour), y: .value("时长", hours))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 40)
        }
    }

    static func scoreColor(_ pulse: Int?) -> Color {
        guard let pulse else { return .secondary }
        if pulse >= 70 { return .green }
        if pulse >= 40 { return .orange }
        return .red
    }

    private static func signed(_ v: Int) -> String { v >= 0 ? "+\(v)" : "\(v)" }
    private static func durationDelta(_ t: TimeInterval) -> String {
        (t >= 0 ? "+" : "-") + Format.duration(abs(t))
    }
}
```

前置核对：`Color(hex:)` 在 `ColorHex.swift` 中的实际构造名（可能是 `Color(hex:)` 或 `Color.fromHex` 之类），按现状调用；分数颜色阈值与 `Cards.swift` 中生产力分卡的既有映射保持一致（实现时先读该文件，如已有颜色函数则直接复用而不是重新定义 `scoreColor`）。

`TimeSinkApp.swift`：`MenuBarContent` 的 body 替换为 `MenuBarDashboardView(model: model)`（保留结构体做壳，或直接在 MenuBarExtra 里换用新视图并删除旧 MenuBarContent；二选一，删旧代码优先）。

- [ ] **Step 6: 编译 + 人工验证**

Run: `swift build 2>&1 | tail -3` 确认编译通过，然后 `swift test 2>&1 | tail -3` 全量通过。

人工验证（主会话执行）：`swift run TimeSink`（用的是 dev 库），点菜单栏图标：分数环动画扫入、环比 chip 颜色正确（无昨日数据时不显示）、Top3 条形与统计页一致、24h 迷你图形状合理、三个底部按钮可用；系统「减弱动态效果」开启时无动画。

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: menu bar mini dashboard with score gauge, deltas, streak, and hourly sparkline"
```

---

## 收尾（主会话执行）

- [ ] `swift test` 全量最终确认
- [ ] `make bundle CERT="TimeSink Dev"` 打包成功
- [ ] 合并到 main（fast-forward 优先），清理 worktree
- [ ] `make install` 重装并手工过一遍：仪表盘、退出（Cmd-Q 主窗口）后重开数据完整、`swift run` 走 dev 库

## Self-Review 记录

- **范围覆盖**：P0-1/A2 → Task 2；P0-2/P0-4 → Task 1；P0-3/D1 → Task 3；B3 → Task 4；C1 → Task 5。C4 元素（预算/专注）明确排除。
- **类型一致性**：`ChromeSampler.TabInfo` 为 Task 2 测试与实现共用；`rangedSpans(for:)` 在 Task 3 公开、Task 5 消费；`chromeCaptureDegraded` 在 Task 2 产出、Task 5 消费；`DateRangeSelection(kind:anchor:)` 现有公开构造直接表达昨天与近 30 天，无新增 API。
- **已知适配点**（实现者按源码现状微调，不视为计划缺口）：`Permissions.chromeAutomationStatus` 返回类型；`Color(hex:)` 构造名；Package.swift 资源声明方式。
