# ClipSlots v2.9.40

本版为 CLI 批量写入的 P0 数据安全修复，聚焦 `write --batch` 与 `--page-name`/`--page` 页面约束的失效问题，无新增功能，用户可安全升级。

## 🐞 修复

- **`write --batch` 页面约束失效导致误写他页同名组（P0）**：此前 `write --batch --group-name "X" --page-name "Y"` 时，批量处理器解析组名走的是**全局**路径（`resolveGroup(args)` 未传入已解析页面、逐条 `entry.group` 走全局 `resolveGroupLiteral`），当多个页面存在同名组时，数据会被写到**首个全局匹配**的页面而非用户指定的「Y」页面，且不会触发任何护栏报错。现改为：
  - 在批量入口一次性解析 `--page`/`--page-name`，并把该页面约束传递给顶层默认组与逐条 `group` 的解析；
  - 组解析严格限定在指定页面内查找，指定页面不存在该组时**直接报错**（`group '<name>' not found in page '<label>'`），绝不回落到其他页面的同名组。
  - 与 v2.9.32 已修复的单条 `write`/`read`/`paste` 页面约束行为对齐，批量路径不再是缺口。

## 📝 文档

- **补充 `create-group` 并行约定**：在 CLI Skill 文档中明确 `create-group` 必须**顺序调用**，一次建多个组时不可并行发起，否则组排序按创建先后确定会出现顺序不确定（错乱）。

> 注：DMG 为 ad-hoc 签名，未做 Developer ID 公证，首次打开可能需右键→打开。
