# TimeSink 第二批（p1-batch2）设计文档

日期：2026-08-24
状态：待用户审阅
基线：main @ a7373a4（p0-batch1 已合并：P0×4 + A2 + B3 + D1 + C1，75/75 测试通过）
交互规范（normative）：「TimeSink 交互稿」Artifact `https://claude.ai/code/artifact/ef355ee7-6a7b-471e-92c4-aca063f6a45e` ——其「交互总表」即实现验收标准，本文不复述逐条交互，只记录架构与裁定。
侦察依据：6 个只读审计 agent 对 main @ a7373a4 与系统 API 的实测结论（EventKit / UserNotifications / Focus API / hide() 均在本机以同签名 bundle 验证过）。

## 1. 目标与范围

本批交付交互稿定义的六块：

1. **B1** 标题规则分类（右键创建 + 规则面板 + 内置标题种子）
2. **C2** 统计 2.0（范围切换 / 环比 / 30 天趋势线 / 7×24 热力图）
3. **C3** 活动 2.0（搜索 / 日历叠加与会议标注 / 轻量实体展示）
4. **C4** 预算、提醒与专注（分类预算 + 系统通知 + 专注会话闭环）
5. **菜单栏时间文本**（三态 label）
6. **C1+** 仪表盘全面可点击化（hover 下钻子窗 + 点击深入主窗口）

**非目标**（交互稿「范围边界」定死）：B2 完整实体规则引擎、B5 项目归因、A4 麦克风/电源会议检测、系统级强制拦截、系统勿扰/专注模式联动。

**三个刻意降级**（各在 UI 留一句边界说明文案）：

- 实体展示只做已知域名（github 等）的路径级分组，展示层聚合，不建实体表；
- 会议标注只依赖日历重叠；
- 专注拦截 = 应用「隐藏 + HUD」软拦截 + Chrome 网站分类硬拦截（本地拦截页），**TimeSink 自己完成拦截，不依赖系统专注模式**（RescueTime 式）。经实测确认：macOS 上 FamilyControls/ManagedSettingsStore 不可用、INFocusStatusCenter 只读，系统级路线不存在，此降级是唯一诚实路径。

## 2. 已确认的决策

| 决策 | 结论 | 来源 |
|---|---|---|
| 批次组织 | 一份 spec + 一份 plan，单 worktree 顺序任务 | 用户 |
| 架构组织 | 聚焦组件 + 最小基础设施（方案二）：Notifier / BudgetEngine / FocusSessionController / PanelHost / Permissions 重构；其余直挂 | 用户 |
| 日历授权入口 | 活动页内联启用卡触发首次授权；设置·通用权限区加状态行；不进 onboarding、不进 canFinish | 用户 |
| 专注模式语义 | 个人定制（RescueTime 式），不碰系统专注/勿扰 API | 用户 |
| B1 反转旧裁定 | 旧 spec §5「不做标题匹配」被本批有意反转；定位为**用户主导的例外通道**（scoped 优先、最小长度校验、影响预览），而非主分类面。旧 spec 第 65 行加修订注 + 补 ADR | 用户（选入 B1 即为反转） |
| 菜单栏文本内容 | 今日**专注**时长（= 现有 `menuTitle` 语义），非总时长；等宽数字；设置·通用可关 | 交互稿 |
| 拆分出的其余设计裁定 | 见各节「裁定」段 | 本文 |

## 3. 总体架构

新增组件全部在 TimeSinkKit 单模块内：

```
TimeSink.app
├── MenuBarExtra
│   ├── label 三态（常态时长 / 专注倒计时 / 降级黄点）
│   └── 弹出层：常态仪表盘 ↔ 专注配置态 ↔ 专注进行态
│       └── PanelHost —— hover 下钻 NSPanel 子窗（7 个悬停面）
├── TrackerEngine（现有 1s 采样循环，新增 2 个闭包 seam：
│     isInMeetingProvider（会议空闲豁免）、focusGate（软/硬拦截检查点））
├── FocusSessionController（@MainActor @Observable：状态机 + 倒计时 +
│     应用 hide 循环 + ChromeBlocker 重定向 + 落盘心跳）
├── BudgetEngine（纯函数评估）+ AppModel.refreshMenu() 末尾挂载
├── Notifier 协议（SystemNotifier / NoopNotifier，bundle id 门控）
├── CalendarStore（actor，EventKit 唯一栖身处，向外只出 Sendable 值）
├── EntityParser（纯函数，github/gitlab/youtube 路径实体）
└── Permissions → PermissionState 重构（4 权限 × 1 共享行视图）
```

