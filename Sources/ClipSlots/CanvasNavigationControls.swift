import SwiftUI
import ClipSlotsKit

struct CanvasNavigationControls: View {
    private typealias TapSkin = CanvasSkin
    let nodes: [CanvasNode]
    var projectID: String = ""
    var selectedNodeIDs: Set<String> = []
    let viewport: CGRect
    @Binding var pan: CGSize
    @Binding var zoom: CGFloat
    @Binding var showMap: Bool
    @Binding var showEdges: Bool
    @Binding var gridSnap: Bool
    let onZoom: (CGFloat) -> Void
    let onFit: () -> Void
    let onViewportEnd: () -> Void
    @State private var hovered: String?
    @State private var tooltipID: String?
    @State private var previousNodeCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let mapSize = CanvasReplicaGeometry.mapSize

    var body: some View {
        WorkspaceContentBoundary {
        VStack(alignment: .leading, spacing: 8) {
            if showMap {
                WorkspaceContentBoundary { miniMap }
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottomLeading)))
            }
            WorkspaceStableBoundary(key: .init(
                zoom: zoom, map: showMap, edges: showEdges, grid: gridSnap,
                hovered: hovered, tooltip: tooltipID,
                project: projectID)) {
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
            }
            .foregroundColor(TapSkin.ink)
            }.equatable()
        }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: showMap)
        .onChange(of: nodes.count) { count in
            if count > 50 && previousNodeCount <= 50 && !showMap {
                showMap = true
            }
            previousNodeCount = count
        }
        .onChange(of: selectedNodeIDs.isEmpty) { empty in
            if !empty && !showMap { showMap = true }
        }
        .onAppear {
            previousNodeCount = nodes.count
            if !selectedNodeIDs.isEmpty || nodes.count > 50 { showMap = true }
        }
        .canvasControlRegion("canvas-navigation")
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas-minimap")
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

}
