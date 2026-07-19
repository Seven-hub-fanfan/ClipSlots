# ClipSlots v2.9.42

本版聚焦 CLI 的**槽位组命名体验**，解决「每次 `create-page` 都会多出一个无用的空默认槽位组」的痛点：新增组重命名能力，并让建页时可一步指定第一个组名。含向后兼容改动，可安全升级。

## ✨ 新增

### 1. 新增 `rename-group` 命令

- **用法**：`clipslots rename-group <group-id> --name <新名称> [--page-name <页面名>]`
- **行为**：把指定 group 的 name 改为新名称。
  - 成功返回：`{"ok":true,"group":{"id":"...","name":"..."}}`（`name` 为实际落盘值，按 30 字截断）。
  - 同页重名：`{"ok":false,"error":"a group named '...' already exists on this page"}`。
  - group 不存在：`{"ok":false,"error":"group ... not found"}`。
  - `--page-name` 为可选校验项：提供时会校验其与该组所属页是否一致，不一致返回 `group '...' is not on page '...'`，避免误改错页的组；不影响核心重命名逻辑。
- **主要场景**：`create-page` 之后，把自动生成的默认槽位组重命名为想要的第一个组名，避免浪费。

### 2. `create-page` 新增 `--group-name` 参数

- **用法**：`clipslots create-page <页面名> [--group-name <第一个组的名称>]`
- **行为**：
  - 不传 `--group-name`：行为与旧版完全一致（向后兼容），返回名为「默认槽位组」的 `defaultGroup`。
  - 传了 `--group-name`：建页后立即把默认槽位组 rename 成指定名称，返回结构不变，`defaultGroup.name` 即用户传入的名称。

## 🔧 底层改动

- `SpecialSlotStorage.renameSpecialSlot` 补齐**同页重名校验**：重命名到同页已存在的其它组名时抛 `SpecialSlotError.duplicateName`（改成自身原名的 no-op 仍允许），与 `createSpecialSlot` 的去重规则对齐，保证组名在页面内唯一。

## 🔧 兼容性

- `create-page` 不带 `--group-name` 时行为与旧版完全一致，返回值结构不变。
- GUI 侧 `renameSpecialSlot` 调用均包裹在 do/catch 中（出错仅记日志、不改名），新增的重名校验不破坏 GUI 行为。

> 注：DMG 为 ad-hoc 签名，未做 Developer ID 公证，首次打开可能需右键→打开。
