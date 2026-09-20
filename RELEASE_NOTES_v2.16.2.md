# ClipSlots v2.16.2

本版继续留在 `2.16.x` 画布线，只做 bug 扫描后的安全修复和 TapNow 对比小迭代。

## 修复

- **删除当前画布项目前先同步落盘**：之前当前项目若刚经历拖动 / 缩放 / 连线，最后一次状态可能还停在 400ms 防抖保存窗口里；删除项目时直接取消防抖会让 `.trash` 里的备份少掉最后一步。现在删除当前项目会先 `flushSave()`，再把项目文档移入 `canvas/.trash`。
- **放大状态下拖动更精细**：节点拖动仍然不吸附网格，但落盘去浮点噪声的量化从固定 `0.5 canvas pt` 改成约 `0.5 screen pt`。高倍率下不再出现 4px 级跳格，更接近 TapNow 的像素级微调手感。

## TapNow 对比优化

- **ADD NODE 浮层改为黑玻璃底**：菜单从接近实心深灰底调整为 `ultraThinMaterial + 深色 tint`，保留可读性的同时增加一点 TapNow 风格的毛玻璃层次。

## 验证

- `swift run ClipSlotsKitSmokeTests` 通过。
- `swift build` 通过。
- DMG SHA-256：`36d33f7f1215b829bb1b96d419d6827128388e24152b06ec343bd98ea41c2794`。
