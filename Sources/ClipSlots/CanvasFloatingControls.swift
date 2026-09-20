import SwiftUI
import ClipSlotsKit

/// 画布上的浮动控件（v2.11.7 · 版本 C2 极简浮动）。
///
/// 三件套：右上「生成」、底部工具栏、左下缩放控件。它们的共同点是**悬浮在画布之上、不随画布缩放
/// 平移**——所以刻意都不进 `nodeLayer`（那一层被统一施加了 `scaleEffect`/`offset`），而是作为
/// 兄弟层贴在 ZStack 外侧。

// MARK: - 浮动面板通用外观

/// 浮层的统一底座。抽出来是为了让三个控件的圆角/描边/阴影**只有一份定义**——之前项目里
/// 类似的浮层散落在多处各写一遍，改一次主题要追五个地方。
private struct FloatingSurface: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.elevatedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppTheme.subtleBorder, lineWidth: 1)
            )
            .shadow(color: AppTheme.cardShadow(isEmpty: false), radius: 10, x: 0, y: 4)
    }
}

private extension View {
    func floatingSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(FloatingSurface(cornerRadius: cornerRadius))
    }
}

// MARK: - 生成按钮

/// 右上角「生成」。
///
/// MVP 阶段它是**占位**：生图链路尚未接入，点击只弹 Toast。刻意不做成 disabled 灰按钮——
/// disabled 按钮既不响应也不解释，用户只会反复点它然后以为 App 卡了；给一句明确反馈更诚实。
struct CanvasGenerateButton: View {
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                Text("生成")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(AppTheme.chromeAccentInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Capsule(style: .continuous)
                .fill(isHovering ? AppTheme.chromeAccentSoftFill : AppTheme.elevatedBackground)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(AppTheme.chromeAccentInk.opacity(isHovering ? 0.55 : 0.28), lineWidth: 1)
        )
        .shadow(color: AppTheme.cardShadow(isEmpty: false), radius: 8, x: 0, y: 3)
        .onHover { hovering in
            withAnimation(Anim.interactive) { isHovering = hovering }
        }
        .help("生成选中的图像 / 视频节点（也可以直接用节点上的「生成」）")
    }
}

// MARK: - 底部工具栏

/// 底部浮动工具栏：选择 / 抓手 / 放入槽位 / 历史记录。
///
/// 「放入槽位」与前两个语义不同——它是**一次性动作**而不是持续模式，所以点它不改 `activeTool`，
/// 直接执行（hotfix20 起是展开左侧槽位库；此前是凭空建一个空节点，见 `CanvasTool.pickSlot`）。
/// 把它混在同一排是因为设计稿如此（也符合 Figma/Excalidraw 的习惯），但行为上必须分开，
/// 否则用户点完会发现自己卡在一个「新建」模式里不知道怎么退出。
///
/// 末尾的历史记录同理是一次性动作（开关一个面板），所以也不进 `CanvasTool` 枚举 ——
/// 那个枚举的语义是"当前处于哪种指针模式"，塞一个面板开关进去会让 `activeTool` 变成一个
/// 既表示模式又表示面板的四不像。
struct CanvasFloatingToolbar: View {
    @ObservedObject var canvas: CanvasStore
    @Binding var isHistoryOpen: Bool
    let onPickSlot: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CanvasTool.allCases) { tool in
                if tool == .pickSlot {
                    separator
                    toolButton(tool, isActive: false) { onPickSlot() }
                } else {
                    toolButton(tool, isActive: canvas.activeTool == tool) {
                        canvas.activeTool = tool
                    }
                }
            }

            separator

            Button { isHistoryOpen.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isHistoryOpen ? AppTheme.chromeAccentInk : AppTheme.canvasChromeSecondaryInk)
                    .frame(width: 28, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isHistoryOpen ? AppTheme.chromeAccentSoftFill : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("操作历史（⌘Z 撤销 / ⇧⌘Z 重做）")
            .popover(isPresented: $isHistoryOpen, arrowEdge: .top) {
                CanvasHistoryPanel(canvas: canvas)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .floatingSurface(cornerRadius: 13)
    }

    private var separator: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, 3)
    }

    private func toolButton(_ tool: CanvasTool, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: tool.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? AppTheme.chromeAccentInk : AppTheme.canvasChromeSecondaryInk)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? AppTheme.chromeAccentSoftFill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tool.hint.map { "\(tool.title)（\(tool.shortcut)）· \($0)" } ?? "\(tool.title)（\(tool.shortcut)）")
    }
}

// MARK: - 历史记录面板

