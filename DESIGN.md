---
name: "TimeSink · Refined 精修"
description: "依照指定 Refined 设计实现的原生 macOS 时间记录界面；以当前代码为准。"
colors:
  primary: "AccentColor"
  work-light: "#F6F6F7"
  work-dark: "#1B1B1D"
  panel-light: "#FFFFFF"
  panel-dark: "#252528"
  warning-light: "#C98300"
  warning-dark: "#F2AA2E"
  category-software-dev-light: "#2F6BE4"
  category-software-dev-dark: "#4D8DFF"
  category-learning-light: "#2C9A55"
  category-learning-dark: "#3CC46E"
  category-writing-light: "#0C8898"
  category-writing-dark: "#2BB8C8"
  category-business-light: "#6B50D6"
  category-business-dark: "#9580FF"
  category-utilities-light: "#6C7581"
  category-utilities-dark: "#8D96A3"
  category-communication-light: "#E27F0C"
  category-communication-dark: "#FFA23A"
  category-news-light: "#A043C4"
  category-news-dark: "#C77AE8"
  category-shopping-light: "#DB4F7B"
  category-shopping-dark: "#FF7BA2"
  category-social-media-light: "#DA4338"
  category-social-media-dark: "#FF645A"
  category-entertainment-light: "#C29406"
  category-entertainment-dark: "#F2C51C"
  category-misc-light: "#978E82"
  category-misc-dark: "#A99F92"
  category-uncategorized-light: "#B4B4BB"
  category-uncategorized-dark: "#6A6A72"
typography:
  display:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"PingFang SC\", sans-serif"
    fontSize: "34pt"
    fontWeight: 600
  focus-display:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"PingFang SC\", sans-serif"
    fontSize: "44pt"
    fontWeight: 600
  headline:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"PingFang SC\", sans-serif"
    fontSize: "22pt"
    fontWeight: 600
  onboarding-headline:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"PingFang SC\", sans-serif"
    fontSize: "22pt"
    fontWeight: 700
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"PingFang SC\", sans-serif"
    fontSize: "17pt"
    fontWeight: 600
  section:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"PingFang SC\", sans-serif"
    fontSize: "13pt"
    fontWeight: 600
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"PingFang SC\", sans-serif"
    fontSize: "13pt"
    fontWeight: 400
  supporting:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"PingFang SC\", sans-serif"
    fontSize: "12pt"
    fontWeight: 400
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, \"PingFang SC\", sans-serif"
    fontSize: "11pt"
    fontWeight: 400
rounded:
  micro: "3pt"
  chip: "5pt"
  hover: "6pt"
  field: "7pt"
  container: "10pt"
  panel: "12pt"
  vessel-bottom: "24pt"
spacing:
  chip-y: "3pt"
  tight: "6pt"
  small: "8pt"
  row: "10pt"
  section: "12pt"
  row-inset: "14pt"
  gap: "16pt"
  card: "18pt"
  focus-card: "20pt"
  work-top: "22pt"
  work-x: "24pt"
  work-bottom: "28pt"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    typography: "{typography.body}"
  button-secondary:
    typography: "{typography.body}"
  category-chip:
    typography: "{typography.label}"
    rounded: "{rounded.chip}"
    padding: "3pt 6pt"
  workspace-panel-light:
    backgroundColor: "{colors.panel-light}"
    rounded: "{rounded.panel}"
  workspace-panel-dark:
    backgroundColor: "{colors.panel-dark}"
    rounded: "{rounded.panel}"
  stat-card:
    rounded: "{rounded.panel}"
    padding: "{spacing.card}"
  keyword-editor:
    rounded: "{rounded.field}"
    padding: "7pt"
  sidebar:
    width: "212pt"
  menu-popover:
    width: "340pt"
    rounded: "{rounded.panel}"
  menu-category-row:
    height: "30pt"
    typography: "{typography.body}"
  category-vessel:
    width: "58pt"
    height: "230pt"
  focus-hud:
    width: "312pt"
    padding: "{spacing.row-inset}"
    rounded: "{rounded.panel}"
  settings:
    width: "640pt"
    height: "560pt"
  onboarding:
    width: "500pt"
    height: "470pt"
