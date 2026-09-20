import SwiftUI
import ClipSlotsKit

/// 画布连线层（v2.12.0）。
///
/// ## 为什么它是独立的一层而不是画在卡片里
///
/// 连线跨两张卡片，画在任何一张里都要突破自己的 frame（`clipped` 一开就断），而卡片内部的排版预算
/// 是被 smoke 断言逐像素盯着的（见 `CanvasCardLayout`）—— 往里塞跨界元素是自找麻烦。
///
/// 它压在**节点层下面**：线从卡片边缘出发，压在卡片上会盖住内容（而卡片里正是产物预览）。代价是
/// 被卡片遮住的那段线点不中，这是对的 —— 那段线在视觉上本来就不存在。
///
/// ## 坐标系
///
/// 全程屏幕坐标。线宽 / 箭头 / 命中带**不随 zoom 缩放**：它们是操作尺度而不是画布内容，
/// 25% 视图下跟着缩到 0.4pt 就成了看不见也点不中的发丝。
struct CanvasEdgeLayer: View {

    let edges: [CanvasEdge]
    /// 节点 id → 它此刻的**屏幕矩形**（已含拖拽中的临时位移）。
    let frames: [String: CGRect]
    let selectedEdgeId: String?
    /// 这条线的下游节点接受哪些角色（视频下游才有首帧 / 尾帧）。
    let roleOptions: (CanvasEdge) -> [CanvasEdgeRole]
    let onSelect: (String) -> Void
    let onSetRole: (String, CanvasEdgeRole) -> Void
    let onDisconnect: (String) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(edges) { edge in
                if let from = frames[edge.fromNodeId], let to = frames[edge.toNodeId] {
                    CanvasEdgeShapeView(edge: edge,
                                        fromRect: from,
                                        toRect: to,
                                        isSelected: edge.id == selectedEdgeId,
                                        roleOptions: roleOptions(edge),
                                        onSelect: { onSelect(edge.id) },
                                        onSetRole: { onSetRole(edge.id, $0) },
                                        onDisconnect: { onDisconnect(edge.id) })
                }
            }
        }
    }
}

// MARK: - 单条连线

private struct CanvasEdgeShapeView: View {

    let edge: CanvasEdge
    let fromRect: CGRect
    let toRect: CGRect
    let isSelected: Bool
    let roleOptions: [CanvasEdgeRole]
    let onSelect: () -> Void
    let onSetRole: (CanvasEdgeRole) -> Void
    let onDisconnect: () -> Void

    @State private var hovering = false

    private var geometry: (start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint) {
        let sides = CanvasEdgeGeometry.sides(from: fromRect, to: toRect)
        let start = CanvasEdgeGeometry.anchor(of: fromRect, side: sides.out)
        let end = CanvasEdgeGeometry.anchor(of: toRect, side: sides.in)
        let controls = CanvasEdgeGeometry.controlPoints(start: start,
                                                       end: end,
                                                       outSide: sides.out,
                                                       inSide: sides.in)
        return (start, controls.0, controls.1, end)
    }

    private var lineWidth: CGFloat {
        if isSelected { return 2.6 }
        return hovering ? 2.2 : 1.6
    }

    private var lineColor: Color {
        if isSelected { return AppTheme.chromeAccentInk }
        return AppTheme.chromeAccentInk.opacity(hovering ? 0.80 : 0.55)
    }

    var body: some View {
        let g = geometry
        ZStack(alignment: .topLeading) {
            CanvasEdgeCurve(start: g.start, c1: g.c1, c2: g.c2, end: g.end)
                .stroke(lineColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .allowsHitTesting(false)

            CanvasEdgeArrow(start: g.start, c1: g.c1, c2: g.c2, end: g.end)
                .fill(lineColor)
                .allowsHitTesting(false)

            // 角色角标只在非自动态出现（`badgeText` 自己返回 nil 就不画）。刻意不按 hover 过滤：
            // 它携带的是"这条线当首帧用"这种一眼就要看到的事实，藏起来等于没有。
            if let badge = edge.role.badgeText {
                roleBadge(badge, at: CanvasEdgeGeometry.badgeAnchor(start: g.start, c1: g.c1, c2: g.c2, end: g.end))
            }

            // 命中带：把曲线加粗成一条 16pt 的不可见丝带。
            // 用 `strokedPath` 生成实心形状而不是给可见线加 `contentShape`：后者在 macOS 上对
            // 细线的命中仍然按描边路径算，实测要压到 1pt 精度才点得中。
            CanvasEdgeHitBand(start: g.start, c1: g.c1, c2: g.c2, end: g.end)
                .fill(Color.white.opacity(0.001))
                .onHover { hovering = $0 }
                .onTapGesture { onSelect() }
                .contextMenu {
                    ForEach(roleOptions, id: \.self) { role in
                        Button {
                            onSetRole(role)
                        } label: {
                            Label(role.displayName, systemImage: edge.role == role ? "checkmark" : role.symbolName)
                        }
                    }
                    Divider()
                    Button(role: .destructive) { onDisconnect() } label: {
                        Label("断开连接", systemImage: "scissors")
                    }
                }
        }
    }

    @ViewBuilder
    private func roleBadge(_ text: String, at point: CGPoint) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(AppTheme.chromeAccentInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.canvasChromeSurface)
                    .overlay(Capsule(style: .continuous).stroke(AppTheme.chromeAccentInk.opacity(0.35), lineWidth: 1))
            )
            .position(x: point.x, y: point.y)
            .allowsHitTesting(false)
    }
}

