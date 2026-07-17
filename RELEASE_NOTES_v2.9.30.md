# ClipSlots v2.9.30 发布说明

## App 启动时自动同步 Skill 到 AI 工具目录

- 新增 **启动自动同步**（`syncInstalledSkillsOnLaunch`）：App 每次启动时，会自动把内置 Skill 同步到已安装的 AI 工具目录，确保工具侧使用的始终是与当前 App 版本一致的 Skill。
- **修复升级 App 后旧版 Skill 不自动更新的问题**：
  - 修复软链（symlink）方式安装在 App 更新后可能失效的问题；
  - 修复早期「复制式」安装的 Skill 不会跟随 App 更新的问题——旧版复制安装的 Skill 现在会在启动时被自动刷新为最新版本。

## 涉及文件

- `Sources/ClipSlots/AgentSkillInstallManager.swift`
- `Sources/ClipSlots/main.swift`
- `Sources/ClipSlots/PluginsView.swift`
