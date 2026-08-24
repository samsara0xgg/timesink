# TimeSink 设计文档

日期：2026-08-23
状态：已获用户批准（对话中逐项确认）

## 1. 目标与范围

个人用 macOS 自动时间追踪应用。回答一个问题：**我每天的专注时间有多少，时间都去哪了。**

- 布局复刻 Timing.app（参照 `docs/reference/timing-screenshots/` 中的官方 press-kit 截图）
- 网页分类能力对标 RescueTime（其优势本质是众包域名库 + 用户覆盖，非 ML；我们用种子库 + URL 规则 + 可选 LLM 兜底复刻并超越——RescueTime 不能按 URL 路径细分，我们可以）

**非目标**（明确砍掉）：Timing 的项目/规则树体系、手动计时器、时间条目（time entry）、Reports 导出、团队功能、多设备同步、iOS、Firefox/Safari 支持（只适配 Chrome）、「你刚才在干嘛」空闲补时弹窗。

## 2. 已确认的决策

| 决策 | 结论 |
|---|---|
| 技术栈 | 原生 Swift + SwiftUI，单一 .app，最低 macOS 14（开发机 macOS 26） |
| 浏览器 | 仅 Chrome |
| LLM 分类兜底 | 默认关闭（纯本地）；可选开启，走 OpenAI 兼容接口（用户已有 ChatGPT API 余额），模型用便宜档（如 gpt-4o-mini），endpoint/model 可配置 |
| 功能范围 | 自动分类 + 生产力分（RescueTime 式），无项目体系 |
| 命名 | TimeSink，目录 `~/Projects/timesink`，bundle id `com.alllllenshi.TimeSink` |

## 3. 总体架构

单进程三部分：

```
TimeSink.app
├── MenuBarExtra 菜单栏项 —— 今日专注时长 + 迷你摘要 + 打开主窗口
├── TrackerEngine (actor) —— 监听 + 1s 采样 → 合并 → 写 SQLite
└── 主窗口 (SwiftUI) —— Stats / Activities 两视图；Settings 为标准设置窗口（⌘,）
```

- 关闭主窗口后进程常驻（菜单栏），继续采集。
- `SMAppService.mainApp` 注册开机自启。
- 数据库：GRDB (SQLite, WAL 模式)，位于 `~/Library/Application Support/TimeSink/timesink.sqlite`。
- 网络调用只有一处：LLM 分类兜底（可选，默认关）。其余完全离线。

## 4. 采集引擎（与 Timing 相同的机制）

参考实现：ActivityWatch `aw-watcher-window/macos.swift`（MPL-2.0，可移植）、MacTrack / SimplyTrack（MIT）。

- **应用切换**：`NSWorkspace.didActivateApplicationNotification`（事件驱动）。
- **采样循环**：1 秒一次（Timing 同频），读前台应用 bundle id / 应用名 + 焦点窗口标题（AX API：`AXUIElementCopyAttributeValue` + `kAXFocusedWindowAttribute` / `kAXTitleAttribute`）。
- **Chrome URL**：Chrome 在前台时经 ScriptingBridge（`SBApplication`, bundle id `com.google.Chrome`）读活动标签页 URL + 标题。仅在窗口标题变化时重新查询（标题变 = 切标签/跳转），另每 5 秒兜底刷新。`window.mode == "incognito"` 时丢弃 URL 和标题。
- **空闲**：`CGEventSource.secondsSinceLastEventType(.hidSystemState, .null)`，无需权限。默认阈值 180 秒（可配置）；超时后当前 span 回溯闭合到最后输入时刻。监听 `com.apple.screenIsLocked` 分布式通知（1 秒防抖）与 `NSWorkspace.willSleepNotification` 立即闭合 span；深睡唤醒后以 `didWakeNotification` + `CGSessionCopyCurrentDictionary` 重新校准锁屏状态，不信任单独的解锁通知。
- **合并**：连续采样 (bundle id, title, url) 三元组不变 → 延长当前 span 的 `end`；变化 → 闭合旧 span、开新 span。落库节流：每 30 秒或 span 闭合时写盘。

## 5. 数据模型

```sql
spans(id, start, end, app_bundle_id, app_name, title, url, domain)
  -- url/domain 仅浏览器 span 有值；domain 冗余存储便于聚合
  -- 索引: (start), (domain), (app_bundle_id)
domain_categories(domain PK, category_id, source CHECK IN ('seed','llm','user'), updated_at)
url_rules(id, pattern, category_id, priority, source)   -- 前缀/正则匹配完整 URL
app_categories(bundle_id PK, category_id, source)
categories(id PK, name, color, productivity INTEGER CHECK BETWEEN -2 AND 2, sort_order)
settings(key PK, value)   -- idle_threshold, llm_enabled, llm_endpoint, llm_model
  -- API key 存 Keychain，不入库
```

**URL 是一等字段**——分类规则直接匹配 URL 而非窗口标题（ActivityWatch 只能对标题做正则，为其公认的架构遗憾，不重蹈）。

## 6. 分类引擎

固定 12 个顶级分类（RescueTime 式），默认生产力等级 -2..+2，名称与等级均可在 Settings 改：

