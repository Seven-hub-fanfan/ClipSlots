# ClipSlots App reply v1

本合同属于 ClipSlots 自有网关。它没有宣称复现 TapNow 私有的服务端
`previs_reply` 实现，也不推断未知的业务动作。Swift 客户端现已具备独立
SQLite reply ledger、原网关地址与产物权威字段持久化、只读核对及显式原身份
重试。WebKit 已接入专用回复、manifest 校验和运行状态读取；原生面板提供
核对、原身份重试和接管。其本地验证与真实云服务验收分别记录。

## 权威来源

只有网关正在执行的 provider 回调可以通过 `artifact_updated` 交付
`appReplyManifest`：

```json
{
  "artifactID": "board",
  "path": "apps/board.html",
  "revision": 1,
  "content": "<p>Board</p>",
  "mimeType": "text/html",
  "appReplyManifest": {
    "schemaVersion": 1,
    "manifestRevision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "actions": ["previs_reply"]
  }
}
```

`manifestRevision` 必须来自发布者明确提供的 manifest，格式为 64 位小写
十六进制。网关不把 HTML 内容摘要、页面自报字段或数字产物修订转换为
manifest 身份。示例中的重复字符只用于测试，不是生成 manifest 的算法。
网关验证合同形状并冻结发布者声明；发布者自身的真实性由其接入边界负责，
本实现没有独立的云 manifest resolver。

网关在同一 SQLite 事务中保存 `(binding, path, artifactID, revision,
originRunID, manifest)` 并添加 `appReplyAuthority`。客户端只能从已验证的
运行事件和原网关地址取得这一身份。产物路径是标识，不是本地文件读取许可。
权限判断仍需由原生页面核对当前会话、画布、权限与页面代次。

同修订的不同 manifest 或来源冲突；旧修订不签发新权限。新修订没有 manifest
时撤销原权限。旧数据库迁移不从历史 HTML 或数字 revision 补造权限。
已接受 reply 的回执不因页面更新或撤销而消失。

## 接口

所有地址以 `/v1` 为前缀。每个路径段须独立 URL 编码，尤其是不透明 run ID。
认证和禁止重定向规则沿用现有 gateway transport。

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| GET | `/runs/{originRunID}/artifacts/{artifactID}/app-reply-manifest` | 读取当前签发身份 |
| POST | `/runs/{originRunID}/app-replies` | 首次提交或显式重试同一身份 |
| GET | `/runs/{originRunID}/app-replies/{replyID}` | 只读核对接受结果与当前运行状态 |
| POST | `/runs/{replyRunID}/app-reply-continue` | 用户显式恢复已暂停执行 |

POST 只接受以下字段：

```json
{
  "schemaVersion": 1,
  "appReplySchemaVersion": 1,
  "requestKey": "55b901e4-0ed9-400f-8a55-562fdf17f233",
  "binding": {"sessionID": "session", "projectID": "project", "canvasID": "canvas"},
  "originRunID": "original-run",
  "artifactID": "board",
  "artifactRevision": 1,
  "manifestRevision": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "replyJSON": "{\"reply_id\":\"55b901e4-0ed9-400f-8a55-562fdf17f233\",\"action\":\"previs_reply\",\"payload\":{}}"
}
```

`replyJSON` 按原 UTF-8 字节保存，不重新编码。它必须是 object，含 UUID 形状的
`reply_id`、`action=previs_reply` 和 object `payload`；可选
`expected_manifest_revision` 必须匹配权威 manifest。重复 JSON 字段、非有限
数字、无效 Unicode、未知字段及超过 32768 UTF-8 字节的 reply 在接受前拒绝。
`requestKey` 等于规范化小写 UUID，HTTP `Idempotency-Key` 等于该 key。
首次接受要求原运行已经 `completed`；不能把一个未完成原运行的工具历史
带到另一个运行。

同一 UUID 全局只能绑定一个原始 body。重试时修改 payload、空白、转义形式、
来源、会话或修订均冲突。完全相同的显式重试返回原运行身份并标记
`deduped=true`；持久的首个回执和 `app_reply_accepted` 事件保持不变。
每个原运行最多接受 128 个 reply。

首次接受一次性提交新 run、原始 reply body、接受事件及幂等回执。提交完成后
才启动执行。回执包含原 binding、原运行、产物/manifest 身份、reply ID、
原 reply 字节 SHA-256、新 run ID 和 `acceptedAt`。它不含用户 payload。
只读核对额外返回 `phase` 与 `state`：执行中为 `running`，终态为 `terminal`，
重启后暂停为 `unknown`。业务终态的 failed/cancelled 不否认此前已接受。

## 分派与恢复

普通 `POST /runs` 拒绝外部 `appReply` 字段，不能绕过专用接受事务。网关要求
provider 显式提供 `generate_app_reply(command, messages, appReply, emit, alive)`；
工具续轮或显式恢复使用单独的 `continue_app_reply`。后者不得重新应用首次
业务动作。payload 不会被网关转换成新的聊天 user message。