数据流不变：分类仍是读时计算；`AppModel.rangedSpans(for:)` 仍是唯一取数漏斗（新增 interval 重载）。**span 表 schema 与索引本批冻结**——任何新数据进新表，D1 的 EXPLAIN 回归测试必须原样通过。

## 4. 数据层：迁移 v4

一个迁移，注册在 v3 之后（`AppDatabase.swift:138`），建表用 v1 的 `db.create(table:)` DSL，播种用 v2 的 `db.execute` 惯例：

```sql
titleRule(id PK AUTOINCREMENT, pattern TEXT NOT NULL,
          scopeKey TEXT NOT NULL DEFAULT '',      -- '' = 全局；否则 domain 或 bundleID（同 span.domain ?? appBundleID 键）
          categoryID TEXT NOT NULL REFERENCES category,
          priority INTEGER NOT NULL DEFAULT 0,
          source TEXT NOT NULL,                    -- 'user' | 'builtin'
          enabled BOOLEAN NOT NULL DEFAULT 1,
          createdAt DATETIME NOT NULL)
  -- UNIQUE(pattern, scopeKey)；写入一律 upsert，不复制 addUserURLRule 的裸 INSERT 缺陷
budget(categoryID TEXT PK REFERENCES category,
       dailySeconds INTEGER NOT NULL, enabled BOOLEAN NOT NULL DEFAULT 1)
budgetAlert(categoryID TEXT NOT NULL, day TEXT NOT NULL,  -- 本地日历 "YYYY-MM-DD"，绝不用 UTC Date
            kind TEXT NOT NULL,                    -- 'warn' | 'limit'
            PRIMARY KEY(categoryID, day, kind))    -- 复合 PK 天然实现每类每天各一次
focusSession(id PK AUTOINCREMENT, start DATETIME NOT NULL (indexed),
             end DATETIME NOT NULL,                -- 开始即 = start，随心跳推进（span 同款策略）
             plannedSeconds INTEGER NOT NULL,
             appBlocks INTEGER NOT NULL DEFAULT 0,
             siteBlocks INTEGER NOT NULL DEFAULT 0,
             completed BOOLEAN NOT NULL DEFAULT 0)
```

v4 播种两组内置标题种子（enabled，可在规则面板停用）：

- `lecture|course|教程|课程|讲座` → 学习参考
- `pull request|merge request|PR #` → 软件开发

**pattern 语义裁定**：单行存竖线连接的关键词组，匹配 = 拆 `|` 后任一关键词大小写不敏感子串命中；整串带 `re:` 前缀则整体按现有正则惯例走。一行 = UI 一条规则（一组 chips，一个删除键），与交互稿的规则面板一一对应。（侦察建议一词一行；为对齐交互稿的分组删除语义弃用，记为深思后的偏离。）

**标量设置**（现有 KV，标量字符串，零 JSON）：`budgetWarnPercent`（10/20/30，默认 20）、`dailySummaryEnabled`（默认 false）、`dailySummaryHour`（默认 19）、`lastSummaryDay`、`menuBarTextEnabled`（默认 true）、`focusDurationLast`（默认 25 分钟）、`focusBlockedApps`（逗号连接 bundle id）、`focusBlockedCategories`（逗号连接 categoryID）、`calendarOverlayEnabled`。

新 store：`BudgetStore`、`FocusSessionStore`、`titleRule` CRUD 进 `CategoryStore`——全部 `throws`（CategoryStore 惯例，不用 SettingsStore 的吞错），`Sendable` over `any DatabaseWriter`。记录结构镜像 `URLRule` 的 conformance 清单。