/// 操作历史 + 撤销/重做（v2.11.7 hotfix18）。
///
/// 面板同时列出**已生效**与**已撤销**的条目（后者置灰），点任一条可把画布推到「那一条刚做完」的
/// 状态。这比只给两个 undo/redo 按钮更有用：用户要退回五步前时，看得见目标比数着按五次可靠。
///
/// 刻意不做「删除某一条历史」：撤销栈是一条线性时间轴，抽掉中间一条就得重算它之后所有条目的
/// 前后快照 —— 那是一个必然出错的操作，而收益仅仅是列表短一点。
struct CanvasHistoryPanel: View {
    @ObservedObject var canvas: CanvasStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if canvas.history.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 18, weight: .light))
                        .foregroundColor(AppTheme.canvasChromeTertiaryInk)
                    Text("还没有任何操作")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.canvasChromeSecondaryInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(canvas.history.display, id: \.entry.id) { item in
                            row(item.entry, applied: item.applied, cursorAfter: item.cursorAfter)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: min(CGFloat(canvas.history.count) * 34 + 8, 260))
            }
        }
        .frame(width: 250)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("操作历史")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.canvasChromeInk)
            Spacer(minLength: 0)
            stepButton("arrow.uturn.backward", help: "撤销（⌘Z）", enabled: canvas.canUndo) {
                canvas.undo()
            }
            stepButton("arrow.uturn.forward", help: "重做（⇧⌘Z）", enabled: canvas.canRedo) {
                canvas.redo()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func stepButton(_ symbol: String,
                            help: String,
                            enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(enabled ? AppTheme.chromeAccentInk : AppTheme.canvasChromeTertiaryInk.opacity(0.5))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private func row(_ entry: CanvasHistoryEntry, applied: Bool, cursorAfter: Int) -> some View {
        Button {
            canvas.jump(toCursor: cursorAfter)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: entry.kind.symbolName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(applied ? AppTheme.chromeAccentInk.opacity(0.85) : AppTheme.canvasChromeTertiaryInk.opacity(0.6))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.kind.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(applied ? AppTheme.canvasChromeInk : AppTheme.canvasChromeTertiaryInk.opacity(0.7))
                    if !entry.detail.isEmpty {
                        Text(entry.detail)
                            .font(.system(size: 9))
                            .foregroundColor(applied ? AppTheme.canvasChromeSecondaryInk
                                                     : AppTheme.canvasChromeTertiaryInk.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Text(entry.stamp())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(applied ? AppTheme.canvasChromeTertiaryInk
                                             : AppTheme.canvasChromeTertiaryInk.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(applied ? "点击退回到这一步之后" : "点击重做到这一步")
    }
}

// MARK: - 缩放控件

/// 左下角缩放控件：缩小 / 百分比 / 放大 / 适应窗口。
///
/// 百分比是**只读展示**而不是可编辑输入框：MVP 阶段一个能输入任意数字的框会引出一堆边界
/// （空串、负数、10000%），而它带来的价值不如旁边的「适应窗口」。点百分比等价于重置到 100%。
struct CanvasZoomControl: View {
    let zoom: CGFloat
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void
    let onReset: () -> Void
    let onFit: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            iconButton("minus", help: "缩小", disabled: zoom <= CanvasGeometry.zoomMin + 0.001, action: onZoomOut)

            Button(action: onReset) {
                Text(percentText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    // ★ hotfix19：原来是 `.secondary`（深色下白 ~55%），压在浮层上偏灰到看不清。
                    .foregroundColor(AppTheme.canvasChromeInk)
                    // 固定宽度：否则从 100% 跳到 25% 会让左右两个按钮横向抖动。
                    .frame(width: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("重置为 100%")

            iconButton("plus", help: "放大", disabled: zoom >= CanvasGeometry.zoomMax - 0.001, action: onZoomIn)

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)

            iconButton("arrow.up.left.and.down.right.magnifyingglass", help: "适应窗口", disabled: false, action: onFit)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .floatingSurface(cornerRadius: 11)
    }

    private var percentText: String {
        "\(Int((zoom * 100).rounded()))%"
    }

    private func iconButton(_ symbol: String,
                            help: String,
                            disabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(disabled ? AppTheme.canvasChromeTertiaryInk.opacity(0.45)
                                          : AppTheme.canvasChromeSecondaryInk)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

// MARK: - 拖影

/// 从槽位库拖向画布时跟手的小胶囊。
///
/// 刻意做成**固定尺寸、不随画布缩放**：它表达的是「手上正拿着什么」，属于光标的延伸而非画布内容。
/// 若跟着 zoom 缩放，在 0.25x 下会缩成一个看不清的小点。
struct CanvasDragGhost: View {
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo")
                .font(.system(size: 9))
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(AppTheme.canvasChromeInk)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(AppTheme.elevatedBackground))
        .overlay(Capsule(style: .continuous).stroke(AppTheme.chromeAccentInk.opacity(0.5), lineWidth: 1))
        .shadow(color: AppTheme.cardShadow(isEmpty: false), radius: 6, x: 0, y: 2)
        .allowsHitTesting(false)
    }
}

// MARK: - 空画布引导

/// 画布上一个节点都没有时的引导。
///
/// 不放 `nodeLayer` 里——它不该跟着缩放平移跑掉；空画布下用户还没有任何空间感，
/// 一个会飘走的提示只会加深迷惑。
struct CanvasEmptyHint: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(AppTheme.canvasChromeTertiaryInk.opacity(0.7))
            Text("画布节点就是槽位：从左侧槽位库拖入，或按 Cmd+1~0 放入对应槽位")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.canvasChromeSecondaryInk)
            // ★ v2.11.7 hotfix17: 手势不是自解释的，必须写出来。
            // 中键平移这类约定，用户不被告知就永远发现不了（他会一直用抓手工具，或者以为画布不能动）。
            Text("滚轮上下翻 · 按住中键拖动平移 · Cmd + 滚轮缩放")
                .font(.system(size: 10))
                .foregroundColor(AppTheme.canvasChromeTertiaryInk)
        }
        .allowsHitTesting(false)
    }
}
