# ClipSlots v2.10.86

## 修复：切换到一个组时，所有槽位缩略图停在占位图，切走再切回才加载

v2.10.85 起出现的回归。**根因是 UI 失效通知投递被压得太狠，而不是解码失败** —— 本机实测
QuickLook 为 10 张 1MB PNG 出缩略图共耗 0.1s、无一失败，图片其实早就解好放进缓存了，
只是网格没有被重新求值，所以一直画着「占位图标 + 文件名」。

链条是 v2.10.84 两处优化叠加造成的：

- **PERF-2** 把「每张图开始加载 / 解码完成」各一次的通知（一屏 10 图约 20 次）合并成
  一个 16ms 窗口内**恰好一次** `objectWillChange.send()`。
- **PERF-1** 又移除了切组 `onCommit` 里的 `invalidateSpecialSlot(oldId)`——它顺带在
  「新数据提交后的下一个 tick」还会再发一次通知。

于是每次切组只剩唯一一次 send，且它恰好落在切组自身的更新/过渡窗口内；这一次若被 SwiftUI
的更新时序吞掉（本轮已求值过的卡片不再因它重新求值），就再没有任何补救 —— 表现为整组停在
占位图，只能靠切走再切回（缓存命中路径）自愈。

### 改动

1. **通知投递改为 epoch 计数 + 补发校验 send**（`ThumbnailProvider`）
   - 每次状态变化 `changeEpoch += 1`，flush 时追平 `flushedEpoch`：flush 之后才发生的变更
     必被下一次 flush 覆盖，不再依赖布尔量恰好覆盖。
   - 每次 flush 立即 send 之后，再在**下一个 runloop tick** 补发一次。该次必然落在当轮 SwiftUI
     更新之外，保证「解码完成」最终一定被视图看到。一次 burst 2 次全网格重绘（对比 v2.10.83
     的约 20 次），PERF-2 的性能收益基本保留。
2. **切组提交后补一次收尾刷新**（`refreshAfterGroupSwitch`，`loadSlotsAsync` / `reloadAllAsync`
   两个提交点都挂）
   - **不动缓存**，PERF-1 的跨组常驻缓存（A→B→A 秒回）收益完整保留。
   - 只清「进入组」的 `failedKeys` + 触发一次通知。失败态原本是永久的：一次偶发 nil（QuickLook
     抖动 / 10s 看门狗 / 请求被取消）就让该槽位永久停在占位图；v2.10.83 之前靠每次切组的
     invalidate 顺带自愈，PERF-1 之后这条自愈路径也没了，这里以「进入组给一次干净重试」补回。
3. **触发解码加第三道保险**（`SlotThumbnailView`）
   - 卡片身份自 v2.10.73 起是 `.id(slot)`（切组复用卡片、更流畅），因此切组时 `onAppear`
     不再触发，全靠 `onChange(of: currentKey)` 一个钩子。新增 `.task(id: currentKey)` 作为
     独立触发路径；`load()` 对「已缓存 / 正在解码 / 已知失败」直接返回，重复调用零成本。

### 不变量守护（历史最敏感）

「图片槽位切组立即刷新、绝不串图」不受影响：

- 缓存键仍是 `specialSlotId::slot::contentId::updatedAt`，任何保存/覆盖都会同时改变
  contentId 与 updatedAt → 键必变 → 必然 miss 重解码。
- 渲染仍是 `state(for: currentKey)` 的纯函数，本次改动只影响「何时被通知」，不影响「画什么」。
- 清 `failedKeys` 不含任何图片数据，最坏结果只是「重新解码一次」，不可能让槽位显示到别的内容。
- 内容真变的失效点（clearAllSlots / 导入覆盖 / 单槽写入）全部原样保留。

### 验证

- `swift build` 通过；smoke **通过 33、失败 0**。
- QuickLook / ImageIO 实测基准（10 张 1MB PNG）：QL 0.103s 全部成功，ImageIO 0.142s 全部成功
  —— 据此排除「解码失败/超时」假设，定位到通知投递。
- DMG 打包校验通过（`SKIP_NOTARIZE=1`，ad-hoc 签名），装机运行无崩溃，CLI 版本 2.10.86。
- DMG SHA256：`fbe6ea9064cf804577db4487ac02bf95f1858277f5a38e00b7950a621d3ce982`