---

# Design System: TimeSink · Refined 精修

## Overview

**Creative North Star: "Refined 精修：原生、清晰、克制"**

TimeSink 的视觉世界由用户指定的 Refined 设计稿确定。界面以原生 SF / PingFang、macOS 控件与材料、紧凑的信息密度和轻量卡片组织时间记录。此文档记录当前 SwiftUI / AppKit 实现中的可复用规则；它不是另一次创意提案，也不把目标稿中尚未接入的细节写成完成事实。

浅色工作区和白色面板、深色工作区和略亮面板形成稳定层次。系统强调色表达操作和选择，分类色表达数据归属；二者各自承担语义。用户自定义分类色优先于默认自适应色板。真实的空白、暂停、未授权和缺失内容必须保持可辨认。

**Key Characteristics:**

- 原生系统字体、系统强调色、原生导航和控件。
- 自适应深浅色分类色板，保留个人颜色覆盖。
- 轻边框、温和圆角、稳定数值列和局部数据图形。
- 密集桌面布局随可用内容宽度重排，状态由真实数据决定。

权威与边界：用户选定的 [设计原始代码](docs/reference/refined/design.html) 是视觉参照；当前实现是本文件的提取依据。[PRODUCT.md](PRODUCT.md) 保留产品事实。尺寸均为 macOS 逻辑点；浏览器拦截页使用 CSS 像素。frontmatter 中的 CSS 系统色名 `AccentColor` 是原生 `Color.accentColor` / `.tint` 的可移植表达，不是固定色值。

提取依据：`Sources/TimeSinkKit/UI/RefinedStyle.swift`、`WorkspaceStyle.swift`、`MainWindow.swift`、`SidebarView.swift`、`TodayView.swift`、`MenuBarDashboard.swift`、`ActivitiesView.swift`、`ActivityListView.swift`、`StatsView.swift`、`HeatmapCard.swift`、`FocusWorkspaceView.swift`、`RefinedRulesPane.swift`、`SettingsView.swift`、`TitleRuleEditor.swift`、`OnboardingView.swift`、`FocusViews.swift`，以及浮层实现 `PanelHost.swift`。原生控件未显式定义的字体行高、边框、尺寸或焦点环不在 frontmatter 中臆造。

验收证据见 [截图清单](docs/design-audit-images/refined/manifest.json) 和 [实现记录](docs/refined-implementation.md)。复刻阶段保存了 56 张合成数据截图、摘要数字过渡视频和 120 帧时间记录；这些证据不包含真实个人活动，也不证明全部权限、通知、云端和浏览器行为已完成验收。随后合入的英文支持与更新控件尚未重录截图。

## Colors

颜色按数据和操作语义分工；精确浅色/深色值以 frontmatter 为准。

### Primary

- **系统强调色**（`primary`）：原生主操作、导航符号、选中状态、专注进度及默认时长热力图。当前 Mac 截图呈橙色，这是系统偏好，不是固定品牌色。本地浏览器拦截页在生成时分别解析 aqua / darkAqua 下的 `NSColor.controlAccentColor` 为 sRGB，并注入对应 CSS；解析失败才使用代码内的蓝色后备值。
- **提醒琥珀**（`warning-light` / `warning-dark`）：预算阈值、需要处理的分类与记录提醒。错误或权限异常也使用原生语义红色，不把红色当成装饰强调色。

### Secondary

分类色为离散的数据标识，不是可互换的装饰色。每一行对应同名 `category-…-light` / `category-…-dark` token。

| 分类 ID | 色彩角色 |
| --- | --- |
| softwareDev | 开发蓝 |
| learning | 学习绿 |
| writing | 写作青 |
| business | 事务紫 |
| utilities | 工具灰蓝 |
| communication | 沟通橙 |
| news | 新闻紫红 |
| shopping | 购物粉 |
| socialMedia | 社交红 |
| entertainment | 娱乐金 |
| misc | 杂项暖灰 |
| uncategorized | 未分类中性灰 |

### Neutral

