# ClipSlots v2.9.31 发布说明

## 新增「自动前进」功能开关

- 新增 **自动前进**（`autoAdvanceAfterPaste`）：粘贴完当前组最后一个非空槽位后，自动切换到下一组。
- **本页用完自动跳下一页**：当前页所有组用完后，自动跳转到下一页继续。
- **全部用完停止，不循环**：所有页面、组都用完后停止，不会回到开头循环。
- 开关位于**槽位主界面右上角工具栏**，状态**持久化**保存。

## 涉及文件

- `Sources/ClipSlots/UserPreferenceKeys.swift`
- `Sources/ClipSlots/ContentView.swift`
- `Sources/ClipSlots/main.swift`
