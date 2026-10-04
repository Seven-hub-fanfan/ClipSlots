# API 凭据重复授权修复

## 行为

- 同一进程首次读取 API Key 时，侧栏、设置页和后端共用一次钥匙串读取及其结果。
- 取消或拒绝授权后，页面刷新不再次请求授权；在 Agent 设置里点「重新授权」可重试。
- 等待系统授权期间，窗口保持可操作；设置页显示正在访问钥匙串。
- 无凭据时发送的内容会保留，配置完成后可重试。停止后，迟到的读取结果不会恢复已停止的请求。
- Tika 后端不在启动时读取 DeepSeek API Key。

API Key 仍只保存在系统钥匙串；缓存仅存在于进程内存，未改变 ACL、存储位置或签名策略。ad-hoc 签名变化后的首次系统授权仍可能出现；本修复不保证不同应用、不同钥匙串条目或操作系统自身的授权可以合并。

## 实现

`AgentKeychain` 的锁覆盖系统读、写、删及缓存失效。并发读取共享成功、缺失或失败状态，防止迟到读取覆盖新写入、恢复已删除的值。错误重试只清除失败缓存，成功授权不会因点击重试而失效。

`AgentConfigView` 在后台读取和修改凭据，等待期间禁用重复操作；仅把脱敏状态交给界面。`AgentChatModel.send` 不再同步查询钥匙串，异步后端仍在任何网络请求前验证凭据。侧栏按当前后端决定是否探测。

## 验证

- 真实系统钥匙串使用随机测试 service 和合成内容，前后均为 12 个并发调用：修复前调用系统 12 次，修复后 1 次，结果均正确；测试结束删除临时条目。
- `Tests/AgentKeychainRegression/main.swift`：57 项通过。覆盖并发、缺失、三种授权失败、显式重试、失败写删，以及读/写/删/失效竞争。不访问用户凭据。
- 隔离原生 Agent 回归：36 项通过，包括授权等待期间的主线程响应、停止、缺失凭据后的配置重试，以及 DeepSeek/Tika 的流式显示和输入。桌面会话在运行前后均未锁定；接口及凭据使用 fixture。
- Debug、Release 构建与修复包签名校验通过。
- 核心回归最终串行运行 32,715 项通过，0 失败（`.dbg/keychain-core-smoke-serial.log`）。首次与编译同时运行时有一项 0.5 秒 Tika 超时用例失败，保留原日志；未修改代码或测试阈值，编译结束后重跑通过。

重跑凭据专项：

```sh
swiftc -parse-as-library Sources/ClipSlotsKit/AgentKeychain.swift Tests/AgentKeychainRegression/main.swift -o .dbg/keychain-regression
.dbg/keychain-regression
```

运行时证据：`.dbg/trae-debug-log-keychain-single-unlock.ndjson`（pre 1–25 行，post 26–39 行）。
原生回归报告：`build/validation/agent-perf-keychain-single-unlock.json`。

调试会话 `debug-keychain-single-unlock.md` 保持 OPEN，等待用户实际启动后的授权体验反馈。探针未读取真实 API Key，未发起付费 API 请求。

## 本机更新

2026-10-02 已安装并启动 `/Applications/ClipSlots.app`，版本 **2.17.8（217805）**。

- 原 217804 备份：`build/backup/ClipSlots-217804-before-keychain-fix-20261002-151124.app`。
- 画布备份：`build/local-keychain-fix-20261002-151124/canvas-data-before-update`。
- 安装包及内置 CLI 签名有效，与 stage 文件校验一致。
- 页面索引、编辑页及画布 Agent 会话文件前后校验一致；`~/.local/bin/clipslots` 软链保留。
- 安装记录：`.dbg/keychain-single-unlock-install.json`。

本次更新保留此前素材节点、引用缩略图、直接删除及 Tika 长任务修复，未提交或发布远端版本。
