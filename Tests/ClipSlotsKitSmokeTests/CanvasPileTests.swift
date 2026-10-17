import Foundation
import ClipSlotsKit

func runCanvasPileTests(_ t: TestRunner) {
    struct Fixtures: Decodable {
        struct Sample: Decodable {
            struct Node: Decodable { let id: String; let type: String; let width: CGFloat; let height: CGFloat }
            struct Origin: Decodable { let id: String; let x: CGFloat; let y: CGFloat }
            struct Gallery: Decodable {
                let id: String; let centerX: CGFloat; let centerY: CGFloat; let width: CGFloat; let height: CGFloat
            }
            let count: Int; let width: CGFloat; let height: CGFloat
            let nodes: [Node]; let origins: [Origin]; let gallery: [Gallery]
        }
        struct Layer: Decodable {
            let count: Int; let index: Int; let expansion: CGFloat
            let x: CGFloat; let y: CGFloat; let rotation: Double; let shade: Double
        }
        let samples: [Sample]; let layers: [Layer]
    }
    do {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("PileFixtures.json")
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
        for sample in fixtures.samples {
            let nodes = sample.nodes.enumerated().map { i, source -> CanvasNode in
                var node = CanvasNode(pageId: "p", groupId: "g", slot: i + 1,
                    kind: source.type == "text" ? .text : .image, x: CGFloat(i * 70), y: CGFloat(i * 20))
                node.width = source.width; node.height = source.height
                return node
            }
            let pile = CanvasPile(id: "PILE-test", memberIDs: nodes.map(\.id), at: CGPoint(x: -80, y: 45))
            let frame = CanvasPileGeometry.frame(pile, nodes: nodes)
            t.equal(frame.size, CGSize(width: sample.width, height: sample.height), "REA Pile \(sample.count) last-five frame")
            let origins = CanvasPileGeometry.unstackOrigins(pile, nodes: nodes)
            for origin in sample.origins {
                t.equal(origins[origin.id], CGPoint(x: origin.x, y: origin.y), "REA unstack \(sample.count)/\(origin.id)")
            }
            let gallery = CanvasPileGeometry.galleryFrames(nodes)
            for expected in sample.gallery {
                // IPe returns centers. Compare those directly; reconstructing an
                // origin from a center introduces a needless floating-point round trip.
                let actual = gallery[expected.id]
                t.check(actual?.midX == expected.centerX && actual?.midY == expected.centerY
                    && actual?.width == expected.width && actual?.height == expected.height,
                    "REA gallery \(sample.count)/\(expected.id) center and size")
            }
            let edges = [CanvasEdge(id: "original", fromNodeId: nodes[0].id, toNodeId: nodes[1].id, role: .prompt)]
            let doc = CanvasDocument(nodes: nodes, edges: edges, piles: [pile])
            let copy = try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(doc))
            t.check(copy.piles == [pile] && copy.edges == edges && copy.nodes == nodes,
                    "Pile \(sample.count) persists exact nodes and graph")
        }
        for expected in fixtures.layers {
            let actual = CanvasPileGeometry.layer(index: expected.index, count: expected.count, expansion: expected.expansion)
            t.equal(actual.offset, CGPoint(x: expected.x, y: expected.y), "REA layer \(expected.count)/\(expected.index)/\(expected.expansion)")
            t.equal(actual.rotation, expected.rotation, "REA layer rotation")
            t.equal(actual.shade, expected.shade, "REA layer shade")
        }
        var a = CanvasNode(pageId: "p", groupId: "g", slot: 1, kind: .text, x: 0, y: 0)
        var b = CanvasNode(pageId: "p", groupId: "g", slot: 2, kind: .image, x: 600, y: 100)
        a.width = 500; a.height = 700; b.width = 220; b.height = 160
        let nodes = [a, b]
        let group = CanvasNodeGroup(id: "parent", nodeIDs: nodes.map(\.id))
        let pile = CanvasPileGeometry.creation(sourceIDs: [a.id, b.id], nodes: nodes, piles: [], groups: [group])
        t.check(pile != nil && pile?.groupID == "parent", "Pile retains shared Group parent")
        t.equal(CanvasPileGeometry.creation(sourceIDs: [a.id, a.id], nodes: nodes, piles: [], groups: []), nil,
                "Pile deduplicates selection before minimum-size check")
        t.equal(CanvasPileGeometry.creation(sourceIDs: [a.id, "missing"], nodes: nodes, piles: [], groups: []), nil,
                "Pile refuses a missing selected source")
        if let pile {
            let dirty = CanvasPile(id: "dirty", memberIDs: [a.id, a.id, "missing", b.id], at: .zero)
            t.equal(CanvasPile.normalized([dirty, pile], nodes: nodes).map(\.id), ["dirty"],
                    "Normalization keeps one owner and removes duplicate and missing members")
            t.equal(CanvasPileGeometry.creation(sourceIDs: [a.id, b.id], nodes: nodes, piles: [pile], groups: []), nil,
                    "Hidden members cannot be individually selected into another Pile")
        }
        let legacy = try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(CanvasDocument(nodes: nodes)))
        t.check(legacy.piles.isEmpty && legacy.nodes == nodes, "Older documents retain their content without Piles")
        t.equal(CanvasKeyBinding.action(keyCode: 5, command: true, shift: false), .pile, "Mod+G creates a Pile")
        t.equal(CanvasKeyBinding.action(keyCode: 5, command: true, shift: true), .none, "Unverified Shift+Mod+G is not assigned")
        t.equal(CanvasKeyBinding.action(keyCode: 5, command: true, shift: false, option: true), .none,
                "Alt+Mod+G is not intercepted")

        let screen = CGRect(x: 410, y: 175, width: 260, height: 180)
        let poses = CanvasPileGalleryMotion.pilePoses(nodes, screenFrame: screen, zoom: 0.65, expansion: 2)
        if let bottom = poses[a.id], let top = poses[b.id] {
            let layer = CanvasPileGeometry.layer(index: 0, count: 2, expansion: 2)
            t.check(abs(bottom.frame.midX - (screen.midX + layer.offset.x * 0.65)) < 0.000001
                && abs(bottom.frame.midY - (screen.midY + layer.offset.y * 0.65)) < 0.000001,
                "Gallery source uses actual Pile center and expanded layer offsets")
            t.check(abs(bottom.frame.width - 500 * 320 / 700 * 0.65) < 0.000001
                    && abs(bottom.frame.height - 320 * 0.65) < 0.000001,
                    "Gallery source respects text display cap and canvas zoom")
            t.equal(bottom.rotation, -7, "Gallery source retains expanded bottom rotation")
            t.equal(bottom.shade, 0.18, "Gallery source retains bottom depth shading")
            t.equal(top.frame.midY, screen.midY - 8 * 0.65, "Gallery source retains top-member expansion lift")
            t.equal(top.frame.size, CGSize(width: 220 * 0.65, height: 160 * 0.65),
                    "Gallery source retains media aspect ratio")
            t.equal(top.rotation, 0, "Top member opens without invented rotation")
            let grid = CanvasPileGalleryMotion.gridPose(CGRect(x: -240, y: 80, width: 220, height: 160),
                viewport: CGSize(width: 1000, height: 800), pan: CGSize(width: 30, height: -20), zoom: 0.6)
            t.equal(grid.frame, CGRect(x: 386, y: 428, width: 132, height: 96),
                    "Gallery grid card excludes label/action bands from its geometry")
            t.equal(bottom.interpolated(to: grid, progress: 0).frame, bottom.frame,
                    "Opening begins at the actual Pile member frame")
            t.equal(bottom.interpolated(to: grid, progress: 1), grid, "Opening reaches unrotated unshaded grid pose")
            let middle = bottom.interpolated(to: grid, progress: 0.5)
            t.equal(middle.rotation, bottom.rotation / 2, "Opening coherently removes rotation")
            t.equal(middle.shade, bottom.shade / 2, "Opening coherently removes depth shade")
            t.check(abs(middle.frame.midX - (bottom.frame.midX + grid.frame.midX) / 2) < 0.000001,
                    "Opening interpolates card geometry instead of scaling the whole modal")
            t.equal(grid.interpolated(to: bottom, progress: 1), bottom, "Closing restores source geometry and depth")
            t.equal(bottom.interpolated(to: grid, progress: -1).frame, bottom.frame, "Interpolation clamps negative progress")
            t.equal(bottom.interpolated(to: grid, progress: .nan).frame, bottom.frame, "Interpolation rejects invalid progress")
        } else { t.check(false, "Mixed-size source poses exist") }

        var many = (0..<7).map { index -> CanvasNode in
            var node = CanvasNode(pageId: "p", groupId: "many", slot: index + 1, kind: .image, x: 0, y: 0)
            node.width = 300; node.height = 200
            return node
        }
        many[0].width = 800; many[0].height = 100
        let manyPoses = CanvasPileGalleryMotion.pilePoses(many, screenFrame: screen, zoom: 1, expansion: 1)
        t.equal(manyPoses.count, 7, "Gallery includes every member, not only the five preview cards")
        t.equal(manyPoses[many[0].id]?.zIndex, 0, "Hidden Gallery source sits behind the visible five")
        t.equal(manyPoses[many[0].id]?.frame.width, 284, "Hidden source fits within recovered 8pt cover inset")
        t.equal(manyPoses[many[0].id]?.frame.height, 35.5, "Hidden source fitting preserves aspect ratio")
        t.equal(manyPoses[many[2].id]?.zIndex, 1, "Visible preview order starts at the sixth-from-top boundary")
        t.equal(manyPoses[many[6].id]?.zIndex, 5, "Top preview card has highest source rank")
        for count in 2...7 {
            let members = Array(many.prefix(count))
            let targets = CanvasPileGalleryMotion.pilePoses(members, screenFrame: screen, zoom: 0.65, expansion: 2.35)
            let bounds = CanvasPileGalleryMotion.returnBounds(members, screenFrame: screen, zoom: 0.65)
            t.check(targets.values.filter { $0.zIndex > 0 }.allSatisfy {
                bounds.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
            }, "Return bounds cover every expanded member center for \(count) members")
            t.check(targets.values.filter { $0.zIndex > 0 }.allSatisfy {
                $0.rotatedBounds.minX >= bounds.minX && $0.rotatedBounds.maxX <= bounds.maxX
                    && $0.rotatedBounds.minY >= bounds.minY && $0.rotatedBounds.maxY <= bounds.maxY
            }, "Native return bounds include rotated card extents for \(count) members")
        }
        t.equal(CanvasPileGalleryMotion.returnBounds([], screenFrame: screen, zoom: 1), .null,
                "Empty return target cannot accept a drop")
        t.check(CanvasPileGalleryMotion.pilePoses(nodes, screenFrame: screen, zoom: 0, expansion: 1).isEmpty,
                "Invalid zoom cannot create source poses")
        t.equal(CanvasPileGalleryMotion.returnExpansion, 2.35, "Recovered return-target expansion is distinct from hover")
        t.equal(CanvasPileGalleryMotion.stagger(index: 49), 0.048, "Gallery stagger is capped at five items")
        t.check(abs(CanvasPileGalleryMotion.completionDuration(memberCount: 50) - 0.568) < 0.000001,
                "Gallery completion waits for capped stagger and completion buffer")

        for (delta, expected) in [(CGSize(width: 71.999, height: 0), false),
                                   (CGSize(width: 72, height: 0), true),
                                   (CGSize(width: -72, height: 0), true),
                                   (CGSize(width: 0, height: 72), true),
                                   (CGSize(width: 43.2, height: 57.6), true),
                                   (CGSize(width: 50, height: 50), false),
                                   (CGSize(width: CGFloat.nan, height: 0), false)] {
            t.equal(CanvasPileGalleryMotion.hasCrossedThreshold(delta), expected,
                    "Extraction threshold uses screen-space Euclidean distance: \(delta)")
        }
        let picked = CGRect(x: 100, y: 120, width: 240, height: 180)
        let grab = CanvasPileGalleryMotion.grabFraction(pointer: CGPoint(x: 160, y: 255), frame: picked)
        t.equal(grab, CGPoint(x: 0.25, y: 0.75), "Pickup records fractional grab point, not pointer as center")
        let carried = CanvasPileGalleryMotion.carriedFrame(size: CGSize(width: 400, height: 300),
            pointer: CGPoint(x: 750, y: 600), grab: grab)
        t.equal(carried, CGRect(x: 650, y: 375, width: 400, height: 300), "Pickup resize keeps original grab point under pointer")
        t.check(carried.midX != 750 && carried.midY != 600, "Extraction landing uses card center rather than release pointer")

        var session = CanvasPileGallerySession()
        t.check(!session.beginDrag(a.id), "Opening Gallery rejects drag pickup")
        t.check(session.complete(revision: session.revision) && session.phase == .open, "Opening completes into interactive Gallery")
        t.check(!session.complete(revision: session.revision), "Duplicate completion cannot mutate an open Gallery")
        t.check(session.beginDrag(a.id) && !session.beginDrag(b.id), "One member owns the Gallery drag")
        let beforeCollapse = session.revision
        t.check(!session.updateDrag(CGSize(width: 71, height: 0)) && session.phase == .dragging,
                "Sub-threshold pickup does not collapse")
        t.check(session.updateDrag(CGSize(width: 72, height: 0)) && session.phase == .collapsed,
                "Exactly 72px activates extraction collapse")
        t.check(!session.updateDrag(.zero) && session.phase == .collapsed, "Collapse remains latched after returning inside threshold")
        t.check(!session.complete(revision: beforeCollapse), "Stale pre-collapse timer cannot end a drag")
        t.equal(session.cancelDrag(), .pile(a.id), "Cancelled collapsed drag returns to Pile without extraction")
        t.check(!session.requestClose() && !session.beginDrag(b.id), "Pile handoff blocks close and second pickup")
        t.check(session.complete(revision: session.revision) && session.phase == .closed, "Pile return waits for handoff completion")
        t.equal(session.finishDrag(overReturnTarget: false), nil, "Repeated mouse-up after handoff cannot extract")

        var small = CanvasPileGallerySession()
        _ = small.complete(revision: small.revision); _ = small.beginDrag(b.id)
        t.equal(small.finishDrag(overReturnTarget: false), .cell(b.id),
                "Sub-threshold release outside Pile restores Gallery cell")
        t.check(small.complete(revision: small.revision) && small.phase == .open && small.memberID == nil,
                "Cell snapback restores interactive Gallery and clears drag owner")
        _ = small.beginDrag(b.id)
        t.equal(small.cancelDrag(), .cell(b.id), "Sub-threshold cancellation restores exact cell without promotion")
        _ = small.complete(revision: small.revision); _ = small.beginDrag(a.id)
        _ = small.updateDrag(CGSize(width: 100, height: 0))
        t.equal(small.finishDrag(overReturnTarget: false), .canvas(a.id), "Collapsed release outside return target lands on canvas")
        t.check(small.complete(revision: small.revision) && small.phase == .closed,
                "Canvas extraction waits for visual landing before closing")

        var dismissed = CanvasPileGallerySession()
        let openingRevision = dismissed.revision
        t.check(dismissed.requestClose(), "Native close during opening reverses the transition")
        t.check(!dismissed.complete(revision: openingRevision), "Cancelled opening completion cannot reopen a closing Gallery")
        t.check(!dismissed.requestClose(), "Repeated close is idempotent")
        t.check(dismissed.complete(revision: dismissed.revision) && dismissed.phase == .closed, "Reverse animation owns final dismissal")
    } catch { t.check(false, "Pile fixtures and roundtrip: \(error)") }
}
