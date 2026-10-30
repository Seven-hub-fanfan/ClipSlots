# ClipSlots 自有 Gateway v1 本地服务

这是可运行的 Python 标准库 HTTP/SSE + SQLite 服务，不是 TapNow 私有接口。
客户端是项目已有的真实 Swift `URLSessionAgentGatewayTransport`。
本交付不安装后台服务，不修改 App 配置、Keychain 或 DeepSeek/Tika 凭据。

自有 App reply v1 的 manifest 权威、不可变 reply 身份、专用分派和只读恢复
合同见 [APP_REPLY.md](APP_REPLY.md)。数据库 schema 已增至 4；原有 run、
decision 和 steer 合同继续保留。Swift/WebKit App reply 接入仍在进行中。

## 三种边界

| 类型 | 行为 |
| --- | --- |
| 原有 Swift fixture | 注入内存 transport，不代表 HTTP 已通。 |
| 真实本地 HTTP/SSE | `server.py` 实际监听 loopback，事件和回执写入 SQLite。网络测试属于这一层。 |
| 真正远端模型 | 只有显式提供下面三个 `GATEWAY_PROVIDER_*` 环境变量才调用。当前未用专用远端凭据验证。 |

`--test-only-provider` 必须显式启用，启动日志标注
`TEST-ONLY-SYNTHETIC-NOT-A-REMOTE-MODEL`。生产启动不加载这个 provider，
没有专用模型配置时 `POST /v1/runs` 返回 `503 PROVIDER_NOT_CONFIGURED`，
不会生成回执、内容或伪成功。

## 启动与停止

### 私有专用配置（v2.17.38）

从本源码目录执行：

```bash
python3 -B gateway/manage.py init
python3 -B gateway/manage.py status
python3 -B gateway/manage.py configure
python3 -B gateway/manage.py start
```

`init` 创建 `~/.config/clipslots-gateway/gateway.json`（0600）及
`~/.local/share/clipslots-gateway/`（0700），生成独立的本地认证 token。
三个 provider 字段保持空白。重复初始化保留原文件和 token。
`configure` 在交互终端询问专用 API 根地址、模型名和专用 key，key 输入隐藏；
不会导入 App 的 DeepSeek/Tika 或 Keychain 凭据。私有配置不进入源码或交付压缩包。
`start` 清除继承的 `GATEWAY_*` 环境后，仅使用这份显式配置，前台运行，Ctrl+C 停止。
未填齐三个字段时拒绝启动；`start --allow-unconfigured` 只用于本地健康检查，
此时创建 run 仍然返回 503。

服务运行后可执行：

```bash
python3 -B gateway/manage.py check
python3 -B gateway/manage.py probe
```

`check` 请求带认证的 `GET /v1/health`，不会调用上游、创建 run 或写事件，
返回 provider 是否已配置、是否测试合成服务及协议能力。它不证明远端凭据有效。
`probe` 是显式的一次短文本模型请求，不含工具或媒体生成；必须同时收到内容、
assistant 完成和 run 完成事件才通过。只有 HTTPS 远端上游才标记
`remoteModelVerified=true`，loopback wire fixture 单独标记本地请求验证。
所有命令输出均隐藏 token/key，不打印模型回复正文。

App 的 Agent 设置选择 Gateway，地址填写 status 中的 `gatewayURL`，
本地服务 token 使用私有配置的 `authToken`，模型名使用专用模型名。
provider key 只填在本地私有配置中。App 保存 token 的操作由其现有设置入口完成。
本工具不自动改写 App 的当前 backend 或凭据。远端 provider 支持的
thinking/tool/usage 扩展仍需实际验证，健康检查不能替代完整 REA 对照验收。

从本 WORK 目录执行，Python 3.9+，只用标准库：

```bash
python3 -B gateway/server.py --db /tmp/clipslots-gateway-live-manual/state.sqlite
```

默认地址是 `http://127.0.0.1:8787/v1`，只允许 IPv4 loopback 监听。
可通过 `--port` 更换端口，`--port 0` 由系统分配测试端口。
`--db` 必填；请使用专用、可信、私有目录，不要指向 App 业务数据。
前台 `Ctrl+C` 停止，不使用 launchd、后台部署或系统安装。

认证与模型均由进程环境显式配置：

