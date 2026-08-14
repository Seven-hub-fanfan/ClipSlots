## ClipSlots v2.10.92

这一版做两件事：给自动更新链路补上「同版本绝不重装」的硬闸门与完整日志；给存储监听补上「FSEvents 静默失效」的自检与兜底。

### 一、自动更新：同版本重装的硬闸门 + 可自证的日志

起因是一次「反复重装同一个版本」的排查。**结论是那次重装并非 App 自动更新造成**（本 App 只有设置里的手动「检查更新」入口，没有定时/启动自检），而是开发期反复打包装机导致。但排查过程暴露了两个真实的薄弱点：

1. **整条更新链路一条日志都没有**——出问题时无法自证「我到底有没有下载/安装」，只能靠文件 mtime 反推。
2. **从版本比对到真正替换 bundle 之间，没有任何幂等兜底**——只要有人把一个与当前运行版本相同的目标喂进安装入口（错误的比对、被篡改的 tag、重复触发的回调），就会挂载 → 替换 → 重启，重启后再来一遍。

本版修法：

- 版本语义逻辑下沉到 `ClipSlotsKit/UpdateVersion.swift`（零依赖纯函数）。此前它写在 App target 的 `@MainActor` 类里，而测试 target 只能依赖 Kit，导致**这条最容易写错的逻辑恰恰无法被测试覆盖**。现在 `UpdateChecker` / `UpdateInstaller` 共用同一实现，规范化口径不会再漂移。
- 规范化：剥 `v`/`V` 前缀、去空白、丢 `+build`、单独解析 `-pre`；比较**逐段按整数**（绝不字符串字典序），位数不同补 0；**相等或更旧一律不更新**。
- 三道安装闸门（`UpdateVersion.installGuard`，纯判定可测）：总闸关闭 / 目标版本 == 当前运行版本 / 同一目标已尝试过。
- **失败即可重试**：去重记录是在动 bundle 之前写的，因此每条安装失败路径都会清除它（`UpdateInstallGuardStore.clearAttempt`）。否则一次偶发失败（挂载失败 / 版本校验中止 / 授权取消 / 磁盘不足）就会把该版本**永久拉黑**，等于把「重装循环」修成「更新彻底堵死」——比原问题更糟。
- 止血总闸，无需等新版本即可立刻停掉自动安装：
  ```
  defaults write com.clipslots.app disableAutoUpdateInstall -bool true   # 关闭
  defaults write com.clipslots.app disableAutoUpdateInstall -bool false  # 恢复
  ```
- 全链路 `[ClipSlots][Update]` 日志：线上 tag、本地版本、两者规范化结果、比对结论、是否有 DMG/SHA256、下载与安装的每次决策与拦截原因。

v2.10.67 的 SHA-256 完整性校验、v2.10.13 的 beta 通道语义（核心相同时正式版 > 预发布版）均保持不变。

### 二、存储监听：FSEvents 聋掉时的自检与兜底

排查性能问题期间抓到过两种真实状态：进程存活但 FSEvents 回调十几分钟一次都不投递；以及回调进得来但那个实例的主队列不转。两者都会让「外部进程（CLI）写盘 → GUI 刷新」这条契约静默失效，而 watcher 此前**没有任何自检**——系统不投事件，App 永远不知道自己已经聋了。

本版补三条兜底：

1. **哨兵轮询**：每 2s 在后台队列做 2 次 `lstat`（存储根目录 + `index.json`），取 (inode, size, mtime) 混成一个 64 位哨兵。所有数据变更都以原子重写 `index.json` 收尾，因此哨兵对任何外部写必然敏感；纯读不改这两者，空闲时哨兵恒定、轮询零动作。
2. **自写抑制**：自写完成时同时登记整树指纹与哨兵，轮询命中即只更新基线不重载；再叠加原有时间窗判定，GUI 自己的写不会被回灌。并做了「本次变化是否已被上一次重载覆盖」的判断，保证一次外部写恰好换来一次重载，不多不少。
3. **流自愈**：哨兵变了、而 FSEvents 通道最近 5s 内一次上报都没有 → 判定流已失效，重建流并照常重载。

同时给 watcher 加了内部记账路径过滤：一批事件全是隐藏分量路径（`.storage.lock` / `.tmp_slot_*` / `.trash/**` / `.undo/**` / `.dat.nosync*`）才丢弃，只要含任意非隐藏路径就照旧上报。这些子树从不显示在界面上。稳态成本是每 2s 两次 `lstat`（微秒级、带 500ms leeway、不写盘、不产生 FSEvents），相比一次 140~180ms 的全量重载可以忽略。

### 三、辅助功能引导弹窗会让整个 App 的异步刷新停摆（本版最重要的修复）

装机验证 v2.10.92 时用 `sample ClipSlots` 抓到主线程栈，停在：

```
AccessibilityPermissionGuide.presentGuideAlert(afterUpdate:)
  → -[NSApplication runModalForWindow:] → _doModalLoop:
```

`runModal` 跑的是 `NSModalPanelRunLoopMode` 嵌套 run loop，而 `DispatchQueue.main.async` / `asyncAfter` 的块只在 common modes 下被 drain。**结果是这个面板开着的整段时间里，App 所有异步主线程工作全部堆积不执行**：watcher 的 0.3s 去抖 reload 一次都跑不了，CLI 写盘后 GUI 不刷新，上面刚加的哨兵轮询也白跑（它同样要回主线程去抖）。

这个面板尤其危险，因为它**在启动时未经用户触发就弹出**（每次 App 更新后 macOS 都会撤销旧二进制的辅助功能授权），用户完全可能让它挂在那儿几小时；而从外部看只是「GUI 不刷新」，几乎无法归因。此前排查性能问题时观察到的「FSEvents 回调进得来但主队列不转」「FSEvents 十几分钟不投递」，根因都在这里。

修法：引导面板改为**非模态**展示（`makeKeyAndOrderFront` + `.modalPanel` 层级 + 静态属性持有面板，按钮回调里关闭并置 nil）。视觉与交互完全不变，回车仍触发「打开设置」（borderless + nonactivating 面板去掉 runModal 后默认无法成为 key window，故子类化面板显式允许成为 key）。主线程 run loop 从此保持常规模式，异步刷新链路照常工作。

其余 `runModal` 调用点（删除确认、文件选择、更新提示等）均为用户主动触发且瞬时存在，块只会被推迟到弹窗关闭、不会丢失，本版不改。

### 验证

`swift build` 通过；smoke 测试 **59 项全绿**（较上版 +26，新增的全部围绕版本比对与安装护栏：`v` 前缀、字典序陷阱、位数不同、相等误判、beta 通道、四种护栏结论、失败后可重试、止血总闸优先级）；DMG 打包校验通过；装机运行正常。

真机验证「外部写 → GUI 刷新」契约：辅助功能引导面板**开着**的状态下，用 CLI 写入一个空槽位，App 侧正常打出去抖重载日志（修复前此路径完全静默）；空闲 30 秒重载次数 0。测试写入的槽位已还原为空。

缩略图「切组/切页立即刷新、不串图」不变量相关文件（`ThumbnailProvider.swift` / `SlotThumbnailView.swift`）本版**零改动**。

### DMG SHA-256

见下方 asset digest。
