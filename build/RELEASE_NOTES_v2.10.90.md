## ClipSlots v2.10.90

针对反馈的三个体感问题，各自定位到具体成因后修复。

### 1. hover 光效「慢慢的、感觉很卡」——移除 v2.10.88 的 `.compositingGroup()`（负优化）

v2.10.88 在 `scaleEffect` 前加了 `.compositingGroup()`，想法是「缩放前先把卡片拍平成一层，让 0.12s 的缩放退化成对单个位图做 GPU 变换」。这个推理只在**被拍平的内容在动画期间保持不变**时成立，而这里两个前提都不满足：

1. **描边就在这个组里，而且和缩放由同一个 `isHovering`、在同一个 0.12s 窗口里一起变**（`cardOutlineColor` 淡入 accent、`cardOutlineWidth` 1 → 1.5）。内容每帧都在变 → 拍平出来的位图每帧都失效、必须重新生成。缓存收益为零，却凭空多出一次**离屏合成 pass**。
2. **卡片子树里含 AppKit 视图**：附件胶囊的 `AttachmentButtonAnchorReporter` 是 `NSViewRepresentable`（持续上报锚点矩形），视频槽位还有 `SafeInlineAVPlayerView`。`compositingGroup` 要维持这一层位图，就得每帧对这些 NSView 做快照再合成，这是 CPU/GPU 同步开销，比它想省掉的重采样更贵。

净效果是负优化。移除后回到 SwiftUI 默认路径：描边是廉价矢量重绘，缩放是普通图层变换，两者互不放大。

顺带修掉一处高频分配：`AppTheme.slotAccent` 每次调用都构造**两个** 5 元素 `Color` 数组（不论 scheme 如何都建），而 `SlotCardView` 里它被引用 10 处 → 一次卡片 body 求值约 100 次 Color 分配，10 张卡片约 1000 次，而 hover 恰好会让整张卡片 body 重算。调色板提为 `static let`。`slotActionAccent` 同样处理。

### 2. 槽位编辑「每个字都像有延迟输入」——编辑器状态从卡片上摘下来

`TextEditor` 原先绑的是 `SlotCardView` 自己的 `@State editingText`，于是**每敲一个字符都会让整张卡片的 body 重新求值**——而它是全仓最重的 body 之一：headerRow、缩略图区（`SlotThumbnailView`，内含四段字符串拼接的 `currentKey` + provider 查表）、元数据行、actionRow、6 层 overlay、阴影、`scaleEffect`，以及两个 `.sheet` 闭包本身。卡片虽被 Sheet 遮住却仍在视图树里，照样全部重算。所以延迟量是随**卡片复杂度**而不是随文本长度增长的。

新增独立的 `SlotTextEditorSheet` 承载编辑器，`TextEditor` 绑它自己的 `@State draft`，逐字输入只重算这一个轻量 Sheet。

语义完全保持：初值仍由卡片在点「编辑」时快照传入，「保存」回调传出草稿、「取消」不回调，⌘↩ 快捷键、等宽字体、圆角描边、纯文本 / HTML 两种尺寸（520×320 / 620×360）原样保留。初值在 `init` 里灌进 `@State`（不用 `onAppear`，避免重复触发时覆盖用户已输入内容），另有 `onChange(of: initialText)` 作为「视图身份被复用」时的纠偏兜底，防止重开编辑器看到上一次的旧草稿。

另外把 `isHTMLContent` 记忆化（NSCache，键为 `contentId::updatedAt`，沿用 `preview` / `plainText` 同款做法）：它原本每次求值都要对全文做一次完整拷贝 + 大小写折叠，而 `canEditContent` 调它一次、`isPlainEditableText` 内部又调一次、`editActionTitle` 再走一遍 → 一次 body 最多 4 次全文 `lowercased()`。这同时降低 hover 的 body 成本。

### 3. 设置界面打开 / 关闭「很慢、卡一下」

- **打开**：`onAppear` 里 `cliManager.refreshState()` + `skillManager.refresh()` 是**主线程同步文件系统扫描**（遍历 Agent 目录 `fileExists`，再对每个命中项解析符号链接），却正好跑在进场动画的第一帧上。改为让出一个 runloop 再扫，动画先跑起来。安装状态是显示用信息，晚一帧无语义影响。
- **关闭**：原先 `store.updateConfig(newConfig)` 紧接 `closeSettings()`，落在同一帧。而 `updateConfig` 是重活：注销并重注册全部全局热键 + 触发主 store `objectWillChange` → 整棵 ContentView（含 10 张卡片的 LazyVGrid）全量重绘，正好压在 0.2s 淡出动画的头几帧上抢主线程。改为先启动关闭动画，配置在下一个 runloop 落地（差异约一帧，最终状态不变）。
- **阴影**：设置面板 `.shadow` 半径 30 → 18。这层阴影挂在最大 880×660 的面板上，而进出场走 `.transition(.opacity)`，每帧都要重新合成这片大面积模糊；18 仍保留清晰的悬浮层次，卷积面积降到约 36%。

### 未改动

缩略图「切组/切页立即刷新、不串图」不变量相关代码一行未动（方向性动画驱动键仍是 `isLoaded` 而非 `currentKey`）。游标胶囊位置、拖拽排序均未触碰。

验证：`swift build` 通过；smoke 测试 33 项全绿；DMG 打包校验通过；装机运行正常、无崩溃。

### DMG SHA-256

```
d11ceca74630f12c371f8c6007f7696c3d0d9d434f9ea28549fd2201a400465e
```
