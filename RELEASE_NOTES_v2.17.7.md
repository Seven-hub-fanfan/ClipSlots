# ClipSlots v2.17.7

## 新增：Tika Agent 双后端

- Agent 设置新增 **DeepSeek / Tika Agent** 一键切换，保留原 DeepSeek 通道。
- 接入本机 `tikacli chat --json`，支持流式正文与推理输出。
- 新增 `<clipslots-call>` / `<clipslots-result>` XML 工具契约，让云端 Tika Agent 经 App 安全调用本机 ClipSlots CLI。
- 本地命令不经过 shell，使用 argv 直传，并限制在 ClipSlots 子命令白名单内。
- 支持 Tika Agent ID 与 tikacli 路径配置，切换后无需重启 App。

## 稳定性与安全

- Tika JSON 流采用顶层对象分帧，兼容多行 pretty-print、任意 stdout 分块和字符串转义。
- 子进程 stdout/stderr 并发 drain，避免管道缓存死锁；增加逐轮超时、取消和 SIGKILL 兜底。
- 每个工具轮使用自包含 transcript + 独立 tikacli 会话，避免编辑页与画布页并发串话；保留历史工具结果供后续追问。
- 工具循环设最大轮数，非法命令返回结构化错误并回喂模型，不在本机执行。
- 为 JSON 分帧、XML 提取、shell-lex、白名单、结果回喂和 mock tikacli 端到端链路补齐 smoke。

## 验证

- ClipSlotsKit smoke：32427 通过，0 失败。
- Tika Web Agent `3247763614212` 已创建并发布 V2，真实 tikacli 对话验证通过。
