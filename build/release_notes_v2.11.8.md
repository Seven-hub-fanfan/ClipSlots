# ClipSlots v2.11.8

macOS 剪贴板槽位管理工具。本版为 v2.11.8 第八轮更新（画布文字与卡叠动效三件套），tag 已 force 更新。

## 本轮（第八轮）新增 / 修改

### 1. 画布文字不再跟着缩放变大变小（screen-space 固定字号）

- 画布缩放时，节点方框、图片、圆角、边框照旧跟着缩放；**文字在屏幕上的视觉大小恒定**（路径行 / 正文 / 「入参文件 N」/ 运行秒数角标全部统一）。
- 实现上**没有**在文字上挂 `scaleEffect(1/zoom)`。本项目的缩放管线是"节点内部按 `layoutZoom` 排版 + 节点层 `scaleEffect(zoom / layoutZoom)` 补连续过程的差值"，再套一层反向缩放会把文字变成被放大的位图（回到之前修过的模糊问题）。新增 `CanvasScreenText.layoutFontSize(_:renderScale:)`：几何走 `s(v) = v * renderScale`，字号走 `fs(v) = 设计 pt`，即排版时字号不乘缩放，文字始终按当前分辨率重新排版渲染，放大后依然是锐利的矢量字。
- **过小时隐藏**：节点视觉短边 < 40pt 隐藏节点文字；卡片阈值单独设为 24pt（卡片本身比节点小很多，用同一个 40pt 会让文字过早消失）。隐藏用 `opacity(0)` 而不是 `if` 不渲染 —— 后者会在跨阈值那一帧触发布局重排，看起来像节点自己抖了一下。
- **副作用兜底**：字号不再随缩放变小，缩小画布时固定字号的正文会把底部「入参文件」行顶出卡片。新增 `CanvasCardLayout.promptMaxHeight(nodeHeight:)`，正文区按"节点高度 − 其余固定分区"限高并 `.clipped()`；节点极矮时正文限高钳到 0 而不是负值。

### 2. 横排轮播（carousel）翻页改为侧滑

- 翻页动画用指定参数 `spring(response: 0.35, dampingFraction: 0.8)`。
- 新增方向状态 `pageForwardLast`：向后翻 = 新卡从右进、旧卡向左出；向前翻反向。
- 关键点是**必须用 transition 而不是靠属性动画**：七轮为了防异步旧图污染，牌面 `.id` 已编入"位置 + 内容身份"，翻页时 SwiftUI 是销毁 / 新建视图而非改属性，单纯 `.animation(value: windowStart)` 不会插值。因此用 `AnyTransition.asymmetric(insertion: .move(edge:) + opacity, removal: ...)` 做侧进侧出。

### 3. 新增第三种展开样式「交替叠放」（Stacked Scatter）

- `CanvasFanGeometry.ExpandStyle` 从两态变三态：扇形展开 / 水平轮播 / **交替叠放**；右上角按钮从二态互切改为三态循环，并新增右键菜单「展开样式」可直接跳选（当前项带 ✓）。样式随节点持久化。
- 几何全部落在 Kit 纯函数 `scatterLayouts(count:cardWidth:hoveredIndex:)`：
  - 横向一排，相邻遮挡 **26%**（步长 = 卡宽 × 0.74），位移关于中轴对称；
  - 倾斜角来自 index 的稳定整数哈希，幅度 **3°~8°**、符号按 index 正负交替 —— 稳定伪随机而非 `random()`，否则每次重绘都换一个角度、卡叠会自己抖；
  - **中间卡 zIndex 最高**，同距的左右卡用 0.5 打破平局（不打破的话 ZStack 会退回声明顺序，"中间在最上"就随机失效）；
  - 投影比扇形柔和（radius 9 / opacity 0.20 / offsetY 4）。
- hover 单卡：目标卡旋转归零 + 放大 1.14 + 上浮 12pt，其余卡左右各让开 10pt。
- `CanvasNodeHover.holdRect` 的维持区从"只按扇形半宽"改成**取扇形与 scatter 半宽的并集** —— scatter 横向铺得比扇形更宽，不扩维持区的话鼠标追着最外侧卡片走就会判定为"离开节点"，整叠瞬间收起。

## 前七轮修复（本 tag 累计内容）

- **参考卡机制整套删除**：牌面一律全亮，不再有 40% 黑遮罩。
- **固定栅格分页**：窗口按 `[0,cap) [cap,2cap) …` 翻页，末页允许不满，翻页零重复下标；渲染层 id 编入附件 UUID + `shownId` 校验，迟到的异步旧图不上屏。
- **顺序与窗口跨重建存活**：附件顺序绑定持久化下标；翻页窗口进 `CanvasFanWindowRegistry`，右键 / 切页往返不打回第一页。
- **`+N` 灰卡**：沉到牌面之下、独占手势（点它只翻页，不选中、不弹「入参文件」导入面板）。
- **hover 维持区 + 200ms 离开延迟**：鼠标去点箭头不再让展开消失。
- **卡片堆叠**：第 1 张最左且视觉最顶层。
- **缩放不再抖**：排版缩放量化到几何阶梯 + 迟滞 + 落定延时。
- **非图像入参也成卡**：`.mp3` / `.md` / `.command` 正常出现，单击用默认程序打开。
- **插件市场官方插件上架 ScrollApp**，下载直链与版本号实时取 GitHub latest release。

## 自测

- `swift build` 通过；`swift build -c release` 通过（本机只有 Command Line Tools，无完整 Xcode，`xcodebuild` 不可用，Release 构建由 SwiftPM release 配置承载，与打包脚本一致）
- smoke：**通过 11538，失败 0**
  - 新增 `CANVAS-TEXT-FIXED`：任意缩放下 `layoutFontSize(13, renderScale:)` 恒为 13；< 40pt 隐藏、边界 40pt 显示；卡片阈值严格小于节点阈值
  - 新增 `CANVAS-PROMPT-CLIP`：正文限高非负；有正文时各分区之和恰好等于节点高度；极矮节点钳到 0
  - 新增 `CANVAS-CAROUSEL-SLIDE`：spring 参数为 0.35 / 0.8；向后翻右进左出、向前翻左进右出
  - 新增 `CANVAS-SCATTER`：张数夹取、角度正负交替且幅度在 3°~8°、同 index 重复调用角度不变、遮挡落在 20%~30%、位移中轴对称、中间 zIndex 最高且无重复、hover 上浮 / 放大 / 转正 / 邻卡散开、hover 维持区覆盖 scatter 宽度、三种样式名称与图标唯一、`.next` 三态闭环、`stackedScatter` 可 Codable 落盘
- 本机装机实测：覆盖安装 `/Applications/ClipSlots.app`，App 版本 2.11.8

## 安装

下载 DMG → 拖入「应用程序」。ad-hoc 签名、未公证，首次打开若被 Gatekeeper 拦，右键「打开」。

DMG SHA256:
```
4d57878089b5d8a06ec9369b7a5b7adf505c827a6c329521a8eea010f3e62215
```