软件开发(+2)、学习参考(+2)、写作创作(+2)、事务(+1)、工具(+1)、沟通(0)、新闻(-1)、购物(-1)、社交媒体(-2)、娱乐(-2)、其他(0)、未分类(0)。

**查找优先级**（自上而下，首个命中生效）：

1. 用户覆盖（`source='user'` 的 domain/app 记录，及用户建的 url_rules）
2. 内置 URL 规则层（如 `music.youtube.com`→娱乐、`docs.google.com`→写作、`mail.google.com`→沟通、`github.com`→软件开发）
3. 域名种子库：WhoTracks.me `site_categories.csv`（MIT）的 ~10 类映射到本分类表，构建期转成 SQLite 表打包进 app
4. 应用默认表：常见 Mac 应用约百条手工预置（Xcode/Terminal/微信/Steam/…）
5. LLM 兜底（可选）：`domain + 页面标题 + 分类表` → OpenAI 兼容 chat completion，结果写 `domain_categories(source='llm')`，每域名仅一次
6. 未命中 → 未分类；Settings 有「未分类清单」批量手动归类（写入即成第 1 层）

分类在**读取时解析**（span 不存分类），改分类立即全历史生效，等价 RescueTime 的重分类行为。聚合查询按需缓存。

## 7. 生产力分与专注时间

- **Productivity Pulse**（0–100）：RescueTime 官方公式，等级 -2..+2 映射 0/25/50/75/100，按时长加权平均。
- **每日专注时间** = 生产力等级 ≥ +1 的分类总时长。菜单栏常显此数字。
- 只有已记录时间参与计算（空闲/锁屏不算，无补时概念）。

## 8. UI（复刻 Timing 布局）

参照截图：`overview_30days.png`（明）、`overview_30days_dark.png`（暗）、`activities_unified.png` / `activities_with_timeline.png`。

- **窗口结构**：左侧固定侧边栏（~17% 宽）+ 右侧内容区，扁平风格、系统字体、明暗双主题（跟随系统）。
- **侧边栏**：Stats / Activities 两个导航项（图标+文字，选中为圆角灰底）；下方「分类」小节——每行彩色圆点 + 分类名 + 右对齐时长胶囊，点击过滤内容区。
- **顶栏**：日期范围导航 `‹ [今天 ▾] ›`（今天/昨天/过去 7 天/过去 30 天 + 前后翻页）。
- **Stats**（对应 Timing 的 Overview）卡片网格：
  - 第一行：总时长（大数字 + 每日均值副标题）｜最活跃星期（柱状）｜最活跃小时（柱状）
  - 第二行：生产力分（大号彩色百分比文字，非仪表盘）｜最高效星期（红绿发散柱状）｜最高效小时（红绿发散柱状）
  - 右侧双高：分类时长堆叠柱状图（按天/按周切换），色 = 分类色
  - 底部两张半宽卡：应用 donut + 排行列表（app 图标+名+时长）｜分类 donut + 排行列表
  - 全部用 Swift Charts。
- **Activities**：右侧垂直时间线（小时自上而下，色块按分类着色、高度∝时长，悬停 tooltip 显示当时的 app/标题/URL，滚轮缩放）；左侧活动列表按 分类 → 域名或应用 → 标题 三级 disclosure 分组，行尾时长右对齐；任意行右键「更改分类」（即用户覆盖）。
- **Settings**：分类编辑（名称/颜色/生产力等级）、未分类清单批量归类、URL 规则管理、空闲阈值、开机自启开关、LLM 开关 + endpoint/model/API key、权限状态与重新授权引导。

## 9. 权限、签名与运行形态

- 首次启动 onboarding：两步授权卡片——① Accessibility（`AXIsProcessTrustedWithOptions` 触发）；② Automation→Chrome（首次 Apple Events 调用时系统弹，检测 `errAEEventNotPermitted -1743` 显示状态）。
- `Info.plist`：`NSAppleEventsUsageDescription`；Hardened Runtime + Apple Events entitlement。
- **自签名证书**（Keychain Access 免费创建 Code Signing 证书）签名，保证 TCC 授权跨重编译存活（规避 ad-hoc 签名 cdhash 变化导致权限静默失效的坑）。不需要付费开发者账号。
- 常规 app（非 LSUIElement）：主窗口开着时在 Dock 显示；关窗后仅菜单栏驻留（`NSApp.setActivationPolicy` 动态切换）。

## 10. 测试策略

- **TDD 覆盖纯逻辑**（XCTest）：span 合并状态机（含 idle/锁屏/睡眠边界回溯）、分类优先级解析、URL 规则匹配、Pulse 与专注时间计算、种子库映射。
- 采集层（AX/ScriptingBridge/通知）不做自动化测试；提供 debug 面板实时打印当前采样三元组供人工验证。
- LLM 客户端以协议抽象，测试用 mock；真实调用仅手动冒烟。

## 11. 构建产物

- 纯 SPM（`Package.swift`，无 .xcodeproj），Swift 6，依赖仅 GRDB；Makefile 负责把 SPM 产物组装成 TimeSink.app（拷入 Info.plist、Resources、codesign）。全流程命令行可完成，无需 Xcode GUI。
- 构建脚本：拉取/转换 WhoTracks.me CSV → 种子 SQLite 表（构建期，不在运行时联网）。
- `make build && make install`：编译、自签名、拷入 /Applications。
