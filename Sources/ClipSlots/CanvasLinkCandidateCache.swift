import SwiftUI
import ClipSlotsKit

@MainActor
final class CanvasLinkCandidateCache: ObservableObject {
    private var revision: UInt64?
    private var project = ""
    private var source = ""
    private var reverse = false
    private var validIDs: Set<String> = []

    func candidates(canvas: CanvasStore, source: String, reverse: Bool) -> Set<String> {
        if revision == canvas.graphRevision, project == canvas.activeProjectId,
           self.source == source, self.reverse == reverse { return validIDs }
        let hidden = canvas.piledMemberIDs
        let nodes = canvas.nodes, edges = canvas.edges
        validIDs = Set(nodes.compactMap { node in
            guard node.id != source, !hidden.contains(node.id),
                  canvas.connectionPolicy.canConnect(from: source, to: node.id),
                  let target = reverse ? canvas.node(id: source) : node,
                  CanvasEdgeGraph.canConnect(from: reverse ? node.id : source,
                    to: target.id, nodes: nodes, edges: edges,
                    purpose: CanvasEdgeGraph.defaultPurpose(for: target)) == nil else { return nil }
            return node.id
        })
        revision = canvas.graphRevision; project = canvas.activeProjectId
        self.source = source; self.reverse = reverse
        return validIDs
    }
}
