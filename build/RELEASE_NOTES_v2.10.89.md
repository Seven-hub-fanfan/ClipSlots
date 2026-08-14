## ClipSlots v2.10.89

修掉「hover 在某个槽位上、再移到另一个槽位时卡一下」的**第二条根因**：主线程同步 I/O。

v2.10.88 已经处理了 hover 路径上两处**渲染**开销（阴影模糊半径逐帧重算、`scaleEffect` 作用于未拍平子树）。但卡顿还有一条与渲染完全无关的来源。

### 根因：附件按钮每次 body 求值做约 9 次主线程存储读

每张槽位卡片里都内嵌一个 `NodeAttachmentButton`（「附件」胶囊）。它的附件数原先是这样拿的：

```swift
private var attachmentCount: Int { store.attachments(for: slot).count }
```

而 `store.attachments(for:)` → `specialStorage.get(slot, in:)` → `SlotStorage.loadContentOrUnknown` 是一次**存储读**。即便命中不加 flock 的快路径，也仍要付 `dirFingerprint()` 的 `stat(2)` 系统调用 + 一次 `queue.sync` 串行队列跳转——后者若正被后台读盘占用，主线程会被直接阻塞。

问题在于它是 computed property，而 body 与 `pill` 里对它的引用有 **9 处**（pill 的 icon、label×2、foregroundColor、background、overlay，body 的 help×2 与 `if attachmentCount > 0`）。也就是**一次 body 求值 = 9 次存储读**。再乘以 10 张卡片 ≈ **90 次主线程 stat + queue.sync**。

更糟的是这个按钮以 `@ObservedObject` 观察巨型主 store，**绕过了卡片 `.equatable()` 的短路**——v2.10.76 让 SwiftUI 跳过未变卡片 body 的优化对它无效。

- 对 hover 的影响：hover 改的是卡片自身的 `@State`（Equatable 拦不住），离开的卡 + 进入的卡各重算一次 body → 约 18 次同步 I/O 正好压在缩放动画的头几帧上。
- **影响面远大于 hover**：每次保存 / 清空 / 弹 Toast / 切组，只要主 store 发一次 `objectWillChange`，就会触发这约 90 次主线程存储读。

### 修法

两层，热路径彻底归零：

1. 新增 `attachmentCountOverride` 参数。主网格的 `SlotCardView` 本来就持有权威的 `content`，直接把 `content.attachments.count` 传进来 → **零存储读**。
2. 未传入时仍回退存储读（节点画布路径），但 body 内**只求值一次**，9 次降为 1 次。

响应性不变：改附件会刷新 `contentId`/`updatedAt`（v2.10.53 起的不变量），从而改变 `thumbnailKey` → 卡片 Equatable 判不等 → 重算 body 并传入新 count。附带的一致性改善是，附件胶囊现在与卡片其余部分（缩略图、元数据）读同一份 `content`，不会再出现两者短暂不一致。

### 顺带

- 修掉 v2.10.87 我自己引入的一处小回归：`SlotThumbnailView` 里 `isThumbnailLoaded` 会**再**调一次 `provider.state(for: currentKey)`，而 `currentKey` 是带 4 段插值的字符串拼接。现改为 body 顶部只取一次 state，同时驱动渲染分支与淡入动画，语义不变。

缩略图「不串图」不变量的方向性动画逻辑（驱动键为 `isLoaded` 而非 `currentKey`）完好未动。

验证：`swift build` 通过；smoke 测试 33 项全绿；DMG 打包校验通过；装机运行正常、无崩溃；附件计数在 CLI `write-attachment`/`read`/`list` 三处一致。

### DMG SHA-256

```
466bb47c9fb74af5698db118f0d2c24a26f30437af08b725a8cfc70a03745a68
```
