import SwiftUI
import ClipSlotsKit

struct CanvasPortHit {
    let node: CanvasNode
    let output: Bool
    let point: CGPoint
}

extension CanvasWorkspaceView {
    /// Selection and hover expose independent node handles, as in TapNow's
    /// node-local group hover. A neighbour never removes the selected handle.
    var staticPortNodes: [CanvasNode] {
        guard canvas.selectedGroupID == nil, canvas.selectedNodeIds.count < 2,
              addMenu == nil, draggingNodeId == nil, inputFilesNodeId == nil else { return [] }
        var ids = canvas.selectedNodeIds
        if let hoverHoldNodeId { ids.insert(hoverHoldNodeId) }
        return nodesInPaintOrder.filter { ids.contains($0.id) && canvas.connectionPolicy.nodesConnectable }
    }

    func portPoint(of node: CanvasNode, output: Bool) -> CGPoint {
        if let session = pointerSession {
            switch session.target {
            case .link(let id) where output && id == node.id,
                 .inputLink(let id) where !output && id == node.id:
                return session.linkPortPoint ?? session.start
            default: break
            }
        }
        let home = output ? outputPortHome(of: node) : inputPortHome(of: node)
        let offset = portMotions.motion(nodeID: node.id, output: output).presentationOffset(output: output)
        return CGPoint(x: home.x + offset.x, y: home.y + offset.y)
    }

    func displayedPortHit(at point: CGPoint) -> CanvasPortHit? {
        guard point.x >= sidebarWidth, !canvasOverlayContains(point) else { return nil }
        for node in staticPortNodes.reversed() {
            guard canvas.connectionPolicy.canConnect(nodeID: node.id) else { continue }
            for output in [true, false] {
                guard portMotions.motion(nodeID: node.id, output: output).opacity() > 0.01 else { continue }
                let port = portPoint(of: node, output: output)
                guard portIsExposed(port, nodeId: node.id),
                      portIsAboveBody(at: point, nodeId: node.id) else { continue }
                let radius = TapSkin.portDiameter * zoom / 2
                if hypot(point.x - port.x, point.y - port.y) < radius {
                    return CanvasPortHit(node: node, output: output, point: port)
                }
            }
        }
        return nil
    }

    func spawnUpstream(of node: CanvasNode, at point: CGPoint) {
        guard canvas.connectionPolicy.canConnect(nodeID: node.id) else { return }
        let rect = screenFrame(of: node)
        let center = CanvasGeometry.canvasPoint(
            screen: CGPoint(x: rect.minX - 80 - 160 * zoom, y: rect.midY),
            pan: effectivePan, zoom: zoom)
        openAddMenu(atScreen: point, canvasPoint: center, parentNodeId: nil, childNodeId: node.id)
    }
}

/// Stable identity for each handle prevents moving the same SwiftUI leaf
/// between neighbours as hover changes.
struct CanvasNodePort: View {
    let nodeID: String
    let output: Bool
    let home: CGPoint
    let frozenPoint: CGPoint?
    let active: Bool
    let connected: Bool
    let motions: CanvasPortMotions
    var visible = true
    var zoom: CGFloat = 1
    var forceHidden = false

    var body: some View {
        let motion = motions.motion(nodeID: nodeID, output: output)
        CanvasMovingPort(motion: motion,
                         home: home, frozenPoint: frozenPoint,
                         isActive: active, isConnected: connected, visible: visible, output: output,
                         zoom: zoom, forceHidden: forceHidden)
            // Identity is stable for this node/side until the motion cache is
            // replaced or pruned. A new motion must receive its initial reveal.
            .id(ObjectIdentifier(motion))
    }
}
