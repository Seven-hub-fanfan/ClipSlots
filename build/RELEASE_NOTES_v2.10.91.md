## ClipSlots v2.10.91

这一版找到了「无论怎么优化都不丝滑」的真正原因，并修掉了它。

### 根因：App 空闲时每 0.65 秒做一次全量重载，永不停止

前几版一直在调动画时长、改渲染方式，都没解决问题。这次先在 App 里加了主线程卡顿检测 + 程序化驱动交互来取数（`PerfMonitor.swift` / `PerfAutoTest.swift`，默认关闭，需 `CLIPSLOTS_PERF_LOG=1` 开启），一测就定位到了：

**完全空闲、无人操作时，40 秒内触发 63 次 `watcher fired → reloadAll`（约每 0.65s 一次），每次伴随 140~180ms 的主线程停顿。**

成因是一个自触发死循环：
1. 读数据也要拿跨进程存储锁；
2. `StorageLock.writeHolderPID` 每次成功 `flock` 后都会写锁文件 `.storage.lock`；
3. 该锁文件位于 `special_slots/` 内，而 GUI 用 FSEvents 递归监听整棵子树；
4. 于是「读盘 → 写锁文件 → FSEvents → 去抖 → reloadAll → 又读盘」无限循环。

这解释了为什么此前三轮动画/渲染微优化全部无效：不管把动画调得多短，背后永远有个每 0.65 秒一次的 150ms 主线程停顿在和所有交互抢资源。

**修法**：`writeHolderPID` 在「锁文件内容已经就是本进程 PID」时跳过写入。语义完全不变——跳过的前提正是「要写的内容与磁盘上已有的完全相同」；别的进程抢锁并写入自己的 PID 后内容不匹配，下次获取锁仍会正常写回，stale-lock 回收逻辑不受影响。实现用 `pread` 从偏移 0 读取，不动共享 fd 的文件偏移。

**实测：空闲 40 秒的全量重载次数 63 → 0。**

### AppKit 弹窗没有浅色界面

删除槽位组等确认弹窗在 App 选「浅色」时仍是深色。根因是主题此前**只**通过 SwiftUI 的 `.preferredColorScheme` 应用，作用域仅限 SwiftUI 视图层级；而 `NSAlert` / `NSMenu` / `NSOpenPanel` 这些由 AppKit 拥有的界面跟随 `NSApp.appearance`，而该值从未被设置过（一直是 nil = 跟随系统）。所以「App 浅色 + 系统深色」时这些弹窗全是深色。

修为在启动时及主题变化时同步 `NSApp.appearance`（`ThemeMode.nsAppearance` + `AppDelegate.applyAppAppearance`），一处生效覆盖全部 AppKit 界面，不必逐个 NSAlert 设置。`.system` 时置 nil，「跟随系统」语义不变。

### 其它

同批还包含若干读路径与设置界面的开销削减。缩略图「切组/切页立即刷新、不串图」不变量相关文件（`ThumbnailProvider.swift` / `SlotThumbnailView.swift`）本版**零改动**。

### 一处方法论修正（记录备查）

排查中曾误判「CLI 外部写入不再刷新 GUI」为本版引入的回归。实际用 v2.10.90 基线做对照后确认：基线同样为 0，属**既有行为，非本版回归**。教训是——把某个观测值当作回归之前，必须先在基线版本上建立「正常值应该是多少」。

验证：`swift build` 通过；smoke 测试 33 项全绿；DMG 打包校验通过；装机运行正常；空闲重载 63→0；测试用的空槽数据已还原。

### DMG SHA-256

见下方 asset digest。
