# 自有网关 decision v1

该合同只描述本仓库网关的实现。它不是 TapNow 云端协议或执行算法的推断。
`decisionCapability: {"schemaVersion":1,"readback":true}` 在运行描述中声明能力。
旧客户端的 `continue` 和 `answer` 入口继续可用；其自由格式回答不代表
通过 v1 的结构校验。

## 原请求与读取

`waiting_question` / `waiting_confirmation` 事件新增以下服务端字段：

```json
{
  "interactionID": "original-opaque-id",
  "decisionSchemaVersion": 1,
  "requestRevision": 1,
  "requestFingerprint": "64位小写SHA-256",
  "createdAt": 1793234364.0,
  "serverTime": 1793234364.0,
  "expiresAt": 1793234664.0,
  "params": {}
}
```

`requestFingerprint` 由服务器计算，客户端必须原样保存。身份属于原
run、binding 与 clientInstanceID。相同 run 下禁止复用一个已解决的
interactionID 或把相同 ID 改为另一份请求。最多保留 128 个原请求；
达到限额只拒绝新请求，不清理旧决策。

`GET /v1/runs/{runID}/interactions/{interactionID}` 使用现有鉴权，
两个 ID 都分别进行 URL 编码。结果包含 schema、binding、runID、
clientInstanceID、interactionID、kind、上述时间和指纹以及 `state`：

| state | 权威含义 |
| --- | --- |
| pending | 原请求仍在等待，尚未过期，没有决策 |
| expired | 原请求仍在等待，但服务端时间已到期 |
| superseded | 原请求已被停止、普通续轮或另一请求替代 |
| resolved | 原决策已在服务端事务中接受，后续运行结果不能撤销此事实 |

读取不接受答案、不发起模型请求，也不返回 params 或回答正文。
404 表示没有可读记录，不能据此断定未知 POST 从未送达。旧数据库中
缺少可判定的历史决策时仍返回 404，不从模型输出推导答案。

## 提交与核对

`POST /v1/runs/{runID}/continue` 的 v1 决策正文：

```json
{
  "schemaVersion": 1,
  "decisionSchemaVersion": 1,
  "binding": {"sessionID":"original-session"},
  "runID": "original-run",
  "clientInstanceID": "original-client",
  "interactionID": "original-opaque-id",
  "requestRevision": 1,
  "requestFingerprint": "原请求中的指纹",
  "requestKey": "不可变的本次回复身份",
  "answerJSON": "{\"decision\":\"accept\"}"
}
```

`Idempotency-Key` 必须与 requestKey 相同。`answerJSON` 是原始 JSON
字符串，支持 Unicode；服务端拒绝重复键、非有限数、非对象和不符合原
请求的字段。不得同时提供旧 `answer`，避免两份回答歧义。

成功的运行描述附带 `decisionReceipt`，SSE 同时保留
`decision_resolved`。二者是同一个事务中的权威记录。读取的 resolved
记录另带：

```json
{
  "decision": {
    "requestKey": "不可变的本次回复身份",
    "answerSHA256": "answerJSON的UTF-8字节SHA-256",
    "acceptedAt": 1793234365.0,
    "generation": 1,
    "messageIndex": 2
  }
}
```

跨语言不必重新格式化 JSON 后再计算摘要。答案的原始 UTF-8 字节用于
回执核对；实际上下文追加一个 user 消息，其 content 是解析后答案的
JSON，messageIndex 是消息数组的绝对位置。generation 标识接受后续轮，
不能作为操作已成功执行或费用已扣除的证据。

请求记录、接受记录、user 消息、generation、SSE 事件和通用 request
回执在同一 SQLite FULL/WAL 事务内提交。断线和重启后可按原 key
读取 `/v1/requests/{requestKey}`，或按原 interactionID 核对。相同 key
和相同正文重复提交返回原回执；同 key 不同正文、同请求另一 key、
旧 binding/client/run/revision/fingerprint 均拒绝。

客户端应先持久化不可变回复，再尝试一次发送。超时、过期、冲突或
响应缺失进入核对流程，不能换 key 或修改答案重发。resolved 的原
requestKey 与 answerSHA256 一致才能确认自己的答案已接受；另一 key
代表其他回复已解决该请求，应展示冲突。接受后断流仅影响后续执行
状态，不能回滚成未提交答案。

客户端把尚未尝试 POST 的持久回答显示为“回答已保存，尚未尝试发送”。
发送前核对失败或此时崩溃，恢复只读取原请求；用户可明确点击“发送已保存
回答”进行首次发送，继续使用原 key 和完整 answerJSON。首次发送前须重新
读取原请求，并先持久化 attempted=true。已尝试发送的回答即使 GET 返回
pending 或 404，也不开放此动作；陈旧界面对象同样不能越过 journal 标记。
首次保存失败须在原锁内读取本地 journal，证明回答未保存才恢复表单。
本地存储无法核实时显示保存状态未知，不假称回答已保留。

