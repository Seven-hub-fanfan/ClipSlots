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
        .help("生成（开发中）")
    }
}

// MARK: - 底部工具栏

/// 底部浮动工具栏：选择 / 抓手 / 框选 / 新建节点。
///
/// 「新建节点」与前三个语义不同——它是**一次性动作**而不是持续模式，所以点它不改 `activeTool`，
/// 直接建一个节点。把它混在同一排是因为设计稿如此（也符合 Figma/Excalidraw 的习惯），但行为上
/// 必须分开，否则用户点完会发现自己卡在一个「新建」模式里不知道怎么退出。
struct CanvasFloatingToolbar: View {
    @ObservedObject var canvas: CanvasStore
    let onCreateNode: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CanvasTool.allCases) { tool in
                if tool == .newNode {
                    Divider()
                        .frame(height: 18)
                        .padding(.horizontal, 3)
                    toolButton(tool, isActive: false) { onCreateNode() }
                } else {
                    toolButton(tool, isActive: canvas.activeTool == tool) {
                        canvas.activeTool = tool
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .floatingSurface(cornerRadius: 13)
    }

    private func toolButton(_ tool: CanvasTool, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: tool.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? AppTheme.chromeAccentInk : .secondary.opacity(0.8))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? AppTheme.chromeAccentSoftFill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.title)（\(tool.shortcut)）")
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
                    .foregroundColor(.secondary)
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
                .foregroundColor(.secondary.opacity(disabled ? 0.3 : 0.85))
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
        .foregroundColor(.primary.opacity(0.85))
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
                .foregroundColor(.secondary.opacity(0.35))
            Text("从左侧槽位库拖入内容，或点底部 ＋ 新建节点")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.55))
        }
        .allowsHitTesting(false)
    }
}
