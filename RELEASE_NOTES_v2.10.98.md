# ClipSlots v2.10.98

修复 v2.10.97 新增的「撤销步数」设置项**看不到当前值**的显示问题。

## 问题

设置 → 高级 → 操作历史里的「撤销步数」只显示了 ∧ / ∨ 两个箭头，当前步数完全不可见，用户无法判断现在是几步。

## 根因

数值胶囊被写成了 `Stepper` 的 **label**，同时又叠加了 `.labelsHidden()` —— 该修饰符正是用来隐藏 label 的，于是唯一显示当前步数的控件被自己隐藏掉，只剩下 Stepper 自带的箭头。

## 修复

数值移到 `Stepper` **外部**，并做双重冗余显示：

- 标题直接显示为「**撤销步数：10**」；
- 右侧保留一枚独立的**数值胶囊**（`monospacedDigit()`，与「槽位数量」的数值样式一致），紧贴 ∧ / ∨ 箭头左侧；
- `Stepper` 的 label 改为 `EmptyView()`，只负责提供箭头；
- 补充 `accessibilityLabel` / `accessibilityValue`，VoiceOver 可正确读出当前步数。

仅涉及 `Sources/ClipSlots/SettingsView.swift` 的展示层，撤销步数的存储、截断与生效逻辑（v2.10.97）未改动。

## 验证

- `swift build` 无 error 通过。
- 零依赖 smoke 测试 **117/117 通过**。
- DMG 装机验证：App 与 CLI 版本号均为 `2.10.98`，设置面板正确显示当前步数。