| 环境变量 | 用途 |
| --- | --- |
| `GATEWAY_AUTH_TOKEN` | 本地服务 Bearer token；未设置时仅 loopback、无认证。建议启用。 |
| `GATEWAY_PROVIDER_BASE_URL` | 专用 OpenAI/DeepSeek 兼容 API 根，例如 `https://api.deepseek.com/v1`，不是完整 `/chat/completions` 路径。 |
| `GATEWAY_PROVIDER_API_KEY` | 专用 provider key；不读取 App Keychain、DeepSeek 或 Tika 配置。 |
| `GATEWAY_PROVIDER_MODEL` | 专用模型名；覆盖命令中的模型名，防止隐式切换付费模型。 |

三个 provider 变量必须同时设置。远端仅允许 HTTPS；`127.0.0.1` HTTP 用于
显式本地兼容 provider 和测试。Provider 与 Swift transport 均拒绝重定向。
Provider 单次网络读取超时为 30 秒；取消后丢弃迟到结果，但不承诺远端停止计费。
`thinkingMode` 的 enabled/disabled 是显式兼容扩展，不保证每个 provider 都支持。
请求 `stream_options.include_usage`；不支持该字段的 provider 可能拒绝请求。
不自动联网检查凭据，不打印 token、上游响应正文、prompt 或服务查询参数。

仅测试合成模型：

```bash
python3 -B gateway/server.py --port 0 \
  --db /tmp/clipslots-gateway-live-manual-test/state.sqlite --test-only-provider
```

## Swift 客户端

业务端保留既有 Gateway backend 的显式入口。下例不写用户配置：

```swift
let backend = AgentGatewayBackend(
    baseURL: URL(string: "http://127.0.0.1:8787/v1")!,
    binding: AgentRunBinding(sessionID: sessionID, projectID: projectID, canvasID: canvasID),
    journalRoot: privateJournalRoot,
    apiKeyProvider: { dedicatedGatewayToken }
)
let messages = try await backend.run(
    history: history, config: config, tools: authorizedTools, onEvent: receive
)
```

Gateway URL/token 与 provider URL/key 是两个不同边界。`AgentConfig.endpoint`
不参与 Gateway 路由或凭据选择。重启必须使用完全相同的服务 root、binding
和客户端 journal；不要通过新 request key 掩盖未知提交结果。

### 运行中追加指令（S12 候选）

自有服务实现了独立版本化的 `accepted / placed / returned` 队列和安全消费点，
协议、限制、恢复与实际消费证据见 [STEER.md](STEER.md)。只有显式的 run 能力
允许显示热追加入口；Swift/App 已接入自有服务消费合同，旧接口保留停止核对
后发送路径。真实系统输入法与原专项的云验收范围仍待完成。

### 确认决策（S13 服务端候选）

自有服务新增按原请求读取的决策 ledger，显式区分 pending、expired、
superseded 与 resolved。回复、原消息位置、服务端时间和回执在同一个
事务内持久化，读取不返回回答正文。批量回复逐项保留 index/action/
modifications，费用决定单列。详见 [DECISIONS.md](DECISIONS.md)。
当前 Swift/App 接入与断流恢复仍待完成，不能把服务端本地通过当作
M05 整体已验收。

### 有界诊断与画布读回（v2.17.104 专项候选）

`await backend.exportDiagnostics()` 导出当前 controller 的脱敏诊断 JSON。
它只含固定阶段/结果/错误类别、耗时（毫秒）、字节量、HTTP 状态、
重试次数和经过 SHA-256 的 scope/run/request/event/call 关联；没有 URL、
header、凭据、工具参数、用户正文或 reasoning。环最多 128 条，导出最多
128 KiB，淘汰数及单调 sequence 可识别缺失记录。它是内存诊断，不承诺
重启后保留；恢复仍依赖原业务 journal，不会因诊断淘汰而删除任何回执。

Swift v1 客户端还接受可选 `canvas_tool_event` SSE，payload 为
`tool/status/tool_call_id（或 tool_use_id）/response`。自有 v1 扩展允许显式
`subagent_id/parent_tool_call_id`；这些可选字段连同工具名和两个调用 ID
保存在读回请求的 `source` 中，未提供时保持缺失，不从文本推断父子关系。
重复请求按 project/conversation/run/key/source 归属核对；同一归属而
ID 集合或 fallback 许可改变会拒绝。旧无 source journal 和回执仍兼容。
普通工具仅接受
completed；显式 Bash/tapnow_cli 的 failed 可以读回部分副作用。26 个
来源工具名称见 `AgentCanvasChangeNotice.snapshotTools`。CLI notice 支持
结构化 `canvas_changed`，或 `_notice` 文本中的有界平衡 JSON。delete/
disconnect 不产生读回请求，删除仍需完整 typed mutation 和原生确认。