- **工作区底色**（`work-light` / `work-dark`）：可滚动工作区和设置、引导的背景。
- **内容面板**（`panel-light` / `panel-dark`）：信息卡片、菜单面板与编辑内容底色。
- 文本、辅助文本、分隔线和部分状态底色保持 SwiftUI `.primary`、`.secondary`、`.tertiary`、`.quaternary` 语义；它们由系统外观解析，不把截图采样值固化成新的 token。

**The System Accent Rule.** 原生操作、选中导航和键盘焦点沿用 macOS 强调色；不把参考稿示例蓝色或当前截图橙色固定为品牌色。

**The Personal Palette Rule.** 只有仍匹配内置 Taxonomy 默认值的分类才经过 RefinedStyle.category 的深浅色映射；用户修改的十六进制颜色原样保留。

## Typography

**Display Font:** 系统 SF；中文由 PingFang 按系统字体回退。
**Body Font:** 同一系统字体体系，不引入额外展示字体。
**Label/Mono Font:** 数值沿用系统字形与 `monospacedDigit`，不另设等宽品牌字体。

字号层级直接来自当前使用的 `.system(size:weight:)`。系统命名字体和原生控件仍由平台管理，未强制统一行高或字距。

### Hierarchy

- **Display**（`display`）：今天和菜单栏的已记录时长主数值。
- **Focus display**（`focus-display`）：专注配置的分钟数。
- **Headline**（`headline`）：支持指标、运行中的专注倒计时；引导标题使用独立 `onboarding-headline` 的粗体权重。
- **Title**（`title`）：短对话框标题、菜单次级指标。
- **Section**（`section`）：卡片标题和当前活动标题。
- **Body**（`body`）：列表主体与主要说明。
- **Supporting**（`supporting`）：指标标签、行内操作、补充内容。
- **Label**（`label`）：时间刻度、辅助说明、分类标签和状态。

**The Stable Number Rule.** 时长、倒计时、百分比和对齐的数值列使用 monospacedDigit；时间轴先测量本地化标签宽度，再筛选刻度，保留完整时间文本。

## Layout

原生窗口与内容布局各有边界，以下值不能被误读为全局固定画布。

| 区域 | 当前实现与约束 |
| --- | --- |
| 主窗口 | 最小内容尺寸 800×580；主内容 Today / Trends 最大宽度 1500。1200×820 为主要验收内容尺寸。真实标题栏会增加捕获窗口的总高度。 |
| 侧栏 | 原生 NavigationSplitView，理想宽度 212，可在 180–250 范围内调整。 |
| 工具栏 | 原始设计目标 52；实际为原生 SwiftUI toolbar，没有硬编码主工具栏高度。保留标题、副标题、上下文操作和系统窗口控件。 |
| 工作区 | 横向内边距 24，顶部 22，底部 28，主模块间距 16。卡片内容常用 18，专注配置卡常用 20。 |
| Today | 内容宽度达到 860 时，片段列表与 300 宽上下文列并排；更窄时上下排列。初始显示 9 个近期片段。分类容器为 58×230。 |
| Activity | 层级列表在左；适用日期范围时，230 宽时间线在中；原生检查器在右，理想宽度 272，可在 260–320 调整并可关闭。分组摘要和控件用 ViewThatFits 重排。 |
| Trends | 内容宽度达到 650 时四项指标同排，否则为两列；达到 850 时分类历史与比较排名并排。热力图用 ViewThatFits 将详情从右侧移到下方，不规定伪造的固定断点。 |
| Focus | 内容宽度达到 860 时专注与限额并排，否则纵排。 |
| 菜单栏弹出层 | 宽度 340；每段水平 14、垂直 12 内边距，段内间距 10；分类行高 30。内容按状态增减。 |
| 设置 | 640×560；七个顶部标签，每个标签内容框 76×52。表单滚动容纳说明和附加设置。 |
| 引导 | 500×470；五步进度；水平 30、顶部 28、底部 22 内边距。 |
| 标题规则编辑器 | 宽度 460，内容决定高度，整体内边距 20；标题、关键词、范围、分类、影响预览和底部操作相邻。 |
| 专注 HUD | 宽度 312，内边距 14；非激活原生浮层，显示四秒后关闭。 |
| 浏览器拦截页 | 内容最大宽度 560 CSS px，小窗口保留两侧 16 px；这是独立本地 HTML 页面。 |