**升级测试**：除全新建库外，必须有一条「v3 库带真实数据 → v4 升级」路径测试（现有测试全部只测全新库，这是已知盲区）。

## 5. B1 标题规则

**优先级链**（合并交互稿与现有链，写回 `Classifier` 的文档注释）：

> 1 用户标题规则 > 2 用户域名/应用修正 > 3 用户 URL 规则 > 4 内置标题种子 > 5 内置 URL 规则 > 6 精选种子 > 7 种子域名 > 8 应用映射 > 9 LLM 兜底 > 未分类

- 层 1 必须压过层 2，否则「youtube.com 整体娱乐、讲座标题学习」不成立（youtube.com/watch 是 priority 200 的内置 URL 规则，且用户可能已有 youtube.com 的 user domain 行）。
- 现有 urlRules 单数组 user-first 排序拆成两次遍历（user / builtin），零成本。
- 同层内排序：scoped 在前 > priority 降序 > id 降序（新规则优先，交互稿语义）。
- 实现：`ClassificationContext` 加 `titleRules`；`Classifier.categoryID` 加 `title: String?` 参数（**不带默认值**，强制所有调用点表态）；`if let title` 早退让无标题 span 零开销；`matches(_:url:)` 抽出 `matches(pattern:in:)` 共用，原签名保留转发。`CategoryResolver.categoryID(for:)` 传 `span.title` 后，所有下游读者自动获得标题感知。

**右键创建**（活动页 Level-3 标题行，交互稿流程）：上下文菜单「始终把此标题归为…」→ sheet：关键词输入（预填完整标题供修剪，逐词 chips）、scope 选择（默认「仅 {当前域名/应用}」，可切「所有活动」）、分类 Picker、**影响预览**（对当前范围重跑候选规则显示「将影响 N 项 · X 时长」）。校验：单关键词去空格后 ≥2 字符；`re:` 必须能编译；拒绝空。确认后 upsert → `resolver.refresh()` → `model.dataChanged()`（直接调，不走 1.5s 防抖——AppModel 现有纪律）。

**规则面板**：现有 `RulesSettingsPane` 顶部加分段 Picker「URL 规则 / 标题规则」，不加第 6 个标签页。标题规则行显示：关键词 chips + scope + 目标分类 + 来源 + 今日命中时长；user 行可删，builtin 行只可停用（enabled 开关）。

**ADR**：在 Obsidian vault `decisions/` 记录反转旧 spec §5 第 65 行的裁定；旧 spec 该行加一句修订注指向本文。风险纪律：tier-0 无撤销，靠 scoped 默认 + 最小长度 + 影响预览三重护栏。

## 6. C2 统计 2.0

**范围模型**：`DateRangeSelection.Kind` 加 `week / month / custom`（保持无关联值枚举，`CaseIterable` 与 String raw value 存活；custom 边界存两个可选属性，归一到 startOfDay 避免 Equatable 抖动触发三视图重算）。`interval` 用 `calendar.dateInterval(of:)` 对齐；`shift` 改按日历分量步进；toolbar 的 ForEach 特判 `.custom` 弹起止日期浮层。范围状态**保持全局 `AppModel.range`**（侧边栏/活动页/统计页数字一致性优先）；统计页的分段控件与活动页的 chips 都是写同一状态的入口。

**星期起点裁定**：全 app 钉死周一为一周之首（现有 Monday=0 惯例与 周一…周日 标签已是事实标准）；`DateRangeSelection` 内部用 `firstWeekday = 2` 的本地副本日历对齐 本周，不受 locale 影响。

**环比基准裁定**：`previousInterval` = 对 week/month 取上一个日历周期，对 day/last7/last30/custom 取等长紧邻前窗；当前周期未结束时，时长类 delta 用 `clippedToElapsed` 把上期裁到相同已过长度（Ruling 14 语义，防「月初必为负」），分数 delta 用未裁全期（比率不受偏置）；上期无数据则不显示。摘要卡悬停浮层说明基准。

**趋势线**：固定近 30 天锚定今天（与所选范围无关，命中菜单栏 streak 已有的缓存键，近零成本）；LineMark + 70 分 RuleMark 虚线 + streak 注记；逐点悬停十字浮层；点击 = `range` 切到该日单日。