解析结果只是带 project/conversation/run 身份的节点/连线 ID，先随
event cursor 持久化，再向宿主回调。宿主必须显式配置
`AgentCanvasSnapshotReading`；当前 Python 服务不提供权威 Canvas 数据库
或快照查询路由，客户端不会推测私有接口。未配置时请求保留并显示不可用。
`CanvasStorageReadbackSource` 可为自有宿主读取显式提供的独立原生数据源，
忽略缓存，缺失或损坏时抛错且不移动/修复源文件。不要把显示缓存当作权威，
也不要把待查询的源与用户的本地写入目标隐式绑定。

`AgentCanvasReadbackBatcher` 默认 100ms 聚合窗口，默认 node/edge 查询并行；
同项目的不同批次串行，不同项目可以独立推进。合法请求的合并集合超过
1000 节点/2000 连线时拆成有界批次，不以整个集合超限拒绝合法单项。
reader 可以覆盖 `snapshot(projectID:nodeIDs:edgeIDs:)` 提供一致快照；
原生文件 reader 从一次严格磁盘读取中裁剪节点与连线，避免两次读取混合。
结果逐请求裁剪，必须覆盖所有 expected ID。仅 CLI 请求允许缺项补查，
补查只补缺失值。取消立即结束对应 continuation，但同项目 lease 直到
底层 reader 实际退出才释放，避免慢取消与新请求并行。reader 仍应自行
实施网络时限与取消；宿主不把停止等待当成底层 I/O 已停止。
项目切换丢弃排队和在途结果；同一读回期间发生的本地移动、编辑、
编辑后撤销及新建后删除优先保留；没有读回时不建立全图观察字典。
普通组容量 10、私有组容量 60 与权威存储一致。结果进入现有 typed preview→confirm→
compare-and-save 路径，读回本身不写用户画布。云端完整节点类型映射、
子 Agent 调度和真实权威 reader 仍需独立取证与契约验收。

S7 自有客户端也投影显式 `subagent_event`（缺省版本或
`schema_version: subagent_event.v1`），只处理 started、tool_started、
tool_completed、tool_failed、completed、failed、stopped 的读回触发。
嵌套 `tool_event` 继承显式 child/parent 身份；不支持的版本、旧父任务
事件和已终止实例的迟到事件不会同步工具结果。终态或流结束生成
`scope: subagentCanvas` 的持久全图读回请求，普通空 ID 请求不能获得此权限。
此投影不实现子任务调度、计划或内容 timeline，也不把 stopped 显示为 completed。
终态和未处理变更与事件游标一起保存，重启可恢复当前 parent scope。

全图读回必须配置 `AgentCanvasSavingSnapshotReading`，按“等待嵌套工具→
轮到本项目队列→捕获本地文档→保存成功→全图快照”执行。
deferred/失败保存不会继续查询。宿主通过共享 `AgentCanvasReadbackSerialGate`
跨读回源/会话换代保留项目锁，旧 I/O 实际退出后新来源才可开始。
捕获后发生的编辑、撤销和新建/删除均优先保留；不存在于 incoming 的本地
节点不会被删除，缺少有效端点的 incoming 连线被跳过。全图只生成完整提案，
超过现有 mutation 单次预算时明确失败，不截取成部分成功。

Pqt 触发函数证据绑定后续发布包 `2026.10.28.40686769132.1`；旧版本完整资源
已轮换，不把后续包的触发证据回填到旧版本。Python 服务没有子任务 scheduler
或云端 Canvas 保存/快照路由；这些能力未接入时仍显示不可用，不能据本地合同
和离线原函数探针宣称云端验收完成。

## 持久语义

### S8 上下文观察与压缩通知

自有 Swift 客户端接受 `context_usage`（直接 payload 或 `context_usage` 包装）
和 `compact`（`phase: started/finished`）。用量字段按照已归档 Qn 校验：
revision 是非负安全整数；用量有限、非负或显式 null；上限不能 0；百分比
允许超过 100，不强制根据 used/max 重算。无效对象被忽略，已提交 cursor 仍前进。
来源和状态分别限定为 sdk/last_request_usage/unavailable 与 ready/stale/unavailable。
`last_good` 缺省和显式 null 分别保存；它必须同会话、ready、revision 不超父值，
且不能再包含 last_good 字段。时间由系统 JavaScriptCore Date.parse 校验，常量
函数接收字符串参数，不执行事件正文。

