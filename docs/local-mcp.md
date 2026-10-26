# 本地 MCP（v2.17.82）

`clipslots-mcp` 是独立的 stdio MCP 可执行文件，直接使用 ClipSlotsKit 数据层和原生画布事务。它不启动 `clipslots` 业务 CLI。

## 独立槽位连接

在 MCP 客户端中添加：

```json
{
  "mcpServers": {
    "clipslots-slots": {
      "command": "/Applications/ClipSlots.app/Contents/MacOS/clipslots-mcp",
      "args": ["--slots"]
    }
  }
}
```

只读连接使用 `["--slots", "--read-only"]`。槽位连接无需 GUI 运行。写入由调用方客户端按用户授权发起。

提供 17 个数据工具：页面与组列表、槽位列表/读取/搜索/写入/清空/复制、创建页面与组、组重命名与软删除、页面软删除、附件摄取、设置/移除缩略图、索引健康检查。保留存储锁、附件快照和软删除保护。写入可携带 `read_slot` 返回的 `revision` 作为 `expected_revision`，冲突时返回 `REVISION_CONFLICT`。

## 当前画布连接

从应用的外接 Agent 入口复制当前项目的 MCP 配置。配置指向同一独立 MCP 文件，并带有当前项目、画布、会话和临时连接信息。连接有效期为 30 分钟；项目或会话切换、停止和关闭会撤销连接。临时配置包含连接令牌，应只交给选定客户端。

先调用 `clipslots_context`，再通过 `canvas_current` / `canvas_get_node` 读取实时状态和版本。`canvas_*` 操作支持新建、正文修改、参数设置、移动、布局、连线/断线、编组、删除以及撤销/重做。修改前读取实际 revision；原生审批通过后再应用，返回真实节点身份和历史回执。之后回读结果。

Full Access 连接声明 46 个工具，其中包含项目产物读取、画布分页读取、17 个槽位工具以及原生画布操作。此数量是工具目录规模，不是完成度或性能评分。访问模式会缩减目录；显式 `--read-only` 不可扩展原连接权限。

分页画布读取在实际内容不变时复用快照身份，内容或运行记录变化后刷新。资料中只有媒体名称或索引时不代表模型已经看过画面。应用未运行时，项目模式只能读取已保存快照，不能修改画布；独立槽位模式仍可直接操作数据。

## 与生成服务的边界

`canvas_list_models` 和 `canvas_generate` 是生成服务适配工具，仍依赖 Crate/ByteArtist 的目录、认证、网络和额度。设置新的 Crate 模型 ID 也需要服务目录校验。这些服务能力应单独评价，不能算作 MCP 独立于 CLI 的本地数据能力。创建图片/视频节点本身不会提交生成。

本地 MCP 使用 stdio JSON-RPC，支持 initialize、ping、tools/list、tools/call 和通知；不提供远端 HTTP MCP、OAuth 服务，也没有对外实现标准 MCP Apps 的 `ui://` 资源协议。应用内 HTML 产物交互属于另一条原生预览链。

## 打包

构建 `ClipSlotsMCP`，将产物放到 `Contents/MacOS/clipslots-mcp` 并独立签名，再签名整个应用。不要把它命名成 `clipslots`；macOS 不区分大小写时会覆盖 GUI 文件 `ClipSlots`。`scripts/package_rea_continuation.py` 已包含三个可执行文件的打包和签名。
