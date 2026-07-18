# ClipSlots v2.9.41

本版聚焦并行操作下的**数据一致性**修复，解决两个同源问题：并行 `create-group` 后组排序错乱，以及并行操作累积的内部引用不一致导致删页面时误触发 repair。无新增功能，用户可安全升级。

## 🐞 修复

### 1. 并行 `create-group` 后组排序错乱（Problem A）

- **根因**：组的排序序号 `order` 在「写入完成时」分配（`maxOrder + 1`）。并行发起的多个 `create-group` 是各自独立的进程，它们在跨进程存储锁上的抢锁先后是不确定的，因此最终 `order` 反映的是「谁先抢到锁」而非「谁先被发起」，导致顺序错乱。
- **修复**：
  - `SpecialSlot` 数据模型新增持久化字段 `requestedAt`（请求接收时刻）。
  - CLI 在**进程创建时**即读取内核进程创建时间（`kp_proc.p_starttime`，通过 sysctl）作为请求接收时刻——shell 顺序 fork 后台任务，该时间戳与发起顺序单调一致，且不受 Swift/dyld 运行时启动抖动影响（纯 `Date()` 会因启动抖动大于 fork 间隔而乱序）。
  - `createSpecialSlot` 持锁后按 `requestedAt` 把新组**插入到正确位置**（排在所有比它更晚发起的兄弟组之前），只后移受影响的序号，不打乱既有组。
  - `groups` 命令输出改为按（页面序、组序）排序，与 `list --page` 对齐。
- **效果**：即使 8 个 `create-group` 完全并行发起，最终顺序也稳定等于发起顺序（多次实测一致）。

### 2. 删页面误触发 repair / 并行累积内部引用不一致（Problem B）

- **根因**：
  - `repairPageScopedSlotGroupsIfNeeded` 在每次存储初始化（即每次 CLI 调用）时运行，却是在**锁外**做「读取—判断—写回」。当并行的 `create-group`/`write` 正持锁修改索引时，锁外 repair 会覆盖并发写入（lost update），反而**制造**了它本应修复的不一致（悬空的 `currentSpecialSlotId`、丢失的组），使下一条命令（如 delete-page）触发 repair 事件。
  - `deletePage` 删除页面及其组后，未同步修正 `currentSpecialSlotId` / `selectedSpecialSlotId` / `activeHotkeySpecialSlotId`，留下悬空指针，成为后续 repair 的诱因。
- **修复**：
  - repair 改为在**跨进程锁内**运行，并在锁内重新加载索引，使「读取—判断—写回」原子化，消除自我制造不一致的根源；锁繁忙时本次跳过（后续命令会修复）。
  - `deletePage` 在同一事务内把选择指针重新指向存活当前页的有效组，保证落盘状态自洽，不再遗留悬空引用。
  - repair 新增 `order` 回填：旧数据缺失 `order` 时按当前列表顺序补齐 0..n，为并行插入提供干净、无重复的基准。
- **效果**：并行建组 + 删除当前页的压力场景下，全流程 repair 触发次数为 0。

## 🔧 兼容性

- 旧数据（无 `order` / `requestedAt` 字段）正常加载：解码缺省容错，首次运行由 repair 按现有列表顺序补齐 `order`，显示顺序不变。

> 注：DMG 为 ad-hoc 签名，未做 Developer ID 公证，首次打开可能需右键→打开。
