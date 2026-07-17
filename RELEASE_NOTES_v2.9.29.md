# ClipSlots v2.9.29 发布说明

## ① CLI 新增 `--page-name`（与 `--group-name` 对称）

- `list` / `read` / `write` / `paste` / `create-group` 命令新增 `--page-name <name>`，按页面名称精确匹配定位页面（遍历所有页面找 `name == pageName` 取其 id），用法与既有的 `--group-name` 完全对称。
- **页面名找不到时显式报错、非零退出**：`找不到名为 '<name>' 的页面`，不再静默回落到默认页面。
- `create-group` 的 `--page` 一并收敛为严格校验：显式传入不存在的页面 id/名时直接报错（`找不到 id 或名称为 '<value>' 的页面`），不再静默落到当前页面。
- `--page` 与 `--page-name` **互斥**：同时传入时报错 `只能指定 --page 或 --page-name 其中一个`。
- 错误输出沿用既有 JSON 结构（`{"ok": false, "error": ...}`），与其他命令保持一致。

## ② 新增 `CLIPSLOTS_DATA_DIR` 环境变量支持（env > 默认）

- 新增环境变量 `CLIPSLOTS_DATA_DIR` 可覆盖数据目录（优先级：环境变量 > 默认值 `~/.local/share/clipslots`）。
- **锁文件随数据目录移动**：跨进程存储锁（`.storage.lock`）始终跟随数据目录，保证 GUI 与 CLI 在重定向数据目录后仍协调同一把锁。
- `clipslots --help` 输出已补充 `CLIPSLOTS_DATA_DIR` 说明（含当前生效值）。
- 说明：仅影响数据目录；用户配置文件 `~/.config/clipslots/config.toml` 不受影响。