**热力图裁定**：**固定近 30 天窗口**，不随范围切换——交互稿 mockup 标题「近 30 天」与注 4「跟随所选范围」互相矛盾，取前者：7×24 格在窄范围下退化为单行噪声，统计有效性优先。指标 = 逐格 pulse（自归一，直接复用 `scoreColor` 色带，与分数卡/仪表盘一个视觉系统）；格内追踪时长 < 15 分钟 → 降透明 + 浮层注「样本不足」。实现先试 Swift Charts `RectangleMark`，逐格 tooltip 不顺手就按 `DayTimelineView` 先例手绘 168 格 + `.help()`。

**卡片**：新增 FocusTimeCard（专注时长今天没有卡）；Total/Score/Focus 三卡加 delta chip（沉淀 `durationDelta` 到 `Format`，消灭第三份手写）。`dailyPulses` / `streak` / `clippedToElapsed` 原样上提进 `Aggregator`，`TodayDashboardModel` 留一行转发 static 保测试不动。`StatsView.topRow` 的定高 Grid 重排以容纳趋势 + 热力图。

**性能纪律**：`rangeCache` 加 LRU 上限（8 个 interval）；趋势/热力图套用 `refreshStreakIfDayChanged` 的 force-vs-day-changed 门控，不随 1.5s dataVersion 抖动重算；StatsModel 保持「只经 `rangedSpans`，自身零 DB 查询」契约；新增 `rangedSpans(for interval: DateInterval)` 原语，原方法一行委托。本月 + 上月 + 趋势 ≈ 6–9 万 span 的主线程重分类是已知热点，若实测卡顿，逃生门是每日 rollup 表——**明确不在本批做**。

## 7. C3 活动 2.0

**搜索**：内存过滤，插在 `ActivitiesModel.recompute` 取数之后、分组之前，全部下游小计自动变「命中时长」。匹配 4 字段（domain/appName/title/url）大小写不敏感子串，`nonisolated static`（internal）纯函数；`.searchable` 落工具栏；命中行「N 项 · 合计 X」；与侧边栏分类过滤**叠加**。宽范围（last7+）加 150ms 防抖 + 预小写 haystack；day 范围直接算（实测 ~5–12ms）。搜索绝不触发 `dataChanged()`。时间轴不过滤（保持全天上下文）。空态文案区分「无命中」与「无痕（隐身/未授权）」。

**实体展示**（展示层，零 schema）：`EntityParser.entity(from:domain:)` 纯函数——github/gitlab 取前两段路径（带保留路径 denylist：settings/login/apps/orgs/…，实测库里有 OAuth 长 URL 与裸 owner 页）；youtube 仅 `/@handle` `/channel/` `/c/` `/user/`（watch URL 无频道信息，明说不伪造）；其余 nil。查询串与 fragment 一律剥掉再展示。`ActivityRow` 加 `reassignKey`（保持写 domain 级覆盖，右键菜单文案注明「整站」）——实体 id 直接进 `setUserDomain` 会写永远匹配不到的垃圾行，必须隔离。共享的 `Aggregator.durationByDomainOrApp` 不动（未分类面板依赖），实体分组在 `rows(for:)` 本地做并升 internal 可测。

**日历叠加**：`actor CalendarStore` 独占 `EKEventStore`，`events(in:) async` 内部完成 EKEvent → `CalendarEvent`（Sendable 值：id/title/start/end/isAllDay/attendeeCount/isDeclined/calendarTitle/colorHex）转换，按日缓存，`.EKEventStoreChanged` 失效（独立于 dataVersion，绝不动 rangeCache）。排除订阅/生日/节假日类型日历；不做逐日历选择（记为后续项）。`recompute` 保持同步，读快照；`loadCalendar(for:) async` 在 onAppear/换日/变更时刷新。授权走 `requestFullAccessToEvents`（检查 `.fullAccess`，非弃用值）；活动页内联启用卡触发，被拒变引导（含直达系统设置链接）；`swift run` 无 bundle 环境一律先查 `Bundle.main.bundleIdentifier` 再触 EventKit。

