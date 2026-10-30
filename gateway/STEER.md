# 自有 Gateway Steer v1

这是 ClipSlots 自有服务的追加指令协议，版本独立于 Gateway v1 和 TapNow。
服务端已实现消费链；当前 Swift/App 仍使用停止核对后重提，客户端接入尚未验收。

## Run 能力

`POST /v1/runs` 的回执和 `GET /v1/runs/{runID}` 在支持的 chat run 上返回：

```json
{
  "steerCapability": {
    "schemaVersion": 1,
    "safePoints": ["model_boundary", "tools_resolved"],
    "accepting": true,
    "maxPending": 32,
    "maxPerRun": 64
  }
}
```

只有明确的 run 能力允许客户端显示运行中追加入口。health、backend 名称、
本地动画或仅存在一条 steer 路由均不能替代能力证据。textPolish run 无此能力。
`accepting` 仅在 streaming 为 true；waiting、终态和重启后的 suspended 不接收新指令。
原客户端的 `cancel → query → 新提交` 路径继续兼容，应明确标为停止后发送。

## 提交

`POST /v1/runs/{runID}/steer`，使用原有 Bearer 认证和 JSON body framing。
`Idempotency-Key` 必须等于 `requestKey`：

```json
{
  "schemaVersion": 1,
  "steerSchemaVersion": 1,
  "requestKey": "steer-9A13E8D8-09E8-42DB-AAD9-515370425FD7",
  "binding": {"sessionID": "s", "projectID": "p", "canvasID": "c"},
  "runID": "run/opaque+id",
  "clientInstanceID": "original-client",
  "submissionID": "9A13E8D8-09E8-42DB-AAD9-515370425FD7",
  "message": {
    "id": "9A13E8D8-09E8-42DB-AAD9-515370425FD7",
    "role": "user",
    "content": "保留已完成的工作，补充这条要求。"
  }
}
```

`message.id == submissionID`，且是 UUID；requestKey 固定为 `steer-<submissionID>`。
同一 key 的字节含义改变返回 409，不产生第二份输入。已有历史消息 ID 不可复用。
body 和 message 严格限制允许字段；不接受新 config、tools、system message、
toolCalls 或 tool result。run 的模型、系统提示、声明与工具 owner 保持原始权限。

content 支持文本，或既有 MessageContent v1 的文本/捕获图像数组。文本最多
262,144 UTF-8 字节；图像继承单项 1 MiB、合计 2 MiB、最多 6 张、MIME/magic
及 provider image capability 校验。服务不读取客户端文件或获取外部图像 URL。
HTTP body 上限仍为 8 MiB。当前上下文加已排队输入的编码体积不得超过 8 MiB，
消息数不得超过 1000。排队最多 32 项，每个 run 总计最多 64 项；不通过清理
未消费输入或回执回避上限。

## 状态和 placement

提交的持久回执为 `accepted`，`revision=1`，没有 placement。它只证明已接收，
不能显示为“已消费”。重复 POST 和 `GET /v1/requests/{requestKey}` 返回同一份
不可变的 accepted 回执，即使此后已经消费、返回或 run 终止。

最新状态由 `GET /v1/runs/{runID}/steers/{submissionID}` 返回；同一结构随
`steer_state` SSE 事件持久化：

```json
{
  "schemaVersion": 1,
  "steerSchemaVersion": 1,
  "binding": {"sessionID": "s", "projectID": "p", "canvasID": "c"},
  "runID": "run/opaque+id",
  "clientInstanceID": "original-client",
  "requestKey": "steer-9A13E8D8-09E8-42DB-AAD9-515370425FD7",
  "submissionID": "9A13E8D8-09E8-42DB-AAD9-515370425FD7",
  "messageID": "9A13E8D8-09E8-42DB-AAD9-515370425FD7",
  "state": "placed",
  "revision": 2,
  "sequence": 1,
  "acceptedAt": 1793260000.0,
  "placement": {
    "point": "model_boundary",
    "generation": 1,
    "messageIndex": 3,
    "placedAt": 1793260001.0
  }
}
```

sequence 是服务端在 run 内接收的顺序。messageIndex 是实际 provider wire messages
的零起始下标，包含 system message；generation 是下一轮模型请求的代数。
placement 证明消息已在安全点原子写入权威上下文与事件日志，不承诺上游已完成
推理或产生结果。正常路径在提交该事务后使用同一个 run 发起下一轮实际模型请求。

安全点只有：

1. `model_boundary`：当前模型轮次完整结束、无工具调用时；先保存 assistant，
   按接收顺序写入输入，再生成下一轮。当前输出保留，不取消已有工作。
2. `tools_resolved`：全部客户端工具结果持久入库时；先保存所有 tool messages，
   再写入输入。部分工具返回、未知工具结果和待确认交互均不是安全点。

有工具的模型轮次结束时不会先插入 user message。工具结果必须仍紧跟其声明。
一个安全点的消息、placement、事件和 generation 共用一个 SQLite 事务。
事务中途失败不得留下 placed 事件或部分上下文；服务进入明确失败并返回全部
尚未消费的输入。

`returned` 为 `revision=2`，没有 placement，含固定 returnReason：
`TERMINAL_CANCELLED`、`TERMINAL_FAILED`、`RUN_WAITING`、`PROCESS_RESTART`
或 `CONTEXT_LIMIT`。输入原文仍在持久 body 中，客户端保留草稿、附件与引用。
不得把 returned 或 404 自动转成新的收费任务。

## 恢复与乱序

先在本地持久化 submission/body/key，再发送；未知提交结果首先核对原 requestKey
和最新 steer 状态，不能换 key 重发。accepted 和 placed 分开处理；旧 revision
不能覆盖终态。同 revision 的身份或 placement 冲突必须拒绝。SSE event cursor
只有在输入状态和正文一起提交后才推进，不以状态查询回执推进 cursor。

服务进程真实退出后，未消费项返回 `PROCESS_RESTART`，原 streaming run 转成
waiting_suspended。已 placed 的上下文/证据保留，不自动重复模型请求。
显式 continue 必须带回每一条已 placed 消息的原 UUID、精确 content 和接收顺序；
缺失、Unicode 规范等价但字节不同、重复 ID 或乱序均返回 409，
不允许旧历史静默删掉已消费的输入。

## 当前验证

从源码目录运行 `python3 -B gateway/test_steer.py`。测试使用真实 loopback
HTTP、OpenAI SSE adapter、SQLite 和 SIGKILL；上游仅为可控本地合成 listener。
它验证消费前不会发第二轮、双工具结果的真实位置、幂等与返回、事务部分失败、
消费后重启/缺失历史、Unicode/图像、权限与预算。原始 provider 请求保存在
输出的 `/tmp/clipslots-gateway-live-python-*` 目录。

此服务合同通过不等于 App 或前台 GUI 已通过；Swift 身份归约、客户端 unknown
核对、队列恢复和实际 App 输入验收仍需接入后完成。远端服务与 TapNow 1:1
能力缺口由 M13/E01 独立保留。
