#if DEBUG
import AppKit
import ClipSlotsKit

@MainActor
func runHeaderMascotProbe(root:NSView,directory:URL,check:(Bool,String)->Void) async {
    func views(_ view:NSView) -> [HeaderMascotNativeView] {
        (view as? HeaderMascotNativeView).map { [$0] } ?? view.subviews.flatMap(views)
    }
    let matches=views(root).filter { !$0.isHiddenOrHasHiddenAncestor }
    check(matches.count==1,"Mascot exactly one native leaf in edit header")
    guard let mascot=matches.first else { return }
    check(mascot.bounds.size==NSSize(width:HeaderMascotView.canvasSide,height:HeaderMascotView.canvasSide),
          "Mascot header uses enlarged transparent canvas")
    check(mascot.accessibilityIdentifier()=="header-ip-mascot","Mascot accessible native button")
    let scene=HeaderMascotScene()
    check(scene.ready,"Mascot volumetric model and original laptop load")
    check(abs(scene.pixelsPerY-28.538486839707254)<0.00001 &&
          abs(scene.legPixels-10.308069221890811)<0.00001,"Mascot camera and leg projection use packaged source")
    var poses:[(String,MascotPose,MascotMotion.Activity)]=[]
    let engine=MascotMotion();engine.legPixels=scene.legPixels
    poses.append(("idle",engine.sample(at:0),.idle))
    engine.setHover(true,at:0)
    poses.append(("hover",engine.sample(at:360),.idle))
    engine.setDrag(true,at:500)
    poses.append(("drag",engine.sample(at:850),.idle))
    engine.reset(at:0); engine.setPointer(x:-500,y:100,at:0)
    for i in 0...100 { _=engine.sample(at:Double(i)*17) }
    poses.append(("look-left",engine.pose,.idle))
    engine.setPointer(x:500,y:-100,at:1800)
    for i in 0...100 { _=engine.sample(at:1800+Double(i)*17) }
    poses.append(("look-right",engine.pose,.idle))
    engine.reset(at:0); engine.random={0}; _=engine.sample(at:0); _=engine.sample(at:2000)
    poses.append(("blink",engine.sample(at:2050),.idle))
    for activity in [MascotMotion.Activity.busy,.superBusy,.voice,.waiting,.completed] {
        engine.setActivity(activity,at:0)
        poses.append((activity.rawValue,engine.sample(at:activity == .waiting ? 900 : 300),activity))
    }
    var hashes=Set<Data>()
    for (name,pose,activity) in poses {
        mascot.motion.setActivity(activity,at:0)
        guard let rep=mascot.render(pose,size:560),
              let data=rep.representation(using:.png,properties:[:]) else {
            check(false,"Mascot \(name) raster available"); continue
        }
        try? data.write(to:directory.appendingPathComponent("mascot-\(name).png"))
        hashes.insert(data)
        check(rep.pixelsWide==560 && rep.pixelsHigh==560,"Mascot \(name) native560px raster")
        check(mascot.geometryInsideFrustum,"Mascot \(name) complete model fits native camera")
        check(mascot.facialSurfaceValid,"Mascot \(name) eyes stay outside the face during deformation")
        let corners=[(0,0),(559,0),(0,559),(559,559)]
        check(corners.allSatisfy { (rep.colorAt(x:$0.0,y:$0.1)?.alphaComponent ?? 1)<0.01 },
              "Mascot \(name) transparent corners")
    }
    check(hashes.count >= 9,"Mascot states render distinct IP expressions and movement")
    for yaw in [-65.0,0,65] {
        for pitch in [-30.0,30] {
            for blink in [0.0,0.5,1] {
                var pose=MascotPose();pose.yaw=yaw;pose.pitch=pitch;pose.blink=blink
                let rep=scene.render(pose,size:208,activity:.idle)
                check(rep != nil && scene.geometryInsideFrustum && scene.facialSurfaceValid,
                    "Mascot extreme yaw\(yaw) pitch\(pitch) blink\(blink) retains a valid face")
            }
        }
    }
    var permissionReply: CheckedContinuation<Bool,Never>?
    var microphoneRequests=0,textCallbacks=0
    let pendingVoice=AgentVoiceInput(speechPermission: {
        await withCheckedContinuation { permissionReply=$0 }
    },microphonePermission: { microphoneRequests+=1;return false })
    pendingVoice.start { _ in textCallbacks+=1 }
    for _ in 0..<20 {
        if permissionReply != nil { break }
        try? await Task.sleep(for:.milliseconds(5))
    }
    check(pendingVoice.isStarting && !pendingVoice.isRecording,
          "Voice pending authorization is visible and cancellable")
    pendingVoice.stop()
    permissionReply?.resume(returning:true);permissionReply=nil
    try? await Task.sleep(for:.milliseconds(20))
    check(!pendingVoice.isStarting && !pendingVoice.isRecording && microphoneRequests==0 && textCallbacks==0,
          "Voice late authorization after stop cannot start microphone or edit draft")
    let deniedVoice=AgentVoiceInput(speechPermission:{true},microphonePermission:{false})
    deniedVoice.start { _ in textCallbacks+=1 }
    for _ in 0..<20 {
        if deniedVoice.error != nil { break }
        try? await Task.sleep(for:.milliseconds(5))
    }
    check(!deniedVoice.isStarting && !deniedVoice.isRecording && deniedVoice.error?.contains("麦克风")==true,
          "Voice denied microphone releases starting state with actionable feedback")
    check(!AgentVoiceInput.anyRecording && AgentVoiceInput.recordingLevel==0,
          "Voice cancelled and denied sessions leave no global recording activity")
    mascot.motion.reset(at:ProcessInfo.processInfo.systemUptime*1000)
    mascot.motion.setActivity(.idle,at:ProcessInfo.processInfo.systemUptime*1000)
    check(mascot.hitTest(NSPoint(x:1,y:1)) == nil,"Mascot alpha padding passes through input")
    let saved=mascot.onToggle
    var toggles=0; mascot.onToggle={toggles+=1}
    check(mascot.accessibilityPerformPress() && toggles==1,"Mascot native press calls Agent toggle once")
    if let window=mascot.window {
        let before=Set((window.childWindows ?? []).map(\.windowNumber))
        let start=mascot.convert(NSPoint(x:mascot.bounds.midX,y:mascot.bounds.midY),to:nil)
        let end=NSPoint(x:start.x+140,y:start.y-80)
        let cursor=NSEvent.mouseLocation
        func event(_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent {
            NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],
                timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,
                context:nil,eventNumber:0,clickCount:1,pressure:1)!
        }
        mascot.mouseDown(with:event(.leftMouseDown,start))
        mascot.mouseDragged(with:event(.leftMouseDragged,end))
        mascot.mouseUp(with:event(.leftMouseUp,end))
        let floating=(window.childWindows ?? []).first { !before.contains($0.windowNumber) }
        check(cursor==NSEvent.mouseLocation,"Mascot posted drag does not need global cursor movement")
        check(floating != nil && toggles==1,"Mascot window drag creates floating panel without Agent toggle")
        let retained=floating?.frame
        try? await Task.sleep(for:.milliseconds(180))
        check(floating?.frame==retained && floating?.isVisible==true,
              "Mascot released drag remains at event position")
        _=mascot.perform(NSSelectorFromString("returnHome"))
        check(Set((window.childWindows ?? []).map(\.windowNumber))==before,
              "Mascot return home removes only its floating panel")
    } else {
        check(false,"Mascot event drag has a hosting window")
    }
    mascot.onToggle=saved
    mascot.isHidden=true
    try? await Task.sleep(for:.milliseconds(70))
    let count=mascot.renderCount
    try? await Task.sleep(for:.milliseconds(100))
    check(mascot.renderCount==count && !mascot.activeTimer,"Mascot hidden leaf parks renderer and timer")
    mascot.isHidden=false
    try? await Task.sleep(for:.milliseconds(100))
    check(mascot.renderCount>count,"Mascot unhide resumes with fresh raster")
    let activityRoot=directory.appendingPathComponent("mascot-activity-state")
    let canvas=CanvasStore(storage:CanvasStorage(rootOverride:activityRoot),
        projectStorage:CanvasProjectStorage(rootOverride:activityRoot))
    let node=canvas.placeSlot(pageId:"mascot-fixture",groupId:"mascot-fixture",slot:1,
        name:"隔离状态检查",at:CGPoint(x:100,y:100)).node
    for (state,expected) in [(CanvasNodeState.running(startedAt:Date()),MascotMotion.Activity.busy),
        (.queued(ahead:2),.waiting),(.failed(reason:"fixture"),.failed),(.idle,.idle)] {
        canvas.updateNode(id:node.id) { $0.state=state }
        let model=AgentChatModel(displayName:"角色状态检查",backend:HeaderMascotFixtureBackend())
        let view=HeaderMascotNativeView(frame:NSRect(x:0,y:0,width:104,height:104))
        view.bind(model:model,canvas:canvas)
        check(view.motion.activity==expected,"Mascot binding immediately adopts existing \(expected.rawValue) state")
        view.dispose()
    }
}

private final class HeaderMascotFixtureBackend:AgentBackend,@unchecked Sendable {
    func run(history:[AgentMessage],config:AgentConfig,tools:AgentToolExecuting?,
             onEvent:@escaping @Sendable (AgentRunEvent) async -> Void) async throws -> [AgentMessage] {
        throw CancellationError()
    }
}
#endif