完整权威观测与最后可靠显示值分别保存。较旧或相同 revision、其他会话/运行，
以及发起后 localVersion 已变化的读取结果均不能替换新状态；完整 SDK 显示值
优先于缺少上限或百分比的新来源，保留值标明“上次可靠观测”。显示圆环范围
限定 0–100%，数值文字保留协议原百分比；计费用的 `usage.promptTokens` 不替换
权威上下文。加载、模型/后端改变、工具完成、重连/中断和 compact 均使观测失效。
compact 重复 started 更新一个生命周期，finished 后等待新的 ready 用量；异常
终止移除尚未 finished 的记录，不能生成虚假的压缩完成。客户端 journal 与
App 会话文件均兼容缺少这些字段的旧数据。

当前 Python provider 没有 SDK 上下文观察或压缩后端，不从计费 usage 伪造
context_usage，也没有 compact 命令/阈值/摘要提示词。S8 的实际 HTTP 测试使用
明确标注的 FaultServer 合成事件，不代表远端压缩、会话元数据接口或 GUI 卡片
已经验收。

- `/runs`、`/continue`、`/cancel`、`/tool-results` 都要求匹配的
  `requestKey` / `Idempotency-Key`。键、规范化 body digest、路由、原始回执共用事务。
  同键同请求返回原回执；同键不同 body/路由为 `409`。
- Run binding 和目标 client 不可被 continue 改写。Query 没有 cursor；
  `/requests/{key}` 返回最初提交的精确回执，不伪造当前状态回执。
- SQLite WAL + `synchronous=FULL`，数据库及锁文件权限 `0600`，进程锁排除第二个 owner。
  回执、状态、工具结果、事件在同一数据库事务内提交。
- SSE 帧提交后才发送，原始 frame 不变。事件 ID 含 `/` 和 `+`，是 opaque ID，
  不根据字符串或数字排序。Cursor 限定 run，未知或跨 run cursor 为 `409`；
  header/query 不一致为 `400`。HTTP query 中字面 `+` 必须编码为 `%2B`。
- 工具由授权 Swift 客户端执行，服务只收结果。`tool-{executionID}` 收集一次，
  重发不追加结果、不重复下一轮模型请求。实际副作用的 exactly-once 仍依赖客户端
  执行 journal；未知执行结果必须 reconcile，不能盲目重复。
- 进程重启将 in-flight run 原子转为 `waiting_suspended`，追加可 replay 的事件，
  保留已有文本和工具结果。不自动重发可能已执行的模型请求。
  所有未决工具须先收齐，再由显式 continue 继续。
- Cancel 事务标记状态并阻止迟到事件；completed 不会被改成 cancelled。
  客户端仍查询状态确认，EOF 或 completed query 不会代替完成事件。
- 输入 JSON 严格拒绝重复键、NaN、无效版本、非法历史和工具参数。
  最大 HTTP body 8 MiB、1000 条历史、128 个工具 schema、20 个调用/消息。
  SSE 单帧限制 1 MiB，转义及 envelope 开销使单工具参数的有效上限可能更小；
  超限安全失败，不发送不符合客户端容量的帧。
- OpenAI adapter 支持增量内容、`reasoning_content`、usage、分片 tool calls 和后续 tool turn。
  缺少完整 `[DONE]` / finish_reason、重定向或坏响应都失败，不伪造完成。

### 消息输入 v1

`schemaVersion: 1` 保持原有 run/事件合同；新客户端额外发送
`messageSchemaVersion: 1`。旧客户端省略该字段时仍接受字符串 content。
新版本允许 user content 为一项 text 和最多六项 image_url 的数组。
图像必须来自客户端已捕获的静态 PNG/JPEG/WebP/GIF data URL；
只有 `config.supportsImageInput: true` 才接受，能力仍须由所选模型明确声明。
网关不抓取任意远程图片链接。单图解码字节最多1MiB，每条消息合计最多2MiB；
完整请求（所有历史、base64及JSON开销）仍最多8MiB，Swift在保存提交命令前检查。