上述断点测量的是对应 GeometryReader 的可用内容宽度，不能用整窗宽度替代。Privacy 的日历组在初始视口以下，随原生 Form 滚动显示；该处理已被八项修正复核接受，不代表第一屏显示全部设置。

## Elevation & Depth

工作区依赖明暗层级、细分隔线和卡片间距。`workspacePanel()` 使用圆角面板和主文本色 7% 不透明度的 0.5 点边框，没有额外投影。原生侧栏、工具栏和表单沿用系统材料；Focus HUD 使用 `.regularMaterial`。AppKit 浮层与 HUD 开启 `hasShadow`，阴影形状由系统控制。

### Shadow Vocabulary

- **Native panel shadow**：`NSPanel.hasShadow = true`，用于临时浮层，不转写成猜测的 CSS 半径。
- **Browser block panel**：独立本地拦截页当前使用 `0 12px 40px #00000012` 的柔和阴影；这是该页面的已有实现，不是全部卡片的规则。

**The Tonal Panel Rule.** 工作区卡片依靠面板色、细边框和间距分层；原生浮层与窗口可保留系统阴影。

## Shapes

主要卡片和菜单使用 `panel` 圆角；标签使用 `chip`，编辑关键词的整体边界使用 `field`。小型时间条、网格和数据标记使用 `micro`，部分嵌套辅助块使用 `container`。胶囊用于进度、状态或时长选择，不能把普通矩形控件都改成胶囊。

分类容器有垂直侧壁和仅底部两角的 `vessel-bottom` 圆角，顶部不圆；数据按真实时长堆积。未分类段可叠加 HatchFill 斜纹。热力图对空白、未发生时段、选中和焦点使用不同填充或边界，不能只靠颜色表达状态。

## Components

### Buttons

原生、紧凑、明确。主动作使用 `.borderedProminent` 和系统强调色；次动作使用原生 bordered、borderless 或 link，依内容上下文决定。取消和默认动作保留键盘语义。常见正文 token 是 `body`，小型链接会使用 `supporting` 或 `label`；原生按钮的实际内边距、圆角、按压和焦点由 macOS 负责。

片段列表的 `RefinedRowButtonStyle` 使用主文本色 5% 悬停、10% 按下背景。菜单中当前打开详情的分类行使用主文本色 6% 背景与 `hover` 圆角。不要把这一状态底色套用为所有按钮的通用背景。

### Chips

`CategoryChip` 由 6 点圆点、5 点内容间距与类别名称组成，使用 `label` 字号、次级文字、`chip` 圆角和四级语义色半透明底。关键词 chip 使用系统强调色文字及 12% 强调色底，包含有辅助功能名称的删除按钮；移除只改关键词，不触发保存。

### Cards / Containers

`workspacePanel()` 决定面板色、圆角与细描边；内容组件决定 padding，不在每张面板上重复不同阴影。`statCardBackground()` 统一增加 `card` 内边距。边缘到边缘的列表卡在内部标题处使用行内边距，行与行通过 Divider 分隔。

### Inputs / Fields

设置使用原生 Form、Toggle、Picker、TextField 与明确的所属说明。搜索使用 `.searchable`；规则关键词编辑器单独使用面板底、`field` 圆角、7 点内边距和 1 点四级语义描边。输入未通过规范化时禁用提交，真实错误在相关区域以错误文本显示。保留原生焦点，不把“看起来可点击”当成键盘可用证明。

### Navigation

五个主要目的地使用原生 sidebar List；符号跟随系统强调色，分类与规则带真实待处理数量。内容页有上下文副标题；Today 的专注操作保留可读文字。设置七个顶部标签以强调色表示当前项，并使用主文本色 8% 的选中底。

Activity 提供分类、应用、时间三种真实分组。选中活动应驱动时间线与右侧检查器；检查器缺少或过期截图时呈现明确空态。原生导航、分隔和行选择应延续系统键盘约定。

### Time graphics

