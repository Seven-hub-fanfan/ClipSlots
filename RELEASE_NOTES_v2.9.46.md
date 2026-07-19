# ClipSlots v2.9.46

## 本次更新

### 新增功能
- **「命令行工具」设置页新增 Agent Skill 卡片**：直观展示 Skill 安装状态，支持「重新安装」与「卸载」操作，方便在各 Agent 环境（Claude Code / Cursor / Codex / Gemini CLI）中管理 ClipSlots Skill。
- **新增「卸载 App」卡片**：一键卸载入口，弹窗提供勾选项，可选择同时删除本地数据、卸载 CLI（`/usr/local/bin/clipslots`）、卸载已安装的 Agent Skill 软链，卸载体验更完整、更干净。

### 内部变更
- 新增 `AppUninstaller.swift`，统一封装 App / 数据 / CLI / Skill 的卸载逻辑。

---
安装：下载 DMG 后打开，将 ClipSlots 拖入 Applications 文件夹即可。