## 回答结构

普通确认使用 `{"decision":"accept"}` 或 `{"decision":"decline"}`，
按原请求 `availableDecisions` 校验。问题使用：

```json
{"answers":{"question-id":{"answers":["一个回答"]}}}
```

问题 ID 必须完整且唯一；每项只能一个非空字符串，非自由输入问题
必须匹配原选项。

批量请求的 params.items 是有序数组，每项必须提供原始 index/action，
可通过 availableDecisions 限定决定，通过 allowedModifications 指定
允许修改的字段。回复保留原顺序，禁止排序后重新生成 index：

```json
{
  "items": [
    {"index":9,"action":"write_file","decision":"accept",
     "modifications":{"text":"修改后的正文"}},
    {"index":2,"action":"organize","decision":"decline","modifications":{}}
  ],
  "costDecision": "decline"
}
```

每项都必须包含 index、action、decision、modifications。拒绝项的
modifications 必须为空。丢项、重项、换序、改 action、未声明的修改字段
或额外字段全部拒绝。全部拒绝仍保留每项身份。

若原 params 含 cost，回复必须另带 costDecision，并按 cost 的
availableDecisions 校验。费用决定与每项操作决定独立，不从操作接受或
拒绝推导。该记录不直接执行文件操作、改变工具权限或调用计费 API。

## 持久化与边界

服务数据库升级至 v3，保留旧事件、通用回执和旧运行消息的原字节。
仅迁移仍在等待且存在原请求的 v2 行。历史已取消/已接受但没有原始
决策证据的记录不作猜测补齐。旧自由格式问题可迁移并读取身份，但不能
假称通过 v1 的回答结构校验。升级后的数据库不应交给仅支持 v2 的服务。

决策读取、决策 SSE 和通用回执只含回答摘要和身份。回答正文仍属于原
提交和模型上下文；不得在普通诊断或 UI 确认摘要中泄露秘密答案。

本地验证入口：`python3 -B gateway/test_decision.py -v`。
测试只使用本地显式合成 provider，包含真实 HTTP、并发、事务 abort、
丢弃响应、SIGKILL、旧库迁移和 128 次真实回复。真实云服务与 App
恢复验收须另行执行。

## 本地 Swift/App 接入

客户端保留原始请求身份、不可变 requestKey 与 answerJSON UTF-8 字节，
并在独立 journal 行中保存接受凭据。界面只在 key 和摘要均匹配时显示
已接受；操作执行或费用实际扣除须有后续证据。接受后断流、失败或停止
不会把回答恢复成未提交。冲突、超时、过期及回执 404 只读取原决策。

系统时间偏差不用于判断 v1 请求到期。每次 HTTP 读取得到 serverTime，
以本进程的单调时钟计算剩余时间；重启恢复的表单须重新读取才启用回答。
旧服务仍使用旧 continue/answer 合同，本地排队只显示待核对；仅匹配的
通用 request 回执能证明接受，等待请求消失不能代替回执。

含新决策记录的客户端 SQLite journal 升级为 v4，旧 v2/v3 journal
仍可读取；旧客户端会拒绝 v4，避免忽略未决回答后重复发送。新记录没有
写入聊天确认摘要或普通诊断。不可变回答排除于事件头，流式事件只写
实际变化的数据。旧 run 归档仍保留，没有自动删除决策记录。

真实本地 HTTP 的客户端验证入口为
`python3 -B gateway/test_decision_client.py --binary <当前源码编译的GatewayDecisionLiveMain>`。
journal 的实际 SIGKILL、配额失败与长回答写量入口为
`python3 -B scripts/test-decision-journal.py --binary <当前源码编译的GatewayDecisionJournalMain>`。
原生 App 会话与独立进程恢复入口为
`python3 -B scripts/test-decision-app.py --binary <当前源码构建的ClipSlots>`。
上述验证均限于隔离目录及显式合成 provider，不能代替前台表单、
系统输入法、真实云服务或整个专项验收。

汇总服务、管理、旧追加协议和当前 Swift 兼容验证时执行：
`python3 -B gateway/test_decision_compatibility.py --swift-bin <当前源码编译的GatewayLiveMain产物>`。
该入口保留源码哈希、各场景原始数据库和机器可读汇总，当前 Swift
兼容通过仍不能代替新决策客户端的断流恢复验收。