普通 OpenAI 聊天 adapter 尚未实现上述专用回调，因此返回
`422 APP_REPLY_PROVIDER_UNSUPPORTED`，且不会发出聊天请求。没有 provider 时
返回 `503 APP_REPLY_PROVIDER_NOT_CONFIGURED`。`health.appReplyExecution` 明确
显示是否有专用首次执行回调；它不证明远端业务能力或凭据已经验收。
当前只有显式启用的 synthetic provider 用于验证本地执行合同。

客户端在尝试发送前需先持久保存不可变 body，并区分：

- preflight：尚未开始网络提交；页面身份、manifest、存储或能力校验未通过。
- rejected：HTTP 400/401/403/404/405/409/413/422/429 的明确拒绝。
- unknown：连接丢失、5xx、响应无效或取消后无法证明是否被接受。

unknown 只能先核对，不能自动新建 UUID 或再次 POST。核对 404 只证明当前
查不到回执，仍需用户显式重试原身份。服务进程被杀或重启后不自动启动旧动作；
即使显式重试 POST 原 body，也只是取回原 run。恢复旧 run 是单独的原生运行
控制动作，使用专用 continuation 回调。

专用续接只接受 `schemaVersion=1`、新控制请求 `requestKey`、原 `binding` 和
原 `clientInstanceID`。它只适用于 `waiting_suspended`，保留原 command 中
的 `appReply` 与历史，不接受新的 history、payload 或首次业务动作。控制回执
与执行状态使用同一事务持久化；重复控制请求只返回原回执。普通 `/continue`
不得用新聊天历史替换结构化回复。原 run descriptor 提供原 client identity，
供原生 journal 验证执行 owner；此字段不授予页面工具权限。

SQLite 当前 schema version 为 4；v0–v3 原有记录迁移保留。WAL/FULL、
数据库单 owner 锁、接受事务回滚和运行重启暂停沿用现有实现。普通日志不输出
reply body 或凭据，业务 payload 保存在私有数据库中，不属于诊断导出。

## 原生持久化与恢复

`AgentAppReplySubmission` 保留原始 reply UTF-8 和首次编码的 HTTP body。
`AgentAppReplyStore` 使用独立 `app-replies.sqlite3`，以
`clipslots.app-replies.v1` header 区分合同；底层通用 SQLite schema 为 2，
不是上面的服务端 schema 4。每次读取先核对权威记录，不回退到历史快照。
正文最大 32768 bytes，单条持久记录最大 128 KiB，全库 128 MiB、4096 条，
同原运行最多 128 条；容量不足不清理未决回执。

首次 `submit` 先提交 saved 记录，再读取原 manifest 与执行能力，权限校验通过后
将 attempt 原子递增并记录 unknown，最后发出已保存的 HTTP body。并发进程
只能取得一次首次 attempt。任何发送尝试后，普通 `submit` 不再 POST。
发送前的保存/能力/权限失败是 preflight；发送后的连接失败、取消、无效响应
和接受回执保存失败均是 unknown。已接受回执不因页面关闭或业务 failed
而回滚，迟到的运行中状态也不能覆盖已经确认的终态。

`snapshots(binding:)` 供原生恢复界面发现历史 reply 身份；页面重开不需要
重新生成 UUID。`reconcile` 只 GET 原身份，404 仍是 unknown；`retry`
要求调用方显式提供当前 attempt，保存的原网关、正文和 request key 全部保持。
原生恢复面板使用这些接口，页面不能构造独立的恢复来源。

页面 `ui/message` 的 `details` 必须含 `type=app_reply`、UUID `reply_id`、
`action=previs_reply`、object `payload` 与可选 `expected_manifest_revision`。
本地桥在第一次转为 native reply JSON 时固定编码，其 UTF-8 字节随后由
独立账本保存，重试不再编码。页面不能选择 endpoint、origin run、binding
或产物身份。`tapnow/validateAppReply` 使用同一 projection；
`tapnow/getAppReplyRunStatus` 只接受属于当前原生产物账本的已知 `run_id`。

每次网络阶段前后均检查原生 session、访问模式、画布激活代次、页面代次、
产物修订与本地 run 身份；同会话/权限/项目往返不会恢复旧授权。接受回执
仍可保存，但旧回调不得接管另一个会话或覆盖更新的原生运行。

接管新 run 只 GET 原 descriptor 和 SSE，在 `app-reply-runs/{replyID}`
独立 journal 保存回执、原 owner、事件游标和消息；保留原运行 journal。
接管或会话保存失败不撤销已接受回复。服务重启后的暂停执行需再点击原生
「续接运行」，由专用续接接口调用 `continue_app_reply`。
面板的核对/重试/接管动作都使用账本中的原地址、原 body 和原 attempt。
已保存但从未尝试的回复也可显式发送；读取 404 不自动重新提交。

