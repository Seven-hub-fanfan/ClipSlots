# Agent 输入法占位提示修复

用户反馈：输入中文拼音、候选词尚未确认时，“随心输入”仍显示在文字背后。

原占位提示由 SwiftUI 根据已提交的 `model.draft` 绘制。原生 NSTextView 的输入法组合文本（marked text）可能尚未同步到 Binding，导致提示和拼音重叠。

## 修复

- `AgentDraftEditor.Editor` 根据原生文本缓冲区和 marked text 状态绘制占位提示，移除侧栏中的独立 SwiftUI 文字覆盖层。
- 开始组合输入立即重绘；确认候选词后保持隐藏；取消组合输入或删除到空白时恢复。
- 普通文字、emoji、多行插入、外部草稿清空使用同一判断。
- 提示与文本使用相同的文本容器位置，颜色随浅深主题更新。
- 保留原有输入法组合文本保护与 Cmd+Return 发送判断；本次不改变提交逻辑。

## 验证

- Debug、Release 构建通过，Release 耗时 59.48 秒。
- 独立 bundle、数据目录与模拟服务运行原生 Agent 回归：**53 项通过，0 失败**。
- 新增 17 项输入检查覆盖两种主题下的拼音组合、视图刷新、候选确认、删除、取消，以及普通文字、emoji、多行、外部清空。
- 浅色空白/组合输入、深色组合输入截图已检查，拼音背后没有残留占位文字。
- 原生回归前后 `sessionLocked: false`。使用 NSTextView 的真实 `setMarkedText`、`insertText`、`deleteBackward` 和 `unmarkText` 路径；未自动操作用户的系统候选词窗口。
- 本次未读取真实 API Key，未请求外部模型。

报告：`build/validation/agent-perf-agent-placeholder-ime.json`。
截图：`build/validation/agent-placeholder-{light,dark}-{empty,composing,committed}.png`。
运行日志：`.dbg/agent-placeholder-native.log`。

## 本机更新

2026-10-02 已安装并启动 **2.17.8（217806）**。

- 旧版备份：`build/backup/ClipSlots-217805-before-agent-placeholder-fix-20261002-151932.app`。
- 画布备份：`build/local-agent-placeholder-fix-20261002-151932/canvas-data-before-update`。
- App/CLI 签名及文件校验通过；页面索引、两份 Agent 会话与 CLI 软链保持不变。
- 安装记录：`.dbg/agent-placeholder-install.json`。

保留 217805 的凭据读取合并及此前修复。未提交、推送或远端发布。
