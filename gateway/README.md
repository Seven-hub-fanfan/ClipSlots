# ClipSlots 自有 Gateway v1 本地服务

这是可运行的 Python 标准库 HTTP/SSE + SQLite 服务，不是 TapNow 私有接口。
客户端是项目已有的真实 Swift `URLSessionAgentGatewayTransport`。
本交付不安装后台服务，不修改 App 配置、Keychain 或 DeepSeek/Tika 凭据。

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

## 持久语义

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
2026-10-16 最终执行为 25 个 Python + 23 个 Swift 网络用例，0 失败；
Swift 共 77 条断言。另有 169 条模拟 transport 断言，单独计数。