接受后的 run journal 使用 schema 5，原始 reply body 单独存于不可变 `appReply`
state row，不随每个 SSE 游标重复编码写入 header。缺失该权威 row 时拒绝恢复；
旧版本 reader 拒绝 schema 5，避免忽略回复身份后按普通聊天执行。原生独立
reply ledger 仍为底层 schema 2，服务端仍为 schema 4。旧 run journal schema
2–4 与早期候选的 embedded reply header 可无损迁移。

带原生工具 provenance 的 journal 使用 schema 6。收到带 App 权威身份的
产物事件时，原生 backend 冻结该修订对应的声明、来源标签、提交 key、执行
scope 和 client identity；它不从页面 JSON 读取这些字段。产物仓库保存这份
独立上下文，后续聊天覆盖会话 journal 后仍可核对原声明。新修订、删除或同
修订冲突不保留旧权限。

首次接管回复时可显式调用 `activateAppReplyTools`，为本轮新执行者建立新的
instance UUID，scope 的 turn ID 固定为 `app-reply:{replyID}`。原 client
identity 只用于匹配远端目标，新执行者同时必须满足原声明的精确匹配和当前
目录/画布/应用授权。原声明不授予已撤销目录或旧工具实例权限。原聊天和各
回复的同名 call ID 分别保存在独立 execution scope。

授权只能在该回复尚未消费事件、尚无工具预留且从未绑定执行者时建立。
普通 resume、重启或再次接管不为旧预留调用重新绑定 owner。已经完成并
持久保存的工具结果可从原 execution scope 读取并补交；没有持久结果的
执行保持 unknown，不开始第二次副作用。服务暂停时，补交结果之后还需独立
的原生续接动作；补交本身不自动恢复首次业务动作。

`appReplyTools` 与 `artifactTools` 为独立 state rows，不与 SSE header
反复复制。schema 6 header 记录预期 row 名，缺失权威 row 即拒绝恢复，旧
reader 拒绝 schema 6。回复 HTTP body、独立 ledger schema 2 和服务端
schema 4 均保持原合同。

## 工具消息归属

`AgentMessage` 的本地 `runID`、`executionScope` 与 `toolOrigin` 保留原调用
assistant UUID、run、scope 和 execution ID。provider 的 call ID 不改写，
不作为跨 run 唯一标识。工具请求在执行前与原 assistant 一起持久保存，结果
只能补入该调用；显示、恢复和中断补全使用同一关联。

旧记录没有这些字段时按消息位置配对。先于 assistant 的旧结果只有在候选
assistant 唯一时才关联；无法确定归属的旧正文保留，不能用另一轮的完成结果
填补缺口。恢复不按全局 call ID 覆盖旧消息。

有原生消息归属的 journal 使用 schema 7，header 的
`nativeToolMessagePresence` 指纹对应消息与 execution rows 的归属字段。
缺失归属、run/scope 不匹配、结果与原执行记录不符时读取失败；旧 reader 拒绝
schema 7。原 schema 6 的工具上下文 rows 与存在性检查继续保留。指纹、消息
metadata、结果和事件 cursor 在同一 SQLite 事务中保存。

## 验证

从项目根目录执行：

```bash
python3 -B gateway/test_app_reply.py
bash scripts/test-app-reply-native.sh
bash scripts/test-app-reply-tools.sh
swift build
python3 -B scripts/test-app-reply-page.py --binary .build/debug/ClipSlots
```

此测试使用真实 loopback HTTP、独立服务进程、SQLite 和 SIGKILL。它覆盖
并发去重、变更身份拒绝、原始 UTF-8 上限、丢失 HTTP body 后核对、提交事务
中间被杀后的全量回滚、接受后被杀的 unknown、撤销后回执保留、普通 provider
不被调用、v3 迁移字节保留，以及事务尾部保存失败的回滚。

原生测试使用独立 Swift 进程、真实 URLSession、HTTP listener、SQLite 和
SIGKILL，验证保存失败、并发 attempt、未知结果核对、原始字节、权限撤销、
客户端/服务端被杀、取消及跨 origin 重定向。页面测试使用真实 WKWebView、
AgentChatModel、URLSession 和独立 synthetic gateway 进程，检查回复、回执、
SSE 接管、权限/会话往返及进程重启后的专用续接。这些本地测试不验收真实
前台输入、云服务或原 28 项计划的其他交付项。tool-input/tool-result 的
projection revision、完整资源生命周期和真实 provider 业务仍须单列验证。
工具测试包含真实临时文件、同调用 ID 的独立 scope、声明变更拒绝、SIGKILL 后
原结果补交和 unknown 保留；它不会访问生产目录或付费 provider。