**会议标注**：`isMeeting` = 非全天 && 未拒绝 && (参加者 ≥2 || 标题命中 sync/1:1/standup/组会)。会议时长在**合并前的原始 span** 上算（合并管线会吞掉 <30s 碎片，479/851 实测在 5s 以下），span 与事件重叠 ≥ span 时长 50% 记为会议 span，加「会议」标注徽章 + 汇总行；**不写分类、不动 Classifier**。**空闲豁免**：TrackerEngine 加 `isInMeetingProvider: (Date) -> Bool` seam（默认 false），命中会议时段时 idle 超时不触发闭合；AppModel 用 CalendarStore 当日快照接线。

**时间轴**：容器从 180pt 加宽到 ~260pt，拆活动/事件双列共享同一 hourHeight 与滚动（必须渲染在 `DayTimelineView` 内部，兄弟视图会缩放脱同步）；全天事件钉在滚动区外的顶条；事件块用日历色描边填充 + `.help()`。时间轴显示条件从 `kind == .day` 放宽为「interval 恰为一天」（修 custom 单日不显示的坑）。

## 8. C4 预算与通知

**评估挂载**：`AppModel.refreshMenu()` 末尾（它已免费持有当天 `durationByCategory`），经引擎 1.5s 防抖路径驱动，用 `didBootstrap` 旗标跳过 init 期间的首调。**不**挂 TrackerEngine.tick（引擎无 resolver，且 TimeSink 自己在前台时 tick 早退会静默停摆——挂 refreshMenu 同样受此影响，但 refreshMenu 还被弹出层打开等 UI 路径触发，覆盖面更好）。

**BudgetEngine**（纯函数 + 薄壳）：`level(spent:limit:warnPercent:) -> 0|1|2` 单调等级；壳读 budget 表 → 对比 budgetAlert 已发级别 → 只发新跨越的最高级（一次评估同时跨 warn+limit 只发 limit，不连发）→ 发通知成功后才落 `budgetAlert` 戳（先做事后盖戳，SeedImporter 惯例）。day 键 = 本地日历 `YYYY-MM-DD`。`budgetAlert` 保留 90 天，启动时清理（新发明的保留策略，库里无先例，写测试）。

**每日小结**：同一评估通道（不用 UNCalendarNotificationTrigger——排程时刻的正文会过期）：`enabled && now ≥ 今日 dailySummaryHour && lastSummaryDay != 今天` → 发（内容：专注时长、pulse 及较昨日 delta、峰值时段；复用 Aggregator + clippedToElapsed 保持口径一致）→ 盖 `lastSummaryDay`。19:00 机器锁着 → 当天稍后首次活跃评估补发；跨天不补。默认关。

**Notifier**：`protocol Notifying: Sendable { requestAuthorization() async -> Bool; post(id:title:body:route:) }`。`SystemNotifier` 中心**惰性解析**（存储属性里碰 `UNUserNotificationCenter.current()` 在无 bundle 进程直接 ObjC 异常炸测试）；构造时按 `Bundle.main.bundleIdentifier` 选真伪实现。授权在**首次启用预算或首次开始专注**时请求（标准 alert 档，用户已明确开启功能，不用 provisional）；被拒 → 设置权限区引导行，不再弹。delegate 在 `applicationDidFinishLaunching` 挂（同 bundle 门控），`willPresent` 返回 `[.banner,.list]` 保证 app 在前台也出横幅。**通知点击路由**：userInfo 带 route 枚举 → 预算通知开设置·预算，小结开统计，专注结束开活动页当日。四类文案照交互稿。

**弹出层预算行**：仅有启用预算时显示，最接近上限者优先，`TodayDashboardModel.recompute` 里算（免费复用 byCategory）。

## 9. C4 专注会话

