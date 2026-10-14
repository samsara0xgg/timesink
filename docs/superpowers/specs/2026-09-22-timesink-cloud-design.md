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
  默认用 Cognito 内置发件，每天上限 50 封；CDK context `sesFromEmail`
  （可选 `sesFromName`、`sesReplyTo`、`sesRegion`、`sesVerifiedDomain`，
  deploy.yml 从同名大写的仓库变量传入）改走 SES。前提是先在 SES 验证该地址或域名、
  并申请脱离沙盒，所以默认关闭。
- **一个 Lambda**，按 `routeKey` 分三条路由：`POST /spans`、`GET /spans`、`DELETE /account`。
- **限流**（2026-10 审核 #18）：注册开放，所以除了 API stage 的全局限流（20 rps / 突发 40），
  Lambda 里每个用户每分钟最多 60 次请求、每个 UTC 日最多上推 50,000 行，超出返回 429 和
  `Retry-After`。计数器写在该用户自己的分区里（`sk` 以 `#` 开头，设备号不会以 `#` 开头），
  靠表的 TTL 属性 `expiresAt` 过期，没有 `seq`，所以拉取看不到。
  Lambda 预留并发是 CDK context `apiReservedConcurrency`，默认不设：新账号的并发配额可能只有 10，
  AWS 要求保留 10 个不预留，设了会部署失败。全局限流是所有用户共享的；要做到按客户端隔离，
  需要 HTTP API 不支持的 WAF（或改用 REST API 的 usage plan）。
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

部分唯一索引 `(deviceID, originID) WHERE deviceID IS NOT NULL` 让重复拉取不会多出行（拉取按它 upsert）；
部分索引 `WHERE remoteSeq IS NULL AND deviceID IS NULL` 让"找待上传行"不扫全表。

设备号 `cloud.deviceID` 存在 `setting` 表里，第一次要用时生成。
数据库和设备号绑定：安装版和 `swift run` 开发版各有一个库，天然是两台"设备"。

**云端**：一行一个 item，字段就是 `Span` 的字段加 `deviceId`、`originId`、`seq`。
时间用 ISO 8601 带毫秒的字符串。服务端校验格式（带时区）和 `start <= end`：不合格的行
（例如时钟回拨产生的结束早于开始）不存，但照样出现在 `acked` 里（另列在 `rejected`），
否则客户端会每一轮重传同一行。各字段按长度截断而不是拒绝：`appBundleID`、`appName`、
`domain` 255，`title` 1024，`url`、`document` 2048（Unicode 标量数；客户端发送前按同样的上限截断）。
一次上推最多 500 行。

## 5. 同步协议

每一行只有一个写入者——记录它的那台设备（重新归类是覆盖规则，不改 `span` 行），
所以没有冲突合并，只有两个方向的搬运。已结束的行仍可能被本机改动
（事后裁掉闲置尾巴）：改动时把它的 `remoteSeq` 置回 NULL，下一轮重新上推，
服务端按同一个键覆盖并分配新的 `seq`；其他设备拉到新 `seq` 后，`insertRemote`
按 `(deviceID, originID)` 更新本机副本（upsert），而不是忽略。

- **上推**：本设备 `remoteSeq IS NULL AND deviceID IS NULL` 的行，
  跳过采集引擎当前还在延长 `end` 的那一行（`TrackerEngine.currentRowID`），
  每批 500 行 `POST /spans`，服务端逐行返回 `seq`，写回 `remoteSeq`。
- **下拉**：`GET /spans?since=<cursor>&deviceId=<mine>`。服务端把 `since` 往前放宽 60 秒
  （两个设备同时上传时，`seq` 的分配顺序和写入落盘顺序可能颠倒），
  排除本设备的行，每页读 500 行；后续页用 `after=<cursor>` 精确接续，不再放宽。
  返回的游标是这一页读到的最后一行（本设备自己的行也算），所以只有一台设备的账号
  游标也会前进，不会每轮重读自己最近的一页。
  客户端逐行解析，读不了的行（缺字段、时间解析失败、结束早于开始）跳过并记日志，
  不让整页失败；按唯一索引 `(deviceID, originID)` upsert：重复拉取不会多出行，
  被来源设备改过（重新上推）的行会更新本机副本。每页后保存 `cloud.pullCursor`。
