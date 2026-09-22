# TimeSink 云端账号与同步设计

日期：2026-09-22
状态：已获用户批准（对话中逐项确认）

## 1. 目标与范围

把 TimeSink 从"一个人、一台机器、纯本机"的工具变成可以公开发布的应用：
用户注册账号，活动记录备份到云端，换机器或多台机器能合并成一份数据。

这条推翻了 2026-08-23 设计文档 §1 里"多设备同步"这一项非目标。
其余非目标（团队、项目体系、手动计时、iOS）不变。

**仍然不上云的东西**：屏幕截图、截图识别出的文字、采集器健康记录、
状态事件。它们只留在本机（用户默认没有 Jarvis，也不需要）。

## 2. 已确认的决策

| 决策 | 结论 |
|---|---|
| 用户是谁 | 公开发布，真实账号（邮箱注册），非家庭共享、非监控 |
| 上云的数据 | 活动记录（应用、窗口标题、网址、文档、起止时间）；截图与 OCR 文本永不上传 |
| 云平台 | AWS，无服务器；用 CDK 把基础设施写成代码（用户要求积累 AWS 项目经验） |
| 数据在哪看 | 只在 Mac 应用里；网页版是后续项 |
| 本机数据库地位 | 仍是主数据。云端是每个账号的一份副本和多设备汇合点。Jarvis 按列名读 `span` 表，此处只加列不改义 |
| 同步默认 | 关。登录后由用户打开开关 |

## 3. 架构

```
Mac app ── OAuth2 code + PKCE ──> Cognito Hosted UI（注册 / 登录 / 找回密码）
   │  access token（Bearer）
   └──> API Gateway HTTP API（JWT authorizer = Cognito）──> 一个 Lambda（Python 3.12）──> DynamoDB
```

- **Cognito 用户池**：邮箱即用户名，自助注册，邮箱验证。第一版只有邮箱 + 密码；
  Apple / Google 登录以后是用户池的纯配置改动，客户端不用改。
- **一个 Lambda**，按 `routeKey` 分三条路由：`POST /spans`、`GET /spans`、`DELETE /account`。
- **DynamoDB 一张表** `Spans`：
  - 分区键 `userId`（Cognito `sub`），排序键 `sk = "{deviceId}#{originId:012d}"`。
    键由设备和该设备本机行号决定，所以重传同一批数据是覆盖而不是重复。
  - 属性 `seq`：服务端写入时分配的单调字符串（20 位纳秒 + 6 位随机），
    全局二级索引 `bySeq (userId, seq)` 供"拉取某个序号之后的所有记录"。
  - 按需计费，开启时间点恢复，栈删除时保留。
- **基础设施**：`cloud/infra/`（CDK, TypeScript），一条 `npx cdk deploy`。
  部署输出的三个值（认证域名、client id、API 地址）填进
  `Sources/TimeSinkKit/Cloud/CloudConfig.swift`。它们是公开值，不是密钥。

地区 us-west-2。小规模用量落在各服务免费额度内。

## 4. 数据模型

**本机**（迁移 v8）：`span` 表加三列，`Span` 的 Codable 形状不动：

| 列 | 含义 |
|---|---|
| `deviceID` | 本设备自己的行为 NULL；从别的设备拉下来的行填来源设备号 |
| `originID` | 同上，来源设备上的行号 |
| `remoteSeq` | 服务端确认后的 `seq`；NULL = 还没上传 |

部分唯一索引 `(deviceID, originID) WHERE deviceID IS NOT NULL` 让重复拉取变成 no-op；
部分索引 `WHERE remoteSeq IS NULL AND deviceID IS NULL` 让"找待上传行"不扫全表。

设备号 `cloud.deviceID` 存在 `setting` 表里，第一次要用时生成。
数据库和设备号绑定：安装版和 `swift run` 开发版各有一个库，天然是两台"设备"。

**云端**：一行一个 item，字段就是 `Span` 的字段加 `deviceId`、`originId`、`seq`。
时间用 ISO 8601 带毫秒的字符串，服务端不解析。

## 5. 同步协议

活动记录一旦结束就不再改变（重新归类是覆盖规则，不改 `span` 行），
所以没有冲突合并，只有两个方向的搬运：

- **上推**：本设备 `remoteSeq IS NULL AND deviceID IS NULL` 的行，
  跳过采集引擎当前还在延长 `end` 的那一行（`TrackerEngine.currentRowID`），
  每批 500 行 `POST /spans`，服务端逐行返回 `seq`，写回 `remoteSeq`。
- **下拉**：`GET /spans?since=<cursor>&deviceId=<mine>`。服务端把 `since` 往前放宽 60 秒
  （两个设备同时上传时，`seq` 的分配顺序和写入落盘顺序可能颠倒），
  排除本设备的行，每页 500 行；后续页用 `after=<cursor>` 精确接续，不再放宽。
  客户端 `INSERT OR IGNORE`，唯一索引吃掉重复，每页后保存 `cloud.pullCursor`。
- **删除账号**：`DELETE /account` 先删该用户在表里的全部 item，再删 Cognito 用户。
  客户端随后清空令牌、关掉同步开关、把本机所有行的 `remoteSeq` 置 NULL、清掉游标。
  已下拉到本机的其他设备的行留下（那是用户自己的数据）。
- **换账号**：登录后把 `sub` 和上次记录的 `cloud.userSub` 比较，不同就按上一条清空同步状态，
  否则已经标记"已上传"的行永远不会进新账号。

节奏：登录且开关开着时每 60 秒一轮（先推后拉）；打开开关和点"立即同步"立刻跑一轮。

## 6. 客户端

- 登录：`ASWebAuthenticationSession` 打开 Cognito Hosted UI，回调 `timesink://auth`
  （URL scheme 已在 Info.plist 注册）。PKCE 用 CryptoKit 算 S256。不引入 Amplify。
- 令牌：refresh token 存钥匙串（复用 `Keychain`），access token 只在内存，
  到期前一分钟用 refresh token 换新；refresh 失败（过期或被撤销）视为已登出。
- 退出：撤销 refresh token，删钥匙串项，关同步开关。
- 设置窗口新增「账号」页：登录 / 邮箱 + 退出 / 同步开关 / 立即同步 / 上次同步与错误 / 删除账号。
  第一版只求能用，界面由用户后续精修。

## 7. 隐私

上云的是"什么时候、在哪个应用的哪个窗口 / 网址上"，等价于一份完整的浏览历史。
因此：同步默认关；截图与 OCR 文本永不离开本机；删除账号是完整删除；传输 TLS，
存储 DynamoDB 默认加密。README 里"不上传任何服务器"的表述随本设计作废，发布前改写。

已知缺口（记录，不在本版处理）：删除账号后同一 access token 在到期前（最长 1 小时）
仍能通过 authorizer；用户自定义的分类覆盖、标题规则、预算尚不同步。

## 8. 测试

- `SyncEngine` 对一个内存里的假云端跑：推送跳过打开的行、重跑不重复、
  两个库共用一个云端时 A 的行出现在 B 且 B 不拉回自己的行、重复拉取不重复插入、游标落盘。
- Lambda 处理函数用 moto 模拟 DynamoDB 与 Cognito：推 / 拉往返、重传不重复、删除账号清空。
- 真实验收：部署后，安装版与开发版登同一账号，一边的记录出现在另一边；删除账号后表为空。

## 9. 非目标（本版）

网页 / 手机端查看、Apple / Google 登录、截图上云、规则与预算同步、
一次性导入历史前的选择性上传、团队或家长模式。
