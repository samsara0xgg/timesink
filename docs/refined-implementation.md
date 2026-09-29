# TimeSink 精修版实现与验收

按[指定设计稿](https://claude.ai/artifact/XPWfaofcbb8RNGDABCjmmK)重建原生 macOS 前端。保留 SwiftUI/AppKit、系统字体、系统强调色和原生控件；分类色分别匹配浅色与深色设计。首次交付仅更新工作区；用户要求重启后，已于 2026-09-28 安装到 `/Applications/TimeSink.app` 并启动，保留原有记录，详情见下文。

## 交付位置

- 完整后端同步清单：[refined-backend-checklist.md](refined-backend-checklist.md)
- 设计原始代码：[design.html](reference/refined/design.html)
- 视觉验收目录：[原生界面 PNG](design-audit-images/refined/)
- 可重复的隔离预览：调试版运行 `--design-preview`。只创建内存数据库和示例数据，不启动记录、采集、云同步或模型请求。

## 已安装版本验证（2026-09-28）

- Release 构建通过，以原应用相同的 Developer ID 与权限声明签名，替换安装并重启；实际主窗口已显示“今天 / 活动 / 趋势 / 专注与限额 / 分类与规则”和“正在记录”。安装文件与构建文件一致，签名校验通过。
- 发现已分发的 0.2.1 版本曾将 `v9` 用于其他数据库迁移，导致新版同名迁移被跳过。新增唯一命名、可重复执行的分类支持表修复迁移；保留旧记录和既有分类覆盖。实际数据库三张所需表均已就绪，启动后未再出现缺表或分类解析错误。
- 修复应用再次打开时没有主窗口的行为。新增两项升级兼容测试；本次数据库定向测试共 19 项，0 失败。随后在提交前完成整合版本的 333 项全套测试，2 项跳过，0 失败。
- 替换前的原应用和数据库备份位于 `~/Library/Application Support/TimeSink/Backups/before-refined-20260928-162636/`；迁移修复前另有 `before-migration-repair/` 快照。备份不纳入仓库，未将真实活动内容保存为验收截图。

## 界面范围

菜单栏状态、当前活动、今日摘要、分类占比与悬停明细、每日限额、快速专注、状态胶囊；主窗口的今天、活动、趋势、专注与限额、分类与规则；活动检查器和截图回看；七页设置；五步新手引导；专注 HUD 和浏览器拦截页。

交互包括暂停/恢复、专注延长/提前结束/放行、分类三种作用范围、影响预览与撤销、活动按分类/应用/时间分组、规则启停和标题规则排序、建议接受、分类卡片编辑、日期选择、键盘导航、可录入全局快捷键、持久化 Chrome 网址开关、截图保留和明确确认的删除、CSV和诊断导出。

## 示例画面

以下均为**当前工作区原生代码生成的合成数据预览**，不是用户真实记录。时间、应用和分类量会随预览构造变化。引擎未启动，因此状态为“记录未启动”；系统强调色跟随当前 Mac。截图不等同于已安装版本，也不能验证系统权限或线上服务。

### 今天

![今天 · 浅色](design-audit-images/refined/today-light.png)

![今天 · 深色](design-audit-images/refined/today-dark.png)

### 活动与检查器

![活动](design-audit-images/refined/activities-light.png)

![已选中的活动检查器](design-audit-images/refined/inspector-light.png)

### 趋势与专注

![趋势](design-audit-images/refined/trends-light.png)

![专注与限额](design-audit-images/refined/focus-light.png)

### 分类与规则

![待分类](design-audit-images/refined/organization-light.png)

![规则](design-audit-images/refined/rules-light.png)

![分类](design-audit-images/refined/categories-light.png)

### 菜单栏状态

![菜单栏](design-audit-images/refined/menu-light.png)

![全部记录已暂停](design-audit-images/refined/menu-paused-light.png)

![专注中](design-audit-images/refined/menu-focus-light.png)

![辅助功能缺失](design-audit-images/refined/menu-permission-light.png)

### 设置、引导与浮层

![通用设置](design-audit-images/refined/settings-general-light.png)

![记录与隐私](design-audit-images/refined/settings-privacy-light.png)

![新手引导](design-audit-images/refined/onboarding-1-light.png)

![专注 HUD](design-audit-images/refined/focus-hud-light.png)

## 验证及边界

- 合入上游后全套 Swift 测试：333 项，2 项跳过，0 失败；构建通过。
- 新增行为测试包括：单段分类覆盖进入主解析器/后台统计/SQL日汇总；批量预览遵守优先级；撤销恢复来源且拒绝覆盖新修改；暂停实际留白；应用排除；AX失去/恢复；专注延长与完整URL；导出转义/诊断内容排除；周起始日。
- 深浅色、1200×820与800×580内容尺寸和多种状态的原生截图已生成。真实工具栏/标题栏通过 SwiftUI Window 场景捕获；未用HTML静态稿冒充原生应用。
- 未验证真实账号的云端状态、通知投递、系统权限弹窗、跨屏悬停或 Chrome 多标签页恢复。详见后端清单的实机验收条目。
- 后端清单共 60 项契约/缺口记录；其中 B09（Chrome 长期开关）和 B12（小结打开今天）已关闭；合入上游 Sparkle 后 B02 更新控件也已接通，仍有 9 项明确开发缺口。设备数量或尚不支持的建议类型未标为完成。
- 静态截图不证明逐像素一致，也不证明实时动效、真实悬停路径或系统行为全部通过。

## 设计复核与动态证据

复核阶段共修正十项界面与交互问题，包括分类色与用户覆盖、规则编辑与排序、真实状态、摘要数值过渡、浏览器拦截页强调色及符号。这个范围不代表全部系统行为已经通过实机验收。

摘要数字共用 `RefinedNumberMotion` 的 280 ms 指定曲线；减少动态效果时改用 150 ms opacity。证据见 [原生视频](design-audit-images/refined/number-motion.mp4)、[帧接触表](design-audit-images/refined/number-motion-contact.jpg) 和 [时间记录](design-audit-images/refined/number-motion-timing.json)。录制使用合成数据，没有改变系统偏好；时间与曲线由源码核对，不是端到端实测保证。

浏览器拦截页的深浅色截图来自实际 WKWebView 加载本地生成 HTML，使用系统强调色与原稿 scope SVG。它们只证明渲染，不证明 Chrome 多标签页拦截、放行和恢复全部通过。

[截图清单](design-audit-images/refined/manifest.json) 记录了 56 张主 PNG。截图产生于界面复刻阶段，随后合入的英文支持和自动更新控件尚未重新截图。设计规范见 [DESIGN.md](../DESIGN.md)，未完成事项见 [后端清单](refined-backend-checklist.md)。

## 与上游主分支对齐

保留上游的 Sparkle 更新服务、发布与公证脚本、按系统语言切换的文案、窗口置前处理和截图节能优化。新的关于页接入自动检查偏好与手动检查更新；没有发布新版本或重新安装这一整合版本。发布流程见 [RELEASING.md](RELEASING.md)。本地化检查通过：738 个提取键、716 项翻译，0 问题；333 项 Swift 测试中 2 项跳过、0 失败。
