#if DEBUG
import SwiftUI
import AppKit
import WebKit
import ClipSlotsKit

extension CanvasWorkspaceView {
    @MainActor func runTapNowMotionProbe(directory: URL) async {
        var passed = 0
        var failures: [String] = []
        func check(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failures.append(label) }
            NSLog("[TapNowMotion] \(condition ? "PASS" : "FAIL") \(label)")
        }
        func settle(_ seconds: Double = 0.38) async { try? await Task.sleep(for: .seconds(seconds)) }
        func screenshot(_ name: String, view: NSView? = nil) {
            guard let view = view ?? inputRouter.anchorView?.window?.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name+".png"))
        }
        canvas.isLibraryExpanded = false
        gridSnapEnabled = false
        pan = CGSize(width: 80, height: 60); zoom = 1
        guard let a = createNode(kind: .image, at: CGPoint(x: 380, y: 300), parentNodeId: nil,
                                  beginEditing: false, quiet: true),
              let b = createNode(kind: .image, at: CGPoint(x: 850, y: 300), parentNodeId: nil,
                                  beginEditing: false, quiet: true) else {
            failures.append("create isolated fixtures"); return
        }
        for node in [a,b] {
            canvas.updateNode(id: node.id) {
                $0.width = 250; $0.height = 250; $0.mediaRole = .generation
                $0.x = node.id == a.id ? 250 : 800; $0.y = 150
            }
        }
        guard let anchor = inputRouter.anchorView, let window = anchor.window else { return }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> Bool {
            guard let event = NSEvent.mouseEvent(with: type, location: anchor.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else { return false }
            return inputRouter.routeForRegression(event)
        }
        func selectSource() async {
            canvas.select(id: a.id, additive: false)
            hoverHoldNodeId = nil
            inputRouter.cursorPoint = CGPoint(x: 400,y: 300)
            await settle()
        }
        for scale in [CGFloat(0.5),1,1.5] {
            zoom = scale
            let source = canvas.node(id:a.id)!
            let frame = screenFrame(of:source)
            check(abs(outputPortHome(of:source).x-frame.maxX-37*scale)<0.001,
                  "plus home is 37 world units at \(scale)x")
            check(abs(edgeEndpoint(id:a.id,rect:frame,output:true).x-frame.maxX-3*scale)<0.001,
                  "edge endpoint is independently fixed at \(scale)x")
        }
        zoom = 1
        await selectSource()
        var home = outputPortHome(of:canvas.node(id:a.id)!)
        check(mouse(.leftMouseDown,home) && pointerSession?.linkPortPoint != nil && linkDrag == nil,
              "press captures plus while preview waits for drag threshold")
        _ = mouse(.leftMouseDragged,CGPoint(x:home.x+1,y:home.y))
        check(linkDrag == nil,"exact 1 pixel does not start connection")
        _ = mouse(.leftMouseDragged,CGPoint(x:home.x+2,y:home.y))
        check(linkDrag?.fromNodeId == a.id,"movement beyond 1 pixel begins connection")
        let sourceFrame = screenFrame(of:canvas.node(id:a.id)!)
        check(linkDrag?.start == CanvasEdgeGeometry.connectionAnchor(of:sourceFrame,output:true,zoom:zoom),
              "preview starts at fixed Handle rather than captured magnetic glyph")
        let body = CGPoint(x:screenFrame(of:canvas.node(id:b.id)!).midX,y:screenFrame(of:canvas.node(id:b.id)!).midY)
        _ = mouse(.leftMouseDragged,body)
        check(linkDrag?.targetNodeId == nil,"target body does not prematurely snap")
        _ = mouse(.leftMouseUp,body)
        check(canvas.edges.contains{$0.fromNodeId==a.id && $0.toNodeId==b.id},
              "body release fallback creates the intended edge")
        let count = canvas.edges.count
        _ = canvas.connect(from:b.id,to:a.id)
        check(canvas.edges.count==count+1,"observed image reverse cycle is permitted")
        check(canvas.undo() != nil && canvas.edges.count==count,"undo removes only reverse edge")
        await selectSource()
        let originalAnchor = edgeEndpoint(id:a.id,rect:sourceFrame,output:true)
        home = outputPortHome(of:canvas.node(id:a.id)!)
        let m=portMotions.motion(nodeID:a.id,output:true)
        m.update(cursor:CGPoint(x:home.x+20,y:home.y+12),home:home,output:true,zoom:1,now:10)
        check(m.offset(at:10.125).x>20,"first-follow easing overshoots")
        m.update(cursor:CGPoint(x:home.x+25,y:home.y+10),home:home,output:true,zoom:1,now:10.3)
        check(m.offset(at:10.3)==CGPoint(x:25,y:10),"follow after 250ms is immediate")
        check(edgeEndpoint(id:a.id,rect:sourceFrame,output:true)==originalAnchor,
              "magnet movement cannot change existing edge geometry")
        m.reset(now:11)
        check(m.offset(at:11.4) == .zero,"leave finishes 400ms return")
        m.clear()
        let highlight = CanvasPortMotion(ticksAutomatically: false)
        highlight.setVisible(true, now: 10)
        highlight.update(cursor: home, home: home, output: true, zoom: 1, now: 12)
        check(highlight.highlighted, "direct plus hover activates bright color")
        highlight.reset(now: 13)
        check(!highlight.highlighted, "leaving plus clears bright hover color")
        await selectSource()
        screenshot("fixed-edge-and-plus")

        let edge=canvas.edges.first!
        let otherFrame=screenFrame(of:canvas.node(id:b.id)!)
        let end=CanvasEdgeGeometry.connectionAnchor(of:otherFrame,output:false,zoom:1)
        let c=CanvasEdgeGeometry.controlPoints(start:originalAnchor,end:end,outSide:.right,inSide:.left)
        let middle=CanvasEdgeGeometry.point(start:originalAnchor,c1:c.0,c2:c.1,end:end,t:0.5)
        updateEdgeHover(at:middle)
        await settle(0.4)
        check(edgeHover.visible==nil,"scissors remains hidden before 800ms")
        await settle(0.45)
        check(edgeHover.visible?.edgeID==edge.id,"scissors appears after 800ms")
        screenshot("edge-scissors")
        _ = mouse(.leftMouseDown,middle); _ = mouse(.leftMouseUp,middle)
        check(canvas.edges.isEmpty,"scissors click disconnects edge")
        check(canvas.undo() != nil && canvas.edges.count==1,"scissors deletion is undoable")
        await selectSource()
        home=outputPortHome(of:canvas.node(id:a.id)!)
        _ = mouse(.leftMouseDown,home); _ = mouse(.leftMouseUp,home)
        check(addMenu?.parentNodeId==a.id && linkDrag==nil,"click plus opens referenced create menu")
        check(canvas.nodes.count==2 && canvas.edges.count==1,"pending command does not mutate persistent document")
        await settle()
        screenshot("plus-create-menu")
        addMenu=nil; cancelCanvasPointer()
        canvas.select(id:a.id,additive:false);canvas.select(id:b.id,additive:true)
        await settle()
        check(staticPortNodes.isEmpty,"multiselect force-hides individual plus")
        check(selectionJunction?.x==selectionScreenBounds?.maxX,"aggregate plus uses 12 screen-unit offset")
        screenshot("multiselect-plus")

        // The replica renderer receives isolated local test state, never a fake
        // task injected into the competitor or the user's persisted projects.
        let motionHost=NSHostingView(rootView:CanvasGenerationMotion(worldSize:CGSize(width:320,height:250),
            renderScale:1,hasMedia:false,reducedMotion:false).frame(width:320,height:250))
        let motionWindow=NSWindow(contentRect:CGRect(x:150,y:250,width:320,height:250),
                                  styleMask:[.titled],backing:.buffered,defer:false)
        motionWindow.isReleasedWhenClosed=false;motionWindow.contentView=motionHost
        motionWindow.makeKeyAndOrderFront(nil)
        await settle(1)
        func webViews(_ view:NSView)->[WKWebView] {
            (view as? WKWebView).map{[$0]} ?? view.subviews.flatMap(webViews)
        }
        if let web=webViews(motionHost).first {
            let result=try? await web.evaluateJavaScript("""
            (()=>{const e=document.querySelector('.node-loading-grid-stars'),s=getComputedStyle(e);
            return {dots:s.backgroundSize,animation:s.animationDuration,mask:s.maskImage,
              burst:getComputedStyle(document.querySelector('.node-loading-burst')).animationDuration,
              sweep:getComputedStyle(document.querySelector('.node-loading-grid-sweep')).animationDelay}})()
            """) as? [String:Any]
            check(result?["dots"] as? String == "18px 18px","actual WebKit renderer uses fixed 18-unit dots")
            check(result?["animation"] as? String == "96s","actual WebKit renderer uses 96s mask shimmer")
            check(result?["burst"] as? String == "2s","actual WebKit renderer uses one 2s burst")
            check((result?["sweep"] as? String)?.contains("2.5s")==true,"actual sweep delays 2.5s")
            screenshot("generation-burst",view:motionHost)
            await settle(2.1)
            screenshot("generation-sweep",view:motionHost)
        } else { check(false,"live WebKit generation renderer exists") }
        motionHost.rootView = CanvasGenerationMotion(worldSize: CGSize(width: 320, height: 250),
            renderScale: 1, hasMedia: false, reducedMotion: true).frame(width: 320, height: 250)
        await settle(0.5)
        if let web = webViews(motionHost).first {
            let reduced = try? await web.evaluateJavaScript("""
            (()=>{const s=getComputedStyle(document.querySelector('.node-loading-grid-stars'));
            return {mask:s.maskImage,alpha:s.opacity,animation:s.animationName,
              burst:getComputedStyle(document.querySelector('.node-loading-burst')).display}})()
            """) as? [String: Any]
            check(reduced?["mask"] as? String == "none" && reduced?["animation"] as? String == "none",
                  "reduced motion removes noise-mask animation")
            check(reduced?["alpha"] as? String == "0.35" && reduced?["burst"] as? String == "none",
                  "reduced motion retains 35 percent fixed stars and hides burst")
            screenshot("generation-reduced-motion", view: motionHost)
        }
        motionWindow.close()

        // Exercise the same owner used by the real card, including late output
        // and re-entry while an old fade or decoder is still in flight.
        func imageFixture(_ name: String, _ color: NSColor) -> SlotContent.SlotAttachment {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            color.setFill(); CGRect(x: 0, y: 0, width: 64, height: 64).fill()
            NSGraphicsContext.restoreGraphicsState()
            var att = SlotContent.SlotAttachment(name: name, type: .image)
            att.data = bitmap.representation(using: .png, properties: [:])
            return att
        }
        let oldImage = imageFixture("old.png", .systemPurple)
        let newImage = imageFixture("new.png", .systemTeal)
        let owner = CanvasGenerationHandoff()
        owner.update(busy: true, failed: false, image: oldImage, isImage: true, reducedMotion: false)
        let firstSession = owner.session
        check(owner.visible && owner.baseMedia?.id == oldImage.id, "generation saves old media on entry")
        owner.update(busy: true, failed: false, image: newImage, isImage: true, reducedMotion: false)
        check(owner.session == firstSession && owner.baseMedia?.id == oldImage.id,
              "queued-to-running update preserves generation session and old image")
        owner.update(busy: false, failed: false, image: oldImage, isImage: true, reducedMotion: false)
        await settle(0.2)
        check(owner.visible && owner.opacity == 1, "unchanged result keeps loading while waiting for late output")
        owner.update(busy: false, failed: false, image: newImage, isImage: true, reducedMotion: false)
        await settle(0.35)
        check(owner.prepared && owner.revealing && owner.opacity == 0,
              "decoded late image primes then reveals after two display turns")
        await settle(2.2)
        check(!owner.visible && !owner.prepared && owner.previousMedia == nil,
              "completed reveal removes old media and overlay")
        owner.update(busy: true, failed: false, image: oldImage, isImage: true, reducedMotion: false)
        owner.update(busy: false, failed: true, image: oldImage, isImage: true, reducedMotion: false)
        owner.update(busy: true, failed: false, image: newImage, isImage: true, reducedMotion: false)
        let rerun = owner.session
        await settle(1.5)
        check(owner.visible && owner.opacity == 1 && owner.session == rerun && owner.baseMedia?.id == newImage.id,
              "old failure fade cannot remove restarted generation")
        owner.update(busy: false, failed: false, image: newImage, isImage: true, reducedMotion: false)
        await settle(12.3)
        check(owner.opacity == 0, "task ending without new image uses 12 second fallback")
        await settle(1.45)
        check(!owner.visible, "fallback releases loading overlay")
        owner.update(busy: true, failed: false, image: oldImage, isImage: true, reducedMotion: true)
        var invalid = SlotContent.SlotAttachment(name: "corrupt.png", type: .image)
        invalid.data = Data("invalid image bytes".utf8)
        owner.update(busy: false, failed: false, image: invalid, isImage: true, reducedMotion: true)
        await settle(0.3)
        check(owner.imageFailed && !owner.revealing && owner.visible,
              "decode error offers retry without announcing successful reveal")
        owner.stop()
        await settle(0.25)
        check(!owner.visible && owner.baseMedia == nil, "leaving card cancels renderer and pending callbacks")

        var fixtureNode = canvas.node(id: a.id)!
        fixtureNode.width = 250; fixtureNode.height = 250; fixtureNode.state = .queued(ahead: 1)
        func card(_ node: CanvasNode, _ attachments: [SlotContent.SlotAttachment]) -> CanvasTapNodeCard {
            var produced = node
            produced.outputAttachmentIds = attachments.map { $0.id.uuidString }
            return CanvasTapNodeCard(node: produced, isSelected: false, isEditing: false, text: "local fixture",
                pathLabel: "本地隔离动画验证", attachments: attachments, renderScale: 1, textCounter: 1,
                viewZoom: 1, isHoverHeld: false, canArchive: false, inlinePlayback: inlinePlayback,
                onHoverChanged: { _ in }, onBeginEdit: {}, onCommitEdit: { _ in }, onCancelEdit: {},
                onOpenFullscreen: { _ in }, onArchive: {})
        }
        let cardHost = NSHostingView(rootView: card(fixtureNode, [oldImage]))
        let cardWindow = NSWindow(contentRect: CGRect(x: 150, y: 250, width: 250, height: 250),
            styleMask: [.titled], backing: .buffered, defer: false)
        cardWindow.isReleasedWhenClosed = false; cardWindow.contentView = cardHost
        cardWindow.makeKeyAndOrderFront(nil)
        await settle(1.7)
        check(!webViews(cardHost).isEmpty, "actual queued card mounts generation renderer")
        screenshot("card-generating-with-old-image", view: cardHost)
        fixtureNode.state = .running(startedAt: Date())
        cardHost.rootView = card(fixtureNode, [oldImage])
        await settle(0.3)
        check(!webViews(cardHost).isEmpty, "actual running card preserves generation renderer")
        fixtureNode.state = .idle
        cardHost.rootView = card(fixtureNode, [newImage])
        await settle(0.4)
        screenshot("card-image-reveal", view: cardHost)
        await settle(2.3)
        check(webViews(cardHost).isEmpty, "actual completed card releases generation WebView")
        screenshot("card-image-complete", view: cardHost)
        fixtureNode.state = .failed(reason: "本地测试：生成失败")
        cardHost.rootView = card(fixtureNode, [newImage])
        await settle(0.2)
        screenshot("card-generation-error", view: cardHost)
        cardWindow.close()
        let report:[String:Any]=["passed":passed,"failures":failures,"complete":true,
            "expectedCrateSubmissions":0,"systemInputValidated":false,
            "scope":"isolated AppKit event routing, world/screen geometry, original CSS rendered by WebKit; no paid competitor task",
            "target_generation_end_to_end_verified":false]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            .write(to:directory.appendingPathComponent("report.json"))
        NSApp.terminate(nil)
    }
}
#endif
