#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

extension CanvasWorkspaceView {
    /// Exercises the actual gallery lifecycle without claiming mouse delivery.
    /// This mode is usable while the desktop is locked.
    @MainActor func runPilePresentationProbe(directory: URL, pileID: String,
                                             check: (Bool, String) -> Void) async -> [[String: Any]] {
        var live: CanvasWorkspaceView { CanvasAgentGroupsProbeBridge.current ?? self }
        let beforeNodes = canvas.nodes, beforeEdges = canvas.edges, beforePiles = canvas.piles
        let history = canvas.history.cursor, camera = live.effectivePan, zoom = live.zoom
        var observations: [[String: Any]] = []
        func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }
        func sample(_ name: String) {
            var record: [String: Any] = ["name": name,
                "elapsedUptime": ProcessInfo.processInfo.systemUptime,
                "phase": CanvasPileGalleryProbeBridge.sessions[pileID]?.phase.rawValue ?? "removed",
                "poseSemantics": "destination, not presentation transform"]
            if let root = live.inputRouter.anchorView?.window?.contentView,
               let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: directory.appendingPathComponent(name + ".png"))
                    record["png"] = name + ".png"
                }
            }
            observations.append(record)
        }
        canvas.select(id: pileID, additive: false)
        live.pileGalleryID = pileID
        // Start the lifecycle clock once SwiftUI has actually mounted the gallery.
        // Setting the workspace state does not synchronously construct its overlay.
        for _ in 0..<150 {
            if CanvasPileGalleryProbeBridge.sessions[pileID] != nil { break }
            await pause(20)
        }
        check(CanvasPileGalleryProbeBridge.sessions[pileID] != nil, "Presentation mounts the actual gallery")
        await pause(35)
        let reduced = CanvasPileGalleryProbeBridge.reducedMotion[pileID] ?? false
        check(CanvasPileGalleryProbeBridge.sessions[pileID]?.phase == (reduced ? .open : .opening),
              "Presentation opening honors reduced motion")
        await pause(650)
        check(CanvasPileGalleryProbeBridge.sessions[pileID]?.phase == .open
              && live.inputRouter.blocksCanvasInput?() == true && canvas.selectedNodeIds == [pileID],
              "Presentation gallery owns modal input and preserves selection")
        if let pile = canvas.piles.first(where: { $0.id == pileID }) {
            let members = CanvasPileGeometry.members(pile, nodes: canvas.nodes)
            let source = CanvasPileGalleryProbeBridge.sources[pileID] ?? [:]
            let grid = CanvasPileGalleryProbeBridge.grids[pileID] ?? [:]
            check(Set(source.keys) == Set(members.map(\.id)) && Set(grid.keys) == Set(source.keys),
                  "Presentation source and grid retain every original member")
            check(members.allSatisfy { node in
                guard let a = source[node.id], let b = grid[node.id] else { return false }
                let size = CanvasPileGeometry.displaySize(node)
                return a.frame.size == CGSize(width: size.width * zoom, height: size.height * zoom)
                    && b.frame.size == CGSize(width: size.width * CanvasPileGeometry.galleryInitialZoom,
                                              height: size.height * CanvasPileGeometry.galleryInitialZoom)
                    && b.rotation == 0 && b.shade == 0
            }, "Presentation preserves per-member size from Pile into grid")
        } else { check(false, "Presentation retains the original Pile") }
        sample("presentation-gallery-open")
        check(live.handleKeyAction(.cancel), "Presentation Escape reaches the real workspace close handler")
        await pause(35)
        check(reduced ? live.pileGalleryID == nil
              : live.pileGalleryID == pileID && CanvasPileGalleryProbeBridge.sessions[pileID]?.phase == .closing,
              "Presentation reverse close retains the modal until animation completes")
        await pause(650)
        check(live.pileGalleryID == nil && CanvasPileGalleryProbeBridge.sessions[pileID] == nil,
              "Presentation reverse close releases gallery state")
        sample("presentation-gallery-closed")
        live.pileGalleryID = pileID
        await pause(20)
        NotificationCenter.default.post(name: .canvasPileGalleryCloseRequested, object: pileID)
        await pause(650)
        check(live.pileGalleryID == nil && CanvasPileGalleryProbeBridge.sessions[pileID] == nil,
              "Presentation close during opening cancels the stale completion")
        check(canvas.nodes == beforeNodes && canvas.edges == beforeEdges && canvas.piles == beforePiles
              && canvas.history.cursor == history && live.effectivePan == camera && live.zoom == zoom,
              "Presentation lifecycle preserves all data, history and camera")
        return observations
    }
}
#endif