**状态机**（`FocusSessionController`，@MainActor @Observable）：`idle → running(id, start, planned) → idle`。配置态纯 UI 态（弹出层内），时长 chips 15/25/45/90 记住上次；应用/网站拦截各自开关 + 清单（KV）。开始：插 focusSession 行（end=start）→ 请通知权限（若未曾）→ 菜单栏 label 切倒计时。运行：控制器自有 1Hz 倒计时驱动 UI（**自有 @Observable 状态，绝不走 dataChanged/dataVersion**，防抖纪律）；30s 心跳把 end 推进落盘（span 同款策略，崩溃丢秒级）；归零或手动结束同路径：终写 completed=true → 发结束通知（含拦截统计）→ label 回常态。退出经 `applicationShouldTerminate` 关闭会话（幂等，弹出层退出按钮会二次触发 stop）。启动时发现 completed=false 的行按其 end 视为已结束，不复活。

**应用软拦截**：引擎 tick 的 sample guard 之后加 `focusGate` 检查：命中被拦 bundle id → `NSRunningApplication.hide()`（**轮询 isHidden 判成败，hide() 返回值实测撒谎**）→ HUD 浮出。per-bundle 冷却 10s（ChromeThrottle 同款可测结构）防再激活拉锯。**绝不 activate TimeSink 自己**（TimeSink 前台时 sampler 返回 nil，会污染 span 归属）。HUD = 非激活浮动 NSPanel：「专注中 mm:ss · X 已被隐藏（第 n 次）｜坚持专注｜结束会话」；「坚持专注」= 收 HUD 并回到被拦前的应用；**双击**「坚持专注」= 本次放行该应用 5 分钟（交互稿验收表语义）。appBlocks 计数。

**Chrome 网站硬拦截**：独立 `ChromeBlocker`（自己的 SBApplication 实例 + 先设 timeout 再首发，60 tick = 1s 的坑已知；**绝不共享** ChromeSampler 的 backoff/节流状态——拦截失败冒充权限告警是 A2 修过的原 bug 类型）。引擎 tick 里：会话运行 && 网站拦截开 && 当前 sample 的 domain 经 resolver 命中被拦分类 → 写 `activeTab.URL` 重定向到本地拦截页。零新权限（现有 Automation 授权是 typeWildCard，覆盖写）。拦截页 = 首次使用时写入 Application Support 的本地 HTML，按钮走自定义 URL scheme `timesink://`（Info.plist 加 CFBundleURLTypes）：「返回工作」关标签，「放行 5 分钟」仅放行该域名。**拦截页自身 URL 在引擎里排除出 span 记录**（否则污染统计与未分类面板）。siteBlocks 计数。非 Chrome 浏览器在前台且网站拦截开 → 每会话一次 HUD 提示降级。

**时间轴区块**：focusSession 行在 `DayTimelineView` 画描边虚线框（注记层，不占分类色块位），悬停「专注 25m · 拦下 n 次分心 · 期间分 X」（期间分 = 会话区间内 span 的 pulse，读时算）。**专注会话不进 span 表、不进任何聚合**——只是标注；底下真实活动照常采集计分。

## 10. C1+ 菜单栏与仪表盘

**label 三态**：`HStack{ 环形图标; Text }`，等宽数字。常态 = 今日专注时长（`menuTitle`，已在每次 refreshMenu 维护）；专注中 = 控制器倒计时（1Hz 自有观察路径）；降级 = 黄点叠加（沿用 A2 chromeCaptureDegraded）。`menuBarTextEnabled` 关掉只留图标。现有 `.onAppear` 引导逻辑必须留在 label 视图上。

**hover 下钻子窗**：`PanelHost`（@MainActor）管一个非激活 NSPanel：定位贴弹出层右缘，悬停目标 0.15s 出、移开 0.25s 收，悬停子窗本体保持，弹出层关闭随之消失。七个悬停面与内容照交互稿总表：分数环（分类贡献构成）、专注/总计行（比较基准）、连续达标（30 天点阵）、分类行（该分类时段分布 + 子条目）、24h 图（大图 + 今天/近7天切换 + 逐时浮层）、预算行（全部预算进度）。**已知风险**：MenuBarExtra 的宿主窗口定位是私有布局，取不到可靠 frame 时的**降级方案 = 弹出层内展开面板**（同内容、就地展开），在 plan 里作为验收允许的替代实现，边界在实现期敲定。