时间带按记录区间绘制，空档留白；刻度宽度按当前 locale 实测，缩窄时减少刻度，不截断时间。分类容器及图例支持指向同一分类的强调，其他段降低到 40% 不透明度。热力图默认展示时长，可切换评分，包含行列边际总量、预览、固定选中及具体日期入口。颜色和标签都源于同一数据归属。

### Motion and transient surfaces

- 状态切换的共享曲线为 `spring(response: 0.36, dampingFraction: 0.78)`，已用于菜单状态/展开、Today 更多片段、引导步进与检查器反馈；减少动态效果时改为 150 ms ease-out。
- 悬停详情延迟打开 150 ms，移出延迟关闭 250 ms；PanelHost 的安全三角保护向子窗移动的路径。面板出现时从靠近锚点的水平方向偏移 6 点并淡入，持续 160 ms；减少动态效果时不位移，150 ms 淡入。
- 热力图固定状态改变使用 160 ms ease-out，减少动态效果时禁用该动画。
- `RefinedNumberMotion` 将 Today 的已记录总量与支持指标、菜单总时长与投入数值接入 280 ms、`cubic-bezier(0.2, 0.8, 0.2, 1)`。正常使用 `.numericText()`；系统请求减少动态效果时改为 150 ms ease-out 的 opacity 过渡。其余计时器不能仅因引用了同一字号而被视为已经使用该 modifier。
- 浏览器拦截页使用原稿中的 `currentColor` scope SVG，并沿用生成时解析的系统强调色；仅在未请求减少动态效果时执行 160 ms ease-out、向下 6 px 起始位移的入场。

数字过渡已有 [原生录制](docs/design-audit-images/refined/number-motion.mp4) 和 [120 帧时间记录](docs/design-audit-images/refined/number-motion-timing.json)：使用与产品相同的 `RefinedNumberMotion`，对比正常 280 ms 与显式减少动态效果分支。录制使用合成数值，没有修改系统偏好；它证明该共享过渡的分支表现，时长与曲线由源码核对，不是独立测得的端到端时长，也不证明系统设置切换、实时记录接入、全部计时器、真实悬停路径、跨屏表现、其余动画或通知行为。浏览器页面的静态截图不证明按钮执行、Chrome 拦截与放行的完整流程，或已打开页面在系统强调色变化后自动更新。

## Do's and Don'ts

### Do:

- **Do** 从 RefinedStyle 和 WorkspaceStyle 复用颜色、面板和动效定义；同步更新本文档与 sidecar，先核对实际调用点。
- **Do** 使用 SF Symbols、真实应用图标和原生语义控件；让系统处理工具栏、窗口按钮、焦点和控制尺寸。
- **Do** 在深浅外观、当前系统强调色、个人分类色覆盖、12/24 小时制和紧凑窗口下检查新增内容。
- **Do** 保留空闲与暂停的时间空档；用文案、纹理或边界区分空白、未分类和缺失数据。
- **Do** 让设置说明紧贴所属控件，长内容正常滚动；分类名称不能被颜色选择器挤压遮挡。
- **Do** 将静态截图、代码路径、测试结果和真实运行验证分别记录；维护后端清单中的未完成项。

### Don't:

- **Don't** 将系统强调色固定成蓝色或橙色，也不要覆盖用户编辑的分类色。
- **Don't** 用固定窄槽截断本地化时间刻度，或把时间线放到 Activity 层级列表左侧。
- **Don't** 给普通工作区卡片追加统一投影，或把原生工具栏改成模拟网页标题栏。
- **Don't** 用虚构内容填充空状态，或把未连接、未授权、未实现的服务显示成成功。
- **Don't** 将未检查调用点的动画声明或静态渲染结果提升为已验证的全局运行行为。

未规范化的范围：浏览器样本与 AppKit 控件的视觉差异、未捕获状态以及未验证的实机交互，均不被写成已通过的设计规则。数值过渡与拦截页的补充修正已接入并在独立补充复核中解决；本文保留两轮各自 8+2 项的范围，不扩大为整体界面或真实系统行为认证。原生系统展示字体本身是用户指定视觉世界的明确要求，不是待替换的品牌缺陷。
