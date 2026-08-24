# TimeSink

TimeSink 是一个 macOS 菜单栏时间追踪应用：自动记录你在各个应用与网站上花费的时间，按内置的 12 类分类法归类，并给出每日生产力分与可视化统计，数据完全保存在本机，不上传任何服务器。

## 功能

- 自动追踪当前活跃应用与窗口标题（含系统空闲/锁屏检测）
- 读取 Chrome 当前标签页网址，按网站精细分类
- 自动分类：内置应用/网址规则 + 可编辑的自定义规则
- 生产力分：按分类的生产力权重实时计算今日得分
- Stats 面板：总时长、生产力分、应用/分类排行、分类时长堆叠图
- Activities 面板：按时间轴查看并手动重新分类每一段活动
- 可选的 LLM 分类兜底（默认关闭，OpenAI 兼容接口，仅用于处理规则未覆盖的网址/应用）

## 安装

```bash
bash scripts/make_cert.sh && make install
```

首次运行 `scripts/make_cert.sh` 会在登录钥匙串中创建一个自签名代码签名证书「TimeSink Dev」，用于给应用签名，使 macOS 记住已授予的权限（Accessibility/自动化）在重新编译、重装后依然有效。**这个证书默认不受信任，首次安装必须手动信任它一次，这一步不可跳过**：打开「钥匙串访问」App，进入 登录 > 证书 > TimeSink Dev，在「信任」里把「代码签名」设为「始终信任」（会要求输入一次登录密码）。

跳过这一步不会立刻报错——`make bundle`/`make install` 会卡在 `codesign` 那一步长时间无响应（这是它在等待一个系统钥匙串授权弹窗，但该弹窗在某些环境下不会正常显示，看起来像卡死）。如果安装命令卡住不动，请先按上面的步骤完成信任设置，再重新执行一次。

`make install` 会构建 Release 版本、签名，并把 `TimeSink.app` 复制到 `/Applications`。首次启动会弹出权限引导窗口，请按提示依次授权。

## 权限说明

TimeSink 需要两项系统权限，均只用于本机追踪，不会以任何形式上传：

- **辅助功能（Accessibility）**：读取当前最前台窗口所属的应用与窗口标题，用于统计各应用的使用时长。
- **自动化（对 Chrome 的 Apple Events）**：读取 Chrome 当前标签页的网址，用于把浏览时间按网站分类。不会读取网页内容、表单或历史记录，仅读取当前标签的 URL。

以上数据以及分类结果、生产力分等全部只写入本机 SQLite 数据库，TimeSink 不包含任何网络上传逻辑（LLM 分类功能默认关闭，开启后也只会把域名/应用名发送给你自行配置的接口，详见设置里的「智能分类」面板）。

## 数据位置与备份

数据库文件位于：

```
~/Library/Application Support/TimeSink/timesink.sqlite
```

备份/迁移时直接复制这个 SQLite 文件即可（应用需处于关闭状态，避免与 WAL 文件不一致）。卸载 TimeSink 不会自动删除这个目录，如需彻底清除数据，手动删除 `~/Library/Application Support/TimeSink/` 即可。

## 开发

```bash
swift test          # 运行测试
swift run TimeSink   # 以裸可执行文件方式运行（不弹首启引导，权限会授予当前终端 App）
swift run tsprobe     # 命令行探针：逐秒打印前台窗口/Chrome 标签页/空闲时间，便于调试采集逻辑
```

开发模式下（`swift run`）弹出的权限授权对话框会把 Accessibility/自动化权限授予当前使用的终端应用（如 Terminal.app / iTerm2 / Ghostty），而不是 TimeSink 本身；这与安装到 `/Applications` 后独立签名的 `TimeSink.app` 权限是分开的两套授权。

开发模式（`swift run`）使用独立的数据库文件 `timesink-dev.sqlite`，与安装版的 `timesink.sqlite` 完全隔离，因此可以和安装版同时运行而不会重复计时。

## 致谢

- Stats 面板布局参考了 [Timing](https://timingapp.com) 的总览界面设计
- 内置网站分类种子数据来自 [WhoTracks.me](https://github.com/whotracksme/whotracks.me)（MIT License）
