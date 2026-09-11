# ClipSlots v2.11.3 发布说明

本版把两条并行开发的线合到一起发布：**圆盘菜单（RadialMenu）视觉与交互增强**，以及**槽位缩略图的 CLI 入口**。

> 版本号说明：v2.11.2 的 CLI 缩略图改动未单独发版，其内容已全部并入本版。

## ✨ 圆盘菜单增强

### 1. 扇区附件角标
- 槽位挂了附件时，扇区编号旁出现一枚回形针角标，悬停显示「该槽位有 N 个附件」。
- 角标沿用与主界面卡片「附件 N」胶囊一致的品牌蓝紫色，圆盘其余配色不变。
- 判定只读内存中的 `attachments` 字段（O(1)），不触发任何磁盘 I/O，划过圆盘不会掉帧。

### 2. 扇区「上次粘贴」标识
- 上次粘贴过的槽位，扇区**外沿**描一段高亮弧，颜色与该槽位在主界面的角标同色。
- 只描外弧、不描径向边：避免与相邻扇区分隔线重合而看起来像「选中了两个扇区」。
- 不做成编号行里的第二枚角标是几何所限：10 槽位下编号行所在半径弦宽仅 ~57pt，而「编号 + 串联色点 + 两枚角标」需要 70pt，必然越界。该结论已固化为 smoke 断言。

### 3. 底栏「上次粘贴」定位按钮
- 底部工具栏在组名与「全部粘贴」之间新增 `checkmark.circle.fill` 按钮，与卡片上的绿色「上次粘贴」胶囊同符号。
- 点击后**全程留在圆盘内**：静默切到目标页 + 目标组 → 对应扇区高亮 → 预览窗同步。圆盘不关闭、主窗口不抢焦点。
- 鼠标重新划入圆盘或点击任意扇区即释放程序化聚焦，回归正常 hover。
- 尚未粘贴过任何槽位时按钮置灰。

### 4. 悬浮预览窗支持附件预览
- 悬停带附件的扇区时，预览窗底部出现附件条：图片附件出**真实缩略图**（最多 3 张，超出折成「+N」），非图片出「语义图标 + 文件名」小卡（按 UTType 区分视频 / 音频 / PDF / 压缩包 / 代码 / 文本）。
- 主视觉优先级：手动封面图 → 槽位主体内容 → 图片附件缩略图 → 文本 → 空。
- 缩略图全程后台线程 + ImageIO 增量下采样，复用全局解码限流器；加载中 spinner，失败退语义图标。

### 5. 预览面板改为磨砂玻璃（本版新增）
- 面板底色由 `Color(NSColor.textBackgroundColor)`（亮色模式下就是**纯白且完全不透明**）换成系统 material：面板本体 `.ultraThinMaterial`、内容卡片 `.regularMaterial`，均压至 0.88 不透明度，下层圆盘扇区能模糊透上来。
- 全部改用系统动态材质与 `.primary` / `.secondary` 语义色，**不再有任何硬编码白色**，亮 / 暗模式自动适配。
- 预览窗内的紫色底与紫色描边全部移除（附件条标题、「+N」块、文件小卡改为中性 material + 极淡中性描边）。扇区上那枚 paperclip 角标仍保留品牌色 —— 那是圆盘本体的视觉锚点。
- 0.88 只压在**背景层**上而非整卡：整卡压会连带把文字降到 88%，半透明底上再叠淡文字会明显掉可读性。
- 空态零渲染：没悬停任何槽位、或悬停到空槽时，整扇预览窗**一个像素都不画**（工具栏与磨砂底都走 `if` 条件渲染，不是 `.opacity(0)` / `.hidden()` 留占位），圆盘右侧不再挂着一块多余的磨砂色块；同时关掉该状态下的命中测试，避免透明窗拦截点击。

## 🖥 CLI：槽位缩略图

新增 3 项能力（与 GUI「右键 → 设置缩略图」写同一份数据，编解码共用 `ClipSlotsKit.ManualThumbnailCodec`）：

- `set-thumbnail <slot> --image <path>` —— 为槽位配封面，图片统一压成最长边 1024px 的 JPEG。注意与 `write-attachment` 的区别：前者只配封面、不改槽位内容。
- `clear-thumbnail <slot>` —— 移除手动缩略图，回落到自动预览；内容、附件、标签均不受影响。
- `set-thumbnail --batch` —— 从 stdin 读 JSON 数组批量设置，两阶段契约与 `write --batch` 逐条对齐；配 `--if-absent` 幂等护栏、`--stop-on-error` 控制批量行为。

`list` / `read` 每槽新增 `hasManualThumbnail`(bool) 与 `thumbnailBytes`(int) 两个字段，便于设置后自检。CLI 命令总数 16 → 18。

## 🔧 工程

- 新增 `RadialAttachmentPreviewPlan`（Kit 纯函数）：决定「谁上缩略图 / 谁折成 +N / 谁走小卡」，配 smoke 断言锁住「附件一个不漏、顺序稳定、计数如实」。
- 新增扇区外弧几何 `RadialSegmentLayoutCalculator.lastPasteArc` 与编号行宽度约束 `numberRowFits`，逐扇区断言不越出楔形。
- 新增 THUMB-CODEC 端到端用例组，覆盖缩略图落盘回读、悬空 id 自愈、批量两阶段契约。
- 版本号 lockstep 断言：`CLI_VERSION` 必须与 App `CFBundleShortVersionString` 一致（历史上漂移过多次）。
- smoke 测试 688 → **765，全部通过**；`swift build` 无新增警告。

## 📦 安装

DMG 为 ad-hoc 签名（未走 Developer ID 公证）。若浏览器下载后被 Gatekeeper 拦截，右键「打开」或执行：

```bash
xattr -dr com.apple.quarantine /Applications/ClipSlots.app
```

SHA-256（自动更新会校验此值）：

```
29d998ff5c2ddbbbedfc73c12a4300947dd3d74472812e91cfe3c8cbc0dab5d6  ClipSlots_v2.11.3.dmg
```
