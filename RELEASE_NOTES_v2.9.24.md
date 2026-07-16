# ClipSlots v2.9.24

本次版本聚焦 Toast 通知视觉重做与若干体验修复。

## 修复内容

### 1. Toast / FloatingNotice 视觉重做
- 图标改为按语义类型统一渲染：成功 `checkmark.circle.fill`（绿）、警告 `exclamationmark.triangle.fill`（黄）、错误 `xmark.circle.fill`（红）、信息 `info.circle.fill`（蓝）。
- 移除此前看起来像「三横线 / 汉堡菜单」的 `text.alignleft` 图标。
- 排版层次优化：标题加粗、副标题字号更小且层次清晰；内边距 12–16pt、圆角 12pt，统一背景材质、描边与轻投影。

### 2. 清除调试文本「在代码里是圆盘」
- 全仓检索确认用户可见字符串中不再出现该调试占位文本，槽位卡片预览与 Toast 副标题均为真实内容描述。

### 3. 统一槽位卡片预览行数 lineLimit=28
- `SlotThumbnailView` 文本分支与 `SlotCardView` 内容预览统一为 `lineLimit(28)`，避免部分卡片过早省略；标题/文件名保持单行。

### 4. 「槽位连接」开关关闭时彻底隐藏连接入口
- 设置中「启用槽位连接」关闭时，主界面底部「连接」入口按钮完全隐藏（不占位），受 `enableSlotConnection`（`store.isSlotConnectionEnabled`）门控。
