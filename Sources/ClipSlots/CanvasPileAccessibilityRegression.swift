#if DEBUG
import SwiftUI
import AppKit
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runPileAccessibilityProbe(directory: URL, pileID: String,
                                             check: (Bool, String) -> Void) async {
        var live: CanvasWorkspaceView { CanvasAgentGroupsProbeBridge.current ?? self }
        func settle() async { try? await Task.sleep(for: .milliseconds(650)) }
        guard let pile = canvas.piles.first(where: { $0.id == pileID }),
              let member = pile.memberIDs.first,
              let media = pile.memberIDs.first(where: { id in
                  canvas.node(id: id).map { live.previewableMedia(of: $0) != nil } ?? false
              }) else { check(false, "AX Pile fixture has ordinary and media members"); return }
        let nodes = canvas.nodes, edges = canvas.edges, piles = canvas.piles
        let history = canvas.history.cursor, camera = live.effectivePan, zoom = live.zoom
        canvas.select(id: pileID, additive: false)
        live.pileGalleryID = pileID
        await settle()
        check(await CanvasPileNativeButtonProbe.press("gallery-close", directory: directory),
              "AX discovers and presses the public Gallery close button")
        await settle()
        check(live.pileGalleryID == nil && canvas.nodes == nodes && canvas.edges == edges
              && canvas.piles == piles && canvas.history.cursor == history, "AX close preserves graph and undo history")
        live.pileGalleryID = pileID; await settle()
        check(await CanvasPileNativeButtonProbe.press("pile-preview-\(media)", directory: directory),
              "AX discovers and presses the public media preview button")
        await settle()
        check(canvas.selectedPile?.id == pileID, "AX media preview preserves Pile selection")
        check(live.handleKeyAction(.cancel) && live.pileGalleryID == pileID, "preview Escape returns to Gallery")
        live.requestPileGalleryClose(); await settle()
        live.pileGalleryID = pileID; await settle()
        check(await CanvasPileNativeButtonProbe.press("pile-extract-\(member)", directory: directory),
              "AX discovers and presses the public extraction button")
        await settle()
        check(live.pileGalleryID == nil && canvas.selectedNodeIds == [member]
              && canvas.history.cursor == history + 1 && canvas.edges == edges,
              "AX extraction commits one original-node transaction")
        let extracted = canvas.history.cursor == history + 1
        check(extracted && canvas.undo() != nil && canvas.nodes == nodes && canvas.edges == edges && canvas.piles == piles,
              "AX extraction undo restores every graph field")
        if !extracted { live.requestPileGalleryClose(); await settle() }
        check(live.effectivePan == camera && live.zoom == zoom, "AX Gallery actions preserve canvas camera")
    }
}
#endif
