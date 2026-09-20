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
    /// 这条线此刻是否"正在被使用"——下游节点在排队 / 生成中（v2.15.0）。
    ///
    /// 用闭包而不是让本视图直接拿 `CanvasStore`：连线层是纯渲染层，它对节点状态的唯一需求就是
    /// 这一个布尔值。把整个 store 塞进来会让它随任意节点的任意字段变化重绘整张网。
    let isFlowing: (CanvasEdge) -> Bool
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
                                        isFlowing: isFlowing(edge),
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
    let isFlowing: Bool
    let roleOptions: [CanvasEdgeRole]
    let onSelect: () -> Void
    let onSetRole: (CanvasEdgeRole) -> Void
    let onDisconnect: () -> Void

    @State private var hovering = false
    /// 流动虚线的相位。动的是 `dashPhase`，不是整条路径 —— 路径每帧重算会让曲线抖。
    @State private var dashPhase: CGFloat = 0

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

            // ★ v2.15.0：运行中流动虚线。
            //
            // 叠在实线**之上**而不是替换它：替换会让线在生成开始的那一刻"变细变虚"，看着像断开了；
            // 叠加则是实线上跑过一串亮点，语义是"这条线上正有东西在走"。
            if isFlowing {
                CanvasEdgeCurve(start: g.start, c1: g.c1, c2: g.c2, end: g.end)
                    .stroke(AppTheme.chromeAccentInk.opacity(0.95),
                            style: StrokeStyle(lineWidth: lineWidth + 0.6,
                                               lineCap: .round,
                                               dash: [5, 9],
                                               dashPhase: dashPhase))
                    .allowsHitTesting(false)
            }

            CanvasEdgeArrow(start: g.start, c1: g.c1, c2: g.c2, end: g.end)
                .fill(lineColor)
                .allowsHitTesting(false)

            // ★ v2.15.0：起点端点圆。
            //
            // 末端已经有箭头，起点却是一条线"凭空长出来"——线贴着卡片边缘时分不清它是从这张卡出发、
            // 还是只是路过被卡片压住了。一枚 6pt 的实心圆把"出发点"讲清楚，代价是零交互（不可点）。
            Circle()
                .fill(lineColor)
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(AppTheme.canvasChromeSurface, lineWidth: 1.2))
                .position(x: g.start.x, y: g.start.y)
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
        // 只在流动态起动画，并且在停下时把相位**归零**：留着非零相位会让下一次开始流动时
        // 虚线从半截处接上，看着像丢了一帧。
        .onAppear { syncFlowAnimation() }
        .onChange(of: isFlowing) { _ in syncFlowAnimation() }
    }

    /// 起 / 停流动动画。
    ///
    /// `repeatForever(autoreverses: false)` + 负向位移 = 虚线顺着线的方向（起点→终点）跑。
    /// 正向会让它倒着跑，观感是"下游在往上游倒灌"。
    private func syncFlowAnimation() {
        guard isFlowing else {
            withAnimation(.linear(duration: 0.12)) { dashPhase = 0 }
            return
        }
        dashPhase = 0
        withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
            // 一个完整 dash 周期（5 + 9）：位移刚好一个周期时首尾无缝，不会在循环边界跳一下。
            dashPhase = -14
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

/// 节点左侧的**入口端口**（v2.15.0）。
///
/// ## 为什么以前没有、现在要加
///
/// v2.12.0 只画了出口把手：连线是"从右边拖出去"的单向动作，入口不需要被抓住。但用户这一轮明确
/// 提到"节点间的连接显示"—— 缺口在于**静态时看不出一个节点能不能接东西**：线从别处飞来，落在
/// 卡片左缘某处，而卡片上没有任何标记说"这里是入口"。拖线时更明显：候选目标只有整张卡在等着，
/// 落点全凭猜。
///
/// 它刻意**不可拖动**（`allowsHitTesting(false)` 由调用方给）：入口是被连的一端，从入口反向拖出
/// 一条线意味着要在这里再做一套"反向连接"语义，而那与出口把手完全重复。
struct CanvasInputPort: View {
    /// 已有几条上游连线。0 时画成空心（"能接但还没接"），>0 画成实心并写数字。
    let incomingCount: Int
    /// 是否正被拖线瞄准。
    let isTargeted: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isTargeted ? AppTheme.chromeAccentInk : AppTheme.canvasChromeSurface)
            Circle()
                .stroke(AppTheme.chromeAccentInk.opacity(isTargeted ? 1 : (incomingCount > 0 ? 0.85 : 0.45)),
                        lineWidth: 1.4)
            if incomingCount > 0 {
                Text("\(min(incomingCount, 9))")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(isTargeted ? .white : AppTheme.chromeAccentInk)
            } else if isTargeted {
                Image(systemName: "plus")
                    .font(.system(size: 7, weight: .black))
                    .foregroundColor(.white)
            }
        }
        .frame(width: 14, height: 14)
        .shadow(color: Color.black.opacity(0.16), radius: 2, x: 0, y: 1)
        .help(incomingCount > 0 ? "有 \(incomingCount) 条上游连线" : "可接收上游连线")
    }
}

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