- **删除账号**（审核 #20）：历史多的账号一次请求删不完，所以 `DELETE /account`
  先对该用户 `AdminUserGlobalSignOut`（作废所有设备的 refresh token）并 `AdminDisableUser`，
  再写一个 `#deleted` 标记：已发出的 access token 最长还有 1 小时能通过 authorizer，
  标记让这期间的上推和下拉都返回 410（上推写完后再查一次标记，赶上删除的那批自己删掉）。
  然后异步调用 Lambda 自己执行删除任务，立即返回 202。删除任务分页查询该分区、
  `BatchWriteItem` 删除，剩余时间不足 10 秒时把任务交给新的一次异步调用，
  全部删完后 `AdminDeleteUser`。标记 7 天后由 TTL 删除。任务失败会触发 Lambda 错误告警
  （异步调用自动重试两次）；要补跑，用同样的 `{"deleteJob": {"userId", "username"}}` 直接调用该函数。
  客户端把 202 当成功，随后清空令牌（本地退出登录）、关掉同步开关、
  把本机所有行的 `remoteSeq` 置 NULL、清掉游标。
  已下拉到本机的其他设备的行留下（那是用户自己的数据）。
- **换账号**：登录后把 `sub` 和上次记录的 `cloud.userSub` 比较，不同就按上一条清空同步状态，
  否则已经标记"已上传"的行永远不会进新账号。

节奏：登录且开关开着时每 60 秒一轮（先推后拉）；打开开关和点"立即同步"立刻跑一轮。
上推失败不影响同一轮的下拉，除非是 429：那时整轮停下，按 `Retry-After` 和指数退避
（15 秒起、连续每次翻倍、上限 1 小时，取两者较大，再加最多 20% 抖动）等待，后台循环在此之前跳过。

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
因此：同步默认关；截图与 OCR 文本永不离开本机；删除账号会删掉表里该账号的全部 item
和 Cognito 用户；传输 TLS，存储 DynamoDB 默认加密。README 里"不上传任何服务器"的表述随本设计作废，发布前改写。

删除不是即时的，也不是立刻从所有副本消失：表里的数据通常几分钟内删完；
表开着时间点恢复（PITR，保留期为默认的 35 天），删掉的数据在之后 35 天内
仍能从 PITR 恢复出来，过后才彻底消失。Lambda 日志（可能含同步的标题和网址）保留 30 天。

已知缺口（记录，不在本版处理）：用户自定义的分类覆盖、标题规则、预算尚不同步。
（删除账号后 access token 仍可用的问题已由 `#deleted` 标记挡住，见 §5。）

## 8. 测试

- `SyncEngine` 对一个内存里的假云端跑：推送跳过打开的行、重跑不重复、
  两个库共用一个云端时 A 的行出现在 B 且 B 不拉回自己的行、重复拉取不重复插入、游标落盘。
- Lambda 处理函数用 moto 模拟 DynamoDB 与 Cognito：推 / 拉往返、重传不重复、游标越过自己的行、
  时间校验与字段截断、每分钟与每日限额的 429、删除账号（禁用、410、分页删除与交接、最后删用户）。
- CDK 断言测试：TTL、预留并发和 SES 默认关闭且可以通过 context 打开、删除账号所需的 IAM 权限。
- 真实验收：部署后，安装版与开发版登同一账号，一边的记录出现在另一边；删除账号后表为空。

## 9. 非目标（本版）

网页 / 手机端查看、Apple / Google 登录、截图上云、规则与预算同步、
一次性导入历史前的选择性上传、团队或家长模式。
