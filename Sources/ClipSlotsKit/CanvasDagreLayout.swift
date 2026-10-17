import Foundation
import CoreGraphics
import JavaScriptCore

/// The same Dagre 1.1.5 LR engine used by TapNow Ozl. Only numeric geometry
/// enters this fresh JavaScript context; no filesystem, network or app bridge.
public enum CanvasDagreLayout {
    public struct Result {
        public let origins: [String: CGPoint]
        public let frame: CGRect
    }
    public static func layout(nodes: [CanvasNode], edges: [CanvasEdge], at anchor: CGPoint) -> Result? {
        guard !nodes.isEmpty else { return Result(origins: [:], frame: CGRect(x: anchor.x, y: anchor.y, width: 200, height: 200)) }
        let relative = "ClipSlots_ClipSlotsKit.bundle/Resources/dagre-1.1.5.min.js"
        let locations = [
            Bundle.main.resourceURL?.appendingPathComponent(relative),
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources").appendingPathComponent(relative),
            Bundle.main.bundleURL.appendingPathComponent(relative)
        ].compactMap { $0 }
        var resource = locations.first { FileManager.default.fileExists(atPath: $0.path) }
        #if DEBUG
        if resource == nil {
            resource = Bundle.module.url(forResource: "dagre-1.1.5.min", withExtension: "js", subdirectory: "Resources")
        }
        #endif
        guard let resource, let source = try? String(contentsOf: resource),
              let context = JSContext() else { return nil }
        context.evaluateScript(source)
        guard context.exception == nil else { return nil }
        let input = nodes.map { ["id": $0.id, "width": $0.width, "height": $0.height] as [String: Any] }
        let ids = Set(nodes.map(\.id))
        let links = edges.filter { ids.contains($0.fromNodeId) && ids.contains($0.toNodeId) }
            .map { ["from": $0.fromNodeId, "to": $0.toNodeId] }
        context.setObject(input, forKeyedSubscript: "layoutNodes" as NSString)
        context.setObject(links, forKeyedSubscript: "layoutEdges" as NSString)
        let script = """
        (function() {
          const g = new dagre.graphlib.Graph().setDefaultEdgeLabel(function(){return {};});
          g.setGraph({rankdir:"LR",nodesep:200,ranksep:200,marginx:100,marginy:100});
          layoutNodes.forEach(function(n){g.setNode(n.id,{width:n.width,height:n.height});});
          layoutEdges.forEach(function(e){g.setEdge(e.from,e.to);});
          dagre.layout(g);
          const placed = layoutNodes.map(function(n) {
            const p=g.node(n.id); return {id:n.id,x:p.x-n.width/2,y:p.y-n.height/2,width:n.width,height:n.height};
          });
          const minX=Math.min.apply(null,placed.map(function(n){return n.x;}));
          const minY=Math.min.apply(null,placed.map(function(n){return n.y;}));
          placed.forEach(function(n){n.x=n.x-minX+100;n.y=n.y-minY+100;});
          return JSON.stringify({nodes:placed,
            width:Math.max.apply(null,placed.map(function(n){return n.x+n.width;}))+100,
            height:Math.max.apply(null,placed.map(function(n){return n.y+n.height;}))+100});
        })()
        """
        guard let json = context.evaluateScript(script)?.toString(), context.exception == nil,
              let data = json.data(using: .utf8) else { return nil }
        struct Output: Decodable {
            struct Node: Decodable { let id: String; let x, y: CGFloat }
            let nodes: [Node]
            let width, height: CGFloat
        }
        guard let output = try? JSONDecoder().decode(Output.self, from: data) else { return nil }
        let frame = CGRect(x: anchor.x, y: anchor.y, width: output.width, height: output.height)
        guard CanvasGroupGeometry.isValid(frame), output.nodes.count == nodes.count,
              output.nodes.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let origins = Dictionary(uniqueKeysWithValues: output.nodes.map {
            ($0.id, CGPoint(x: anchor.x + $0.x, y: anchor.y + $0.y))
        })
        return Result(origins: origins, frame: frame)
    }
}
