import SwiftUI
import ClipSlotsKit

struct CanvasNavigationControls: View {
    private typealias TapSkin = CanvasSkin
    let nodes: [CanvasNode]
    var selectedNodeIDs: Set<String> = []
    let viewport: CGRect
    let saveStatus: CanvasStore.SaveStatus
    @Binding var pan: CGSize
    @Binding var zoom: CGFloat
    @Binding var showMap: Bool
    @Binding var showEdges: Bool
    @Binding var gridSnap: Bool
    let onZoom: (CGFloat) -> Void
    let onFit: () -> Void
    let onViewportEnd: () -> Void
    let onSave: () -> Void
    let onAgent: () -> Void
    @State private var helpOpen = false
    @State private var helpPage: String?
    @State private var hovered: String?
    @State private var tooltipID: String?
    @State private var previousNodeCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let mapSize = CanvasReplicaGeometry.mapSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showMap {
                miniMap
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottomLeading)))
            }
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    control("map", symbol: "map.fill", hint: showMap ? "关闭小地图" : "打开小地图", active: showMap) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showMap.toggle() }
                    }
                    control("edges", symbol: "point.topleft.down.to.point.bottomright.curvepath",
                            hint: showEdges ? "隐藏节点连线" : "显示节点连线", active: !showEdges) {
                        showEdges.toggle()
                    }
                    control("grid", symbol: "square.grid.3x3", hint: "网格吸附", active: gridSnap) {
                        gridSnap.toggle()
                    }
                    control("fit", symbol: "viewfinder", hint: "聚焦全部节点", active: false, action: onFit)
                    zoomSlider
                }
                .padding(.leading, 8).padding(.trailing, 12).frame(height: 40)
                .background(TapSkin.chromeFill, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(TapSkin.border.opacity(0.45), lineWidth: 0.6)
                    .allowsHitTesting(false))
                Button(action: onSave) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 14)).frame(width: 40, height: 40)
                        Circle().fill(saveIndicator).frame(width: 5, height: 5).offset(x: -1, y: 1)
                    }
                    .background(TapSkin.chromeFill, in: Circle())
                }
                .buttonStyle(.plain)
                .help(saveHint)
                .accessibilityLabel(saveHint)
                .accessibilityIdentifier("canvas-save-status")
                Button { helpOpen.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 15)).frame(width: 40, height: 40)
                        .background(TapSkin.chromeFill, in: Circle())
                }
                .buttonStyle(.plain)
                .help("帮助")
                .accessibilityIdentifier("canvas-help")
                .popover(isPresented: $helpOpen, arrowEdge: .top) {
                    helpMenu
                }
            }
            .foregroundColor(TapSkin.ink)
        }
        .onChange(of: nodes.count) { count in
            if count > 50 && previousNodeCount <= 50 {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showMap = true }
            }
            previousNodeCount = count
        }
        .onChange(of: selectedNodeIDs.isEmpty) { empty in
            if !empty { withAnimation(.easeOut(duration: 0.2)) { showMap = true } }
        }
        .onAppear {
            previousNodeCount = nodes.count
            if !selectedNodeIDs.isEmpty || nodes.count > 50 { showMap = true }
        }
        .canvasControlRegion("canvas-navigation")
        .sheet(item: Binding(
            get: { helpPage.map { HelpPage(title: $0) } },
            set: { helpPage = $0?.title })) { page in
            VStack(alignment: .leading, spacing: 16) {
                Text(page.title).font(.title3.bold())
                Text(helpText(page.title)).font(.system(size: 13)).textSelection(.enabled)
                Button("完成") { helpPage = nil }.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(24).frame(width: 460)
        }
    }

    private var zoomSlider: some View {
        let range = CanvasReplicaGeometry.toolbarZoomMax - CanvasGeometry.zoomMin
        let trackWidth = CanvasReplicaGeometry.sliderWidth - 16
        let fraction = min(1, max(0, (zoom - CanvasGeometry.zoomMin) / range))
        return ZStack(alignment: .leading) {
            Capsule().fill(TapSkin.ink.opacity(0.22)).frame(height: 4)
            Circle().fill(TapSkin.ink).frame(width: 16, height: 16)
                .offset(x: trackWidth * fraction)
        }
        .frame(width: CanvasReplicaGeometry.sliderWidth, height: 28)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let position = min(1, max(0, (value.location.x - 8) / trackWidth))
            onZoom(((CanvasGeometry.zoomMin + position * range) * 100).rounded() / 100)
        }.onEnded { _ in onViewportEnd() })
        .help("放大/缩小画布（⌘ + 滚轮）")
        .accessibilityElement()
        .accessibilityLabel("画布缩放")
        .accessibilityValue("\(Int(zoom * 100))%")
        .accessibilityIdentifier("canvas-zoom-slider")
        .accessibilityAdjustableAction { direction in
            let delta: CGFloat = direction == .increment ? 0.01 : -0.01
            onZoom(CanvasGeometry.clampZoom(zoom + delta))
            onViewportEnd()
        }
    }

    private var miniMap: some View {
        CanvasMiniMap(nodes: nodes, selectedIDs: selectedNodeIDs, viewport: viewport,
                      pan: $pan, zoom: zoom, reduceMotion: reduceMotion, onViewportEnd: onViewportEnd)
        .frame(width: mapSize.width, height: mapSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(TapSkin.border.opacity(0.45), lineWidth: 0.6)
            .allowsHitTesting(false))
    }

    private func control(_ id: String, symbol: String, hint: String, active: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CanvasNavigationGlyph(id: id, highlighted: active || hovered == id)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 10).fill(active || hovered == id ? TapSkin.subtleFill : .clear)
                        .padding(hovered == id ? -2 : 0)
                        .shadow(color: .black.opacity(hovered == id ? 0.4 : 0), radius: 3, y: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(hint)
        .accessibilityIdentifier("canvas-navigation-" + id)
        .onHover { hovered = $0 ? id : nil }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hovered == id)
        .overlay(alignment: .top) {
            if tooltipID == id {
                Text(hint).font(.system(size: 11))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundColor(TapSkin.ink)
                    .background(TapSkin.chromeFill, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
                    .fixedSize().offset(y: -38).allowsHitTesting(false)
            }
        }
        .task(id: hovered) {
            tooltipID = nil
            guard let current = hovered else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            if hovered == current { tooltipID = current }
        }
    }

    private var saveIndicator: Color {
        switch saveStatus { case .failed: return .orange; case .saving: return .yellow; case .saved: return .cyan }
    }
    private var saveHint: String {
        switch saveStatus {
        case .saved: return "画布已保存"
        case .saving: return "正在保存画布"
        case .failed: return "保存失败，点击重试"
        }
    }
    private var helpMenu: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(["最近更新", "使用教程", "连接 Agent", "反馈问题", "快捷键"], id: \.self) { title in
                Button {
                    helpOpen = false
                    if title == "连接 Agent" { onAgent() } else { helpPage = title }
                } label: {
                    Label(title, systemImage: helpSymbol(title))
                        .font(.system(size: 12)).padding(10)
                        .frame(width: 142, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(6).foregroundColor(TapSkin.ink).background(TapSkin.chromeFill)
    }
    private struct HelpPage: Identifiable { let title: String; var id: String { title } }
    private func helpSymbol(_ title: String) -> String {
        switch title {
        case "最近更新": return "bell.fill"
        case "使用教程": return "info.circle"
        case "连接 Agent": return "powerplug"
        case "反馈问题": return "ladybug"
        default: return "keyboard"
        }
    }
    private func helpText(_ title: String) -> String {
        switch title {
        case "最近更新":
            return "本次更新：稳定拖拽连线、节点对齐吸附、1–4 次生成、同行结果节点、小地图与画布导航。"
        case "使用教程":
            return "双击空白添加节点；拖动节点右侧 + 连接已有节点或创建下游节点。点击空白取消选择，Shift 多选。小地图可拖动视口，缩放滑杆改变观察范围。生成结果保留在新的节点中。"
        case "反馈问题":
            return "请记录复现步骤、应用版本 \(AppVersion.current) 和录屏。生成失败时可从节点的“错误详情”复制诊断信息。"
        default:
            return "空格 + 拖动：抓手平移\n⌘ + 滚轮：缩放\nShift + 点击：多选\n⌘Z：撤销\n⇧⌘Z：重做\nDelete：删除所选节点或连线\nEsc：取消当前操作\n双击空白：添加节点"
        }
    }
}
