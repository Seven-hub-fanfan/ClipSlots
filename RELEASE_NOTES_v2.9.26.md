# ClipSlots v2.9.26

本次为安装流程修复版本，聚焦 CLI / Skill 安装体验与安全性。

## 🧭 路径统一
- CLI 命令固定安装到 `/usr/local/bin/clipslots`（软链到应用内 `clipslots-cli`）。
- 清理历史遗留的手动放置旧二进制 `~/bin/clipslots`。
- 文档与 Skill 同步：`docs/clipslots-cli-skill-draft.md`、`skills/clipslots-manager/SKILL.md`（含 frontmatter/requires）中所有 `~/bin/clipslots` 统一替换为 `/usr/local/bin/clipslots`，并同步刷新已安装 App bundle 内的 SKILL.md。

## 🔐 Gatekeeper 首次打开提示
- 首次打开 ClipSlots.app 时，macOS 可能提示"无法验证开发者"，请右键点击 App → 选择「打开」→ 点击「打开」确认即可。
- 该提示已同步补充到 README/发布说明与 App 内版本号悬停提示中。

## 🧩 安装后 PATH 检测提示
- CLI 安装成功后，若检测到 `/usr/local/bin` 不在当前 `PATH` 中，会在成功提示后追加一行：
  "提示：请确认 /usr/local/bin 在您的 PATH 中，否则在终端输入 clipslots 可能找不到命令。"

## 🛡 Skill 卸载/更新软链安全防护
- `AgentSkillInstallManager` 在安装/更新前增加软链接守卫：仅当目标为软链接（或不存在）时才执行删除并重建软链；若目标是用户的**真实目录/文件**，则不做任何 `rm -rf` 删除并给出安全提示，避免误删用户数据。
- 判定采用 `lstat` 语义（`FileManager.attributesOfItem` 的 `.type == .typeSymbolicLink`），不跟随软链接。