// MARK: - 形状

/// 连线曲线。几何全部来自 Kit（`CanvasEdgeGeometry`），这里只把点翻译成 `Path`。
struct CanvasEdgeCurve: Shape {
    let start: CGPoint
    let c1: CGPoint
    let c2: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: c1, control2: c2)
        return path
    }
}

/// 末端箭头。
struct CanvasEdgeArrow: Shape {
    let start: CGPoint
    let c1: CGPoint
    let c2: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        let head = CanvasEdgeGeometry.arrowHead(start: start, c1: c1, c2: c2, end: end)
        var path = Path()
        path.move(to: head.tip)
        path.addLine(to: head.left)
        path.addLine(to: head.right)
        path.closeSubpath()
        return path
    }
}

/// 命中带：曲线加粗后的实心形状。
struct CanvasEdgeHitBand: Shape {
    let start: CGPoint
    let c1: CGPoint
    let c2: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var line = Path()
        line.move(to: start)
        line.addCurve(to: end, control1: c1, control2: c2)
        return line.strokedPath(StrokeStyle(lineWidth: 16, lineCap: .round))
    }
}

// MARK: - 拖线预览

/// 从出口把手拖出来、还没落地的那条线。
///
/// 用虚线是因为它表达的是"意图"而不是"事实"：实线会让人以为已经连上了，松手落空时那条线消失
/// 就变成"我连的线丢了"。
struct CanvasLinkDragPreview: View {
    let start: CGPoint
    let cursor: CGPoint
    /// 光标是否正悬在一个可接受的目标上（决定颜色 + 端点那枚小圆）。
    let hasTarget: Bool

    var body: some View {
        let sides = CanvasEdgeGeometry.sides(from: CGRect(x: start.x - 1, y: start.y - 1, width: 2, height: 2),
                                             to: CGRect(x: cursor.x - 1, y: cursor.y - 1, width: 2, height: 2))
        let controls = CanvasEdgeGeometry.controlPoints(start: start,
                                                       end: cursor,
                                                       outSide: sides.out,
                                                       inSide: sides.in)
        ZStack(alignment: .topLeading) {
            CanvasEdgeCurve(start: start, c1: controls.0, c2: controls.1, end: cursor)
                .stroke(AppTheme.chromeAccentInk.opacity(hasTarget ? 0.95 : 0.6),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
            Circle()
                .fill(hasTarget ? AppTheme.chromeAccentInk : AppTheme.canvasChromeSurface)
                .overlay(Circle().stroke(AppTheme.chromeAccentInk, lineWidth: 1.5))
                .frame(width: 9, height: 9)
                .position(x: cursor.x, y: cursor.y)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 端口把手

/// 节点右侧的「拖我连线」把手。
///
/// 位置固定在右边中点（而不是跟着渲染端点跑）：把手要形成肌肉记忆，位置必须可预测。渲染端点则
/// 顺着两张卡片的相对位置选边，两者刻意分开，见 `CanvasEdgeGeometry.outputHandle` 的注释。
struct CanvasOutputPort: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.canvasChromeSurface)
            Circle()
                .stroke(AppTheme.chromeAccentInk.opacity(isActive ? 1 : 0.65), lineWidth: 1.6)
            Circle()
                .fill(AppTheme.chromeAccentInk)
                .frame(width: 5, height: 5)
                .opacity(isActive ? 1 : 0.75)
        }
        .frame(width: 15, height: 15)
        .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
        .help("拖动连到另一个节点")
    }
}
