import SwiftUI
import ClipSlotsKit

/// 画布连线层（v2.12.0 建立 · **v2.16.0 按 TapNow 实测重做线型**）。
///
/// ## 为什么它是独立的一层而不是画在卡片里
///
/// 连线跨两张卡片，画在任何一张里都要突破自己的 frame（`clipped` 一开就断），而卡片内部的排版预算
/// 是被 smoke 断言逐像素盯着的 —— 往里塞跨界元素是自找麻烦。
///
/// 它压在**节点层下面**：线从卡片边缘出发，压在卡片上会盖住内容（而卡片里正是产物预览）。代价是
/// 被卡片遮住的那段线点不中，这是对的 —— 那段线在视觉上本来就不存在。
///
/// ## v2.16.0 把 v2.15.0 的三件事全部删了
///
/// v2.15.0 我按"节点编辑器常识"给线加了**末端箭头 + 起点实心圆 + 运行中流动虚线**，理由写得挺像
/// 那么回事（"讲清方向"、"讲清出发点"、"讲清正在输送"）。实测 TapNow 之后发现方向正好相反：
/// **它的线就是一条 1pt 的灰色贝塞尔，什么都没有。**
///
/// 想明白之后这事是有道理的：
/// - **箭头**：连线两端接的是卡片的右边和左边，方向已经由"从右出、从左进"这个布局事实确定了，
///   箭头是在重复一遍已知信息。而箭头有实体面积，一屏十条线就是十个黑三角在卡片缝隙里晃。
/// - **起点圆**：同理，出发点就是卡片右边缘，圆点只是把它描了一遍。
/// - **流动虚线**：生成状态在**卡片上**已经讲得很清楚了（遮罩 + 转圈 + 秒数）。线上再跑一串亮点，
///   是同一件事说第二遍，而这一遍是**动的**——画布上任何持续运动都在抢注意力，代价远高于收益。
///
/// 留下的唯一一点状态表达是 `isFlowing` 时线**变亮**（`#909090` → `#E6E6E6`）。它是静态的、
/// 零运动的，只在用户主动去看这条线时才被读到。
///
/// ## 坐标系
///
/// 全程屏幕坐标。线宽 / 命中带**不随 zoom 缩放**：它们是操作尺度而不是画布内容，25% 视图下跟着
/// 缩到 0.25pt 就成了看不见也点不中的发丝。
struct CanvasEdgeLayer: View {

    let edges: [CanvasEdge]
    /// 节点 id → 它此刻的**屏幕矩形**（已含拖拽中的临时位移）。
    let frames: [String: CGRect]
    let selectedEdgeId: String?
    /// 下游节点此刻在排队 / 生成中。只用来让线变亮一档，见类型注释。
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

    /// 线宽。实测 TapNow 是 1pt；选中 / 悬停只加到 1.4pt。
    ///
    /// v2.15.0 这里是 1.6 / 2.2 / 2.6 —— 三档都太粗。粗线在纯黑底上是**结构**，会把画布读成
    /// 流程图；细线是**关系**，读起来是"这两张图有关联"。差别就在这一个 pt 上。
    private var lineWidth: CGFloat {
        (isSelected || hovering) ? TapSkin.edgeWidthActive : TapSkin.edgeWidth
    }

    private var lineColor: Color {
        if isSelected || hovering || isFlowing { return TapSkin.edgeInkActive }
        return TapSkin.edgeInk
    }

