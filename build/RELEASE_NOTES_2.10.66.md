## ClipSlots v2.10.66

一次全量 bug 扫描后的修复批次。

### 🔴 关键修复
- **数据不变量**：`clearAllSlots` 补齐与 `set/clear/setLabel` 一致的 STG-2 护栏——组已从索引删除时拒绝清空，杜绝 GUI/CLI 并发删组后清空或覆盖导入把已删组目录"复活"成孤儿目录。
- **回归修复（v2.10.65 引入）**：底部「上次粘贴」跳转不再滚动定位的问题——`.id()` 与 `scrollTo()` 统一到同一单元格身份来源。
- **并发崩溃**：多文件拖入时 `handleFileDrop` 对共享数组的无锁并发 append 改为串行队列收集，消除偶发丢文件/崩溃的数据竞争。

### 🟡 其它
- CLI 版本号与 App 版本对齐（此前滞后到 2.10.58）。
- 批量写入 stop-on-error 后的 `not_executed` 结果补齐 `group` 字段，与其它结果结构一致。
- 导入进度条收口，成功后明确推到 100%（此前因分母含被跳过/损坏槽位而停在 <100%）。

验证：`swift build` 通过；23 项 smoke 测试全绿。

SHA256（ClipSlots_v2.10.66.dmg）：`17cc983311e131ccd23bdd5a7ebb843a9c2dca4354c1fbc7d39836a360dcfcb8`