**点击深入路由**：AppModel 加导航意图（`openStats(range:)` / `openActivities(category:day:)` / `openSettings(tab:)`），弹出层各元素按总表接线：分数环→统计·今天、分类行→活动页按分类筛选、连续达标→统计·趋势、预算行→设置·预算、24h 图→统计。设置深链用 openSettings environment + 选中 tab 绑定。

## 11. 设置与权限

**设置窗口**：5 → 6 个标签页（560×420 已知偏挤，标签用短词）。新「预算」pane：分类预算列表（开关/15m 步进/删除/从未设预算分类中添加）、提前预警阈值（10/20/30% 步进）、每日小结（开关 + 整点步进）、专注拦截应用清单（chips + 编辑 sheet：运行中常规应用勾选 + 手输 bundle id）、专注拦截网站分类清单（分类多选）。「规则」pane 见 §5。「通用」加菜单栏文本开关。

**Permissions 重构（先行任务）**：`PermissionState { granted, denied, notDetermined, unavailable(String) }` 统一四权限（辅助功能=必需、Chrome 自动化=推荐、日历=可选、通知=可选）；共享 `PermissionRow` 视图替换 Onboarding 与设置里两份手写三态块；`canFinish` 只看必需项。通知状态缓存（getNotificationSettings 是回调式，2s 轮询要缓存，照 TCC 缓存先例）。

**打包变更**（`packaging/Info.plist`）：`NSCalendarsFullAccessUsageDescription`（实测缺失 = 静默永久失败，必须加断言日志）、`CFBundleURLTypes`（timesink scheme）。`Package.swift` 加 `.linkedFramework("EventKit")`。Makefile 不变。

## 12. 测试策略

沿用现有裁定：纯逻辑 TDD，采集/系统层零自动化测试 + 手动 QA 清单。

- **纯函数**（nonisolated static / 独立类型）：BudgetEngine 等级与连发抑制、focus 状态机与冷却/放行算术、标题匹配与层级（youtube 讲座、user title > user domain、scope、nil title 直落、竖线组、re: 编译）、EntityParser（denylist、裸 owner、OAuth 长 URL、youtube watch→nil）、isMeeting 与 50% 重叠、DateRangeSelection 周/月/自定义/跨月 shift/previousInterval/周一对齐、热力图分桶与样本门槛、LRU 缓存上界。
- **store/迁移**：v4 建表与种子断言、v3→v4 带数据升级、budgetAlert 复合 PK 拒重、90 天清理、focusSession 心跳推进、span 索引原样（D1 EXPLAIN 回归不动）。
- **行为**：BudgetMonitor 配 SpyNotifier（先发后盖戳、锁屏补发、跨天不补）、focus 引擎 seam 联动（沿用 TrackerEngine 闭包 seam 风格）。
- **红线**：`swift test` 与 `swift run` 全程绝不触 UNUserNotificationCenter / EventKit（bundle 门控是崩溃门不是风格）；EventKit/通知/hide/AE 全部手动 QA，且日历迭代只能 `make install` 后验（TCC 归因到终端的坑已实测），plan 排期须计入。
- 手动 QA 清单 = 交互稿「交互总表」逐行过。

## 13. 风险与已知限制

| 风险 | 处置 |
|---|---|
| NSPanel 贴 MenuBarExtra 定位不可靠 | 降级为弹出层内展开（§10，验收允许） |
| 本月范围主线程重分类卡顿 | LRU + day-changed 门控先行；rollup 表是明确的批外逃生门 |
| hide() 拦截可被轻易绕过 | 产品语义即「劝阻」，HUD 文案不承诺硬拦 |
| Chrome 拦截只覆盖前台标签/仅 Chrome | UI 文案照实说明；其他浏览器 HUD 降级 |
| 日历/通知只能装包后手动验 | 任务排期含 make install 循环；权限行给引导 |
| 六标签 560pt 挤 | 短标签；实现期如溢出可整体加宽窗口（小改） |
| 旧 spec 部分描述已失真（hardened runtime、activation observer） | 本文与源码为准；不顺手修旧文档，只加 §5 修订注 |
