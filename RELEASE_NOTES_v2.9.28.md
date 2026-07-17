# ClipSlots v2.9.28

本次为问题修复版本，针对 v2.9.27 全新安装后暴露的 3 个问题。

## 修复内容

1. **Skill 市场详情页顶部「安装」按钮修复**
   顶部「安装」原为纯展示徽章、点击无反应。现已改为可点击按钮，一键把本 Skill 安装到所有检测到的 Agent（Claude Code / Cursor / Codex / Gemini CLI）。保留软链接安全守卫：目标若为真实目录/文件则跳过，绝不删除用户数据。

2. **修复 CLI 安装报错「找不到内置 CLI 二进制 (clipslots-cli)」**（最重要）
   根因：v2.9.27 打包脚本重写后遗漏把 CLI 二进制打进 App bundle。现打包脚本已固化：构建后把 `clipslots-cli` 打入 `ClipSlots.app/Contents/MacOS/`（并单独签名），同时把内置 Skill 目录打入 `Contents/Resources/skills/`；打包校验会在缺件时直接报错，确保每次发版都带 CLI。

3. **Skill 页「安装到 Agent」区域刷新按钮修复**
   刷新按钮现会重新扫描本机 Agent（`~/.claude` / `~/.cursor` / `~/.codex` / `~/.gemini`）并给出可见反馈。

## 安装说明

打开 DMG 后将 ClipSlots 拖入 Applications 即可。本 DMG 为 ad-hoc 签名，首次打开如遇 Gatekeeper 提示，请右键 → 打开。