原生导入使用ImageIO验证图片可解码和像素预算；服务端只验证data URL、
base64、字节限制与MIME文件头，不能将文件头验证宣称为完整图片解码。
历史assistant的可选 `reasoning` 原样转换为provider `reasoning_content`，
包含空白、Unicode和空字符串。provider返回的思考同样在工具续轮前保存到SQLite，
与回执/历史事务一致，重启不删除。未提供该字段的旧历史保持原行为。
`GET /v1/health` 的 `messageContentV1` / `reasoningHistory` 能力说明协议支持；
它们不是远端模型支持图像或reasoning的验证结果。

### 工具声明与结果恢复（2026-10-28）

Swift在每次提交时一次性保存完整工具声明、来源、提交键、执行scope与实例身份。
工具参数按原声明校验；执行前再次核对当前schema、来源及实例，改变后返回明确拒绝。
网关合同原有128个声明上限保持不变，不把来源前端的32项注册上限套用到所有内置工具。

同一backend与同一执行实例可以继续读取断流事件。新的实例或重启进程只能核对已保存结果，
不能继承旧声明开始新的副作用；需要新的提交才能授权新的实例。只有名称的旧journal
不补造schema或实例。未确认执行仍保持unknown，不能重新运行。
已完成回执和工具启用状态分开：即使新实例移除了该工具，也可按原scope、call ID、
工具名和参数摘要补交确认的结果；不会改用后续轮次的同名call或另一个项目。

取消传播到正在执行的任务和MCP初始化/HTTP请求。handler返回的结果仍落盘供核查，
取消后不发送工具结果；执行期间超过请求到期时间的结果也只保存本地。
已经到期但尚未执行的请求可以返回EXPIRED拒绝回执。这些保证不等于远端工具停止计费。

这不是生产部署：没有多租户、TLS listener、限流、配额、监控、备份策略、
事件清理或数据库迁移运维。事件保留不自动过期，长期使用需安排容量管理。
本 adapter 不把模型文本解释成 artifact、canvas mutation 或本地文件写入。
Artifact/usage schema 已测试。显式测试 provider 可发送 typed `canvas_changed`
提案：GROUP 父链、`parent_local` 坐标与连线用途经过真实 SSE 和 Swift 解码，
再由确认侧执行整图校验、CAS 持久化及 receipt 去重；网络事件不直接写画布。
Provider 获得内部 `gatewayRunID` 用于绑定真实 run，此字段不进入用户请求或
OpenAI 上游 wire body。生产 OpenAI adapter 不从模型文本自动构造画布提案。

## 验证

```bash
bash scripts/test-agent-run-gateway-live.sh
```

脚本仅编译 `ClipSlotsKit` 和两个独立测试程序，默认 scratch 为
`/tmp/clipslots-gateway-live-build`，不编译 GUI。父 agent 也可显式指定已构建的
`/tmp/clipslots-rea-live-build`，让网络测试使用与 GUI 相同的 Kit 对象。
已经有本次更新的 Kit module 时可使用：

```bash
GATEWAY_LIVE_SKIP_BUILD=1 bash scripts/test-agent-run-gateway-live.sh
python3 -B gateway/test_live.py
python3 -B gateway/test_manage.py
```

测试会临时监听 8787 检查未配置的生产模式；该端口应空闲。
其他测试使用独立临时端口，并启动仅测试用的 OpenAI wire fixture、
故意破坏协议的 HTTP fixture 和显式 test provider。它们都不是真正远端模型。
所有进程在结束后停止；SQLite、journal、日志和汇总保存在
`/tmp/clipslots-gateway-live-python-*`，编译及总日志也在
`/tmp/clipslots-gateway-live-*`。测试覆盖并发幂等、conflict、restart、
SIGKILL replay、cursor、cancel、continue、工具缓存及幂等、
metadata、协议错误、auth、provider EOF 和重定向拒绝。
新增 GROUP 网络场景覆盖乱序父链转换、同端点不同用途连线、重复通知、
重启恢复提案、确认后 CAS、非法层级无写入，以及空/超限 GROUP 在回调前拒绝。
2026-10-16历史验证为25个Python及23个Swift网络用例。2026-10-28候选新增
图像与reasoning用例后为30个Python及23个Swift网络用例，0失败，Swift共77条断言。
模拟transport的210条断言及应用集成12条另行计数，不合并为网络断言。
