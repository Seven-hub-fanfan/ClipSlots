# ClipSlots v2.9.38

本版为代码健壮性与一致性专项修复，聚焦 v2.9.36/2.9.37 引入的「自动切换 / 上次粘贴 / 附件粘贴」链路，无新增功能，用户可安全升级。

## 🐞 修复

- **附件粘贴失败时误记「上次粘贴」（P1）**：带附件的槽位此前在启动顺序粘贴**之前**就记录了「上次粘贴」位置，一旦目标应用未能激活、粘贴中止，Footer 与卡片角标仍会显示为成功。现在改为仅在顺序粘贴**成功回调**里记录，确保「上次粘贴」始终反映真实结果。
- **`config.slots == 0` 崩溃隐患（P2）**：`lastNonEmptySlot` 在槽位数为 0 时会构造非法区间 `1...0` 导致崩溃，已加 `guard config.slots >= 1` 兜底。
- **跳转「上次粘贴」时的双重刷新闪烁（P2）**：`jumpToLastPaste` 此前先调 `switchToPage` 再调 `switchSpecialSlot`，而后者本就会同步页面，跨页跳转会触发两次重载 + 两段动画。已移除多余的 `switchToPage` 调用，跨页跳转更顺滑。
- **闪烁高亮未校验槽位组（P2）**：`flashHighlightSlot` 此前只按槽位序号匹配，与带组判定的「上次粘贴」角标语义不一致。改为携带 `(groupId, slot)`，只点亮对应组内的对应卡片。

## 🧹 清理

- **移除延迟切组死代码（P1）**：删除永远不会被触发的 `pendingAutoAdvance` 变量、`firePendingAutoAdvanceOnPanelClose` 函数及 `maybeAutoAdvance` 中的延迟分支（两个调用点都在「无附件」分支，延迟逻辑不可达）。真正生效的「附件粘贴完成后再切组」由顺序粘贴成功回调 `completeAutoAdvanceAfterAttachments` 承担，行为不变。