    var body: some View {
        let g = geometry
        ZStack(alignment: .topLeading) {
            CanvasEdgeCurve(start: g.start, c1: g.c1, c2: g.c2, end: g.end)
                .stroke(lineColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .allowsHitTesting(false)

            // 角色角标只在非自动态出现（`badgeText` 自己返回 nil 就不画）。
            //
            // 这是**我们有、TapNow 没有**的东西，刻意保留：「这条线当首帧用」是一个无法从布局推断
            // 的事实，不写出来用户就只能靠记。它与被删掉的箭头/端点圆的区别正在这里——那些是在
            // 重复已知信息，这个是在提供未知信息。
            if let badge = edge.role.badgeText {
                roleBadge(badge, at: CanvasEdgeGeometry.badgeAnchor(start: g.start, c1: g.c1, c2: g.c2, end: g.end))
            }

            // 命中带：把曲线加粗成一条不可见丝带。
            //
            // 与视觉宽度**刻意脱钩**（1pt 线 / 14pt 命中带）。用 `strokedPath` 生成实心形状而不是
            // 给可见线加 `contentShape`：后者在 macOS 上对细线的命中仍然按描边路径算，实测要压到
            // 1pt 精度才点得中——而线越细，这个问题越致命，正好是这一版把线改细之后最该补的一刀。
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
        .animation(TapSkin.stateAnim, value: hovering)
        .animation(TapSkin.stateAnim, value: isSelected)
    }

    @ViewBuilder
    private func roleBadge(_ text: String, at point: CGPoint) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundColor(TapSkin.chromeInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule(style: .continuous).fill(TapSkin.chromeFill))
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
        return line.strokedPath(StrokeStyle(lineWidth: TapSkin.edgeHitSlop * 2, lineCap: .round))
    }
}

// MARK: - 拖线预览

/// 从出口端口拖出来、还没落地的那条线。
///
/// ## v2.16.0：从虚线改回实线
///
/// 原来用虚线，理由是"它表达的是意图而不是事实"。听起来成立，实际观感是**这条线在闪**——虚线
/// 跟着光标走的时候，每一段短划都在重新分布，视觉上像一条坏掉的线。TapNow 拖线时用的就是与
/// 成品线完全相同的线型，"意图 vs 事实"由**末端那枚圆点**表达（有目标才实心），而不是由线型表达。
///
/// 这样还有一个实际好处：拖的过程和松手之后的结果长得一模一样，用户在松手前就已经看到最终形态。
struct CanvasLinkDragPreview: View {
    let start: CGPoint
    let cursor: CGPoint
    /// 光标是否正悬在一个可接受的目标上。
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
                .stroke(hasTarget ? TapSkin.edgeInkActive : TapSkin.edgeInk,
                        style: StrokeStyle(lineWidth: TapSkin.edgeWidthActive, lineCap: .round))
            // 末端圆点：唯一区分"已瞄准"与"悬空"的元素。悬空时空心（还没落地），
            // 瞄准时实心（松手就连上）。
            Circle()
                .fill(hasTarget ? TapSkin.edgeInkActive : Color.black)
                .overlay(Circle().stroke(hasTarget ? TapSkin.edgeInkActive : TapSkin.edgeInk, lineWidth: 1.2))
                .frame(width: 7, height: 7)
                .position(x: cursor.x, y: cursor.y)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 端口

/// 节点左右两侧的 **⊕ 端口**（v2.16.0 重做）。
///
/// ## 实测数据
///
/// TapNow 的端口是一枚**空心圆 + 细十字**，直径约 18pt，圆心落在卡片左右边缘**外侧约 28pt**
/// 处的垂直中线上。v2.15.0 我做的是 14/15pt 的圆、贴着卡片边缘（偏移 8~9pt），且入口画成
/// 带数字的实心圆。三处都不对：
///
/// 1. **太小**。18pt 的圆在 100% 视图下是一个"舒服的点击目标"，14pt 是"需要瞄一下"。
///    而这枚圆是连线操作的**唯一**入口，它的可命中性直接决定"连线顺不顺手"。
/// 2. **太近**。贴边 8pt 时圆压在卡片轮廓上，圆和卡片的圆角混在一起，看不出它是个独立控件；
///    推到 28pt 之后它悬在黑底上，边界干净。更要紧的是拖拽：贴边意味着"起手那几个像素还在
///    卡片范围内"，手势容易被卡片的拖动手势抢走。
/// 3. **数字是噪声**。入口上写"2"是在回答一个用户没问的问题（"这里接了几条线"——线自己就在
///    那儿，数得出来）。改成"空心 = 还没接 / 中心实点 = 已接"，同样的信息量，零文字。
struct CanvasPort: View {
    /// 端口是否处于活跃态（正被拖 / 正被瞄准 / 已有连线）。
    let isActive: Bool
    /// 已经连上了东西（决定中心画不画那个实点）。
    let isConnected: Bool

    var body: some View {
        ZStack {
            // 底：纯黑填充。不用透明——端口会压在连线上，透明会让线从圆心穿过去，
            // 看起来像"线把端口串起来了"。
            Circle().fill(Color.black)
            Circle().stroke(isActive ? TapSkin.portStrokeActive : TapSkin.portStroke,
                            lineWidth: TapSkin.portStrokeWidth)
            if isConnected {
                Circle()
                    .fill(isActive ? TapSkin.portStrokeActive : TapSkin.portStroke)
                    .frame(width: TapSkin.portDiameter * 0.3, height: TapSkin.portDiameter * 0.3)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: TapSkin.portGlyphSize, weight: .medium))
                    .foregroundColor(isActive ? TapSkin.portStrokeActive : TapSkin.portStroke)
            }
        }
        .frame(width: TapSkin.portDiameter, height: TapSkin.portDiameter)
    }
}
