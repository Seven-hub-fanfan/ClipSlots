#if DEBUG
import AppKit
import SwiftUI
import ClipSlotsKit

@MainActor
func runHeaderMascotProbe(root:NSView,directory:URL,check:(Bool,String)->Void) async {
    // Hold completions as a deliberately stalled GPU. Hundreds of UI samples
    // must stay bounded and only the latest pose may start after it recovers.
    var launched:[Int]=[],presented:[Int]=[]
    var completions:[MascotFrameScheduler.Completion]=[]
    let frame=MascotRenderedFrame(bitmap:nil,geometryInsideFrustum:true,facialSurfaceValid:true)
    var scheduler:MascotFrameScheduler?=MascotFrameScheduler(render: { request, completion in
        launched.append(request.size);completions.append(completion)
    },present: { request,_ in presented.append(request.size) })
    for size in 128...400 {
        scheduler?.submit(MascotFrameRequest(pose:MascotPose(),size:size,activity:.idle))
    }
    check(launched==[128] && scheduler?.inFlight==true && scheduler?.coalesced==271,
          "Mascot stalled renderer keeps one in flight and coalesces 272 pending samples")
    completions.removeFirst()(frame)
    check(launched==[128,400] && presented==[128],
          "Mascot resumed renderer skips obsolete intermediate poses")
    scheduler?.invalidate()
    scheduler?.submit(MascotFrameRequest(pose:MascotPose(),size:560,activity:.busy))
    completions.removeFirst()(frame)
    check(launched==[128,400,560] && presented==[128] && scheduler?.discarded==1,
          "Mascot resize or activity generation rejects the older completed raster")
    scheduler?.invalidate()
    scheduler?.submit(MascotFrameRequest(pose:MascotPose(),size:561,activity:.voice))
    scheduler?.invalidate()
    completions.removeFirst()(frame)
    check(launched==[128,400,560] && presented==[128] && scheduler?.inFlight==false,
          "Mascot hiding cancels the pending pose and discards the in-flight completion")
    scheduler?.submit(MascotFrameRequest(pose:MascotPose(),size:562,activity:.idle))
    completions.removeFirst()(frame)
    check(presented==[128,562],"Mascot unhide accepts a fresh generation")
    scheduler?.submit(MascotFrameRequest(pose:MascotPose(),size:563,activity:.idle))
    weak var released=scheduler
    scheduler=nil
    completions.removeFirst()(frame)
    check(released==nil && presented==[128,562],
          "Mascot in-flight completion cannot retain or revive a disposed scheduler")
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
    check(scene.ready,"Mascot volumetric model and MacBook load")
    check(scene.computerGaze.pitch>15 && scene.computerGaze.pitch<=30 &&
          abs(scene.computerGaze.yaw)<15,"Mascot resting eye ray aims toward the upper MacBook screen")
    let logos=scene.model.childNodes.filter {
        $0.name=="macbook-apple-logo" || $0.name=="macbook-apple-leaf"
    }
    check(logos.count==2,"Mascot light preserves separate Apple body and leaf meshes")
    for level in [0.18,0.55,1.0] {
        var pose=MascotPose();pose.logoIntensity=level
        _=scene.render(pose,size:208,activity:.idle)
        check(logos.allSatisfy {
            abs(Double($0.geometry?.firstMaterial?.emission.intensity ?? -1)-level)<0.00001 &&
            ($0.geometry?.firstMaterial?.emission.contents as? NSColor)==NSColor.white
        },"Mascot both Apple logo surfaces emit white at \(level)")
    }
    check(abs(scene.pixelsPerY-28.538486839707254)<0.00001 &&
          abs(scene.legPixels-10.308069221890811)<0.00001,"Mascot camera and leg projection use packaged source")
    let headset=scene.head.childNodes.filter { ($0.name ?? "").hasPrefix("voice-airpodsmax-") }
    check(headset.contains { $0.name=="voice-airpodsmax-earcup-left" } &&
          headset.contains { $0.name=="voice-airpodsmax-earcup-right" },
          "Mascot AirPods Max has two rounded aluminium earcups")
    check(headset.contains { $0.name=="voice-airpodsmax-digital-crown" } &&
          headset.contains { ($0.name ?? "").hasPrefix("voice-airpodsmax-knit-cross-") },
          "Mascot AirPods Max has crown control and a knitted canopy")
    _=scene.render(MascotPose(),size:208,activity:.voice)
    check(headset.allSatisfy { !$0.isHidden && $0.parent===scene.head },
          "Mascot headset shares the complete animated head transform")
    _=scene.render(MascotPose(),size:208,activity:.idle)
    check(headset.allSatisfy(\.isHidden),"Mascot headset keeps voice activity visibility")
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
                check(scene.neckAttachmentValid && scene.headBodyClearanceValid && scene.neckSurfaceValid,
                    "Mascot extreme yaw\(yaw) pitch\(pitch) has a continuous neck and shoulder clearance")
            }
        }
    }
    // Reproduce low/high pointer sweeps through full authored activity cycles.
    // Assert the rendered deformation, not merely the input pose limits.
    for activity in [MascotMotion.Activity.idle,.busy,.superBusy,.voice] {
        for frame in 0..<12 {
            var pose=MascotPose()
            pose.yaw=65*sin(Double(frame) * .pi/6)
            pose.pitch=30*cos(Double(frame) * .pi/6)
            pose.activityFrame=frame*6;pose.activityProgress=0.5
            pose.voiceLevel=frame%2==0 ? 0 : 1
            let rep=scene.render(pose,size:104,activity:activity)
            check(rep != nil && scene.neckAttachmentValid && scene.headBodyClearanceValid && scene.neckSurfaceValid &&
                scene.geometryInsideFrustum && scene.facialSurfaceValid,
                "Mascot \(activity.rawValue) low-head continuous sample \(frame) remains attached")
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
    if let window=mascot.window {
        let previous=window.firstResponder
        let editor=AgentDraftEditor.Editor(frame:NSRect(x:16,y:16,width:240,height:64))
        editor.isEditable=true;editor.string="帮我生成一段运镜提示词"
        root.addSubview(editor)
        // LaunchServices performs a real OS activation. On macOS 14+ an
        // in-process activate request may be denied after briefly setting
        // app-local state; that is not a valid focused-editor fixture.
        let activation=NSWorkspace.OpenConfiguration()
        activation.activates=true
        _=try? await NSWorkspace.shared.openApplication(at:Bundle.main.bundleURL,configuration:activation)
        window.makeKeyAndOrderFront(nil)
        var focusedSince:Double?
        for _ in 0..<40 {
            if NSApp.isActive && window.isKeyWindow &&
               NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                focusedSince=focusedSince ?? ProcessInfo.processInfo.systemUptime
                if ProcessInfo.processInfo.systemUptime-(focusedSince ?? 0)>=0.3 { break }
            } else { focusedSince=nil }
            try? await Task.sleep(for:.milliseconds(25))
        }
        check(focusedSince != nil && NSApp.isActive && window.isKeyWindow &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
            "Mascot editor fixture has stable actual OS foreground focus")
        check(window.makeFirstResponder(editor),"Mascot focus fixture uses the native Agent draft editor")
        editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0))
        mascot.motion.setActivity(.idle,at:ProcessInfo.processInfo.systemUptime*1000)
        mascot.refreshPromptFocus()
        NSLog("[MascotFocusFixture] active=\(NSApp.isActive) key=\(window.isKeyWindow) responder=\(String(describing:window.firstResponder)) editable=\(editor.isEditable) hidden=\(editor.isHiddenOrHasHiddenAncestor) mascotWindow=\(mascot.window === window) visible=\(mascot.optimizationDiagnostics["visible"] ?? false)")
        check(mascot.motion.editingPrompt,"Mascot captures actual editable first responder")
        try? await Task.sleep(for:.milliseconds(900))
        for step in 0..<20 {
            let point=NSPoint(x:step%2==0 ? 20 : root.bounds.maxX-20,
                              y:step%3==0 ? 20 : root.bounds.maxY-20)
            if let event=NSEvent.mouseEvent(with:.mouseMoved,location:root.convert(point,to:nil),
                modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0) {
                mascot.mouseMoved(with:event)
            }
            try? await Task.sleep(for:.milliseconds(20))
        }
        NSLog("[MascotFocusFixture] after pointer active=\(NSApp.isActive) key=\(window.isKeyWindow) foreground=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") responderSame=\(window.firstResponder === editor) editing=\(mascot.motion.editingPrompt) yaw=\(mascot.motion.pose.yaw) pitch=\(mascot.motion.pose.pitch) expected=\(scene.computerGaze)")
        check(mascot.motion.editingPrompt &&
            abs(mascot.motion.pose.yaw-scene.computerGaze.yaw)<0.05 &&
            abs(mascot.motion.pose.pitch-scene.computerGaze.pitch)<0.05,
            "Mascot native focused prompt remains looking at laptop through pointer events")
        window.makeFirstResponder(nil);mascot.refreshPromptFocus()
        check(!mascot.motion.editingPrompt,"Mascot native editor blur releases the screen gaze")
        editor.removeFromSuperview()
        let host=NSHostingView(rootView:CanvasPromptEditor(text:.constant("画布提示词"),
            font:.systemFont(ofSize:14),onCommit:{},onCancel:{},onBlur:{},autoFocus:false))
        host.frame=NSRect(x:16,y:16,width:240,height:80);root.addSubview(host)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for:.milliseconds(40))
        func promptEditors(_ view:NSView)->[NSTextView] {
            (CanvasPromptEditor.owns(view) ? [view as! NSTextView] : [])+view.subviews.flatMap(promptEditors)
        }
        if let prompt=promptEditors(host).first {
            check(window.makeFirstResponder(prompt),"Mascot canvas prompt fixture uses its actual native editor")
            prompt.setMarkedText("ceshi",selectedRange:NSRange(location:5,length:0),
                                 replacementRange:NSRange(location:NSNotFound,length:0))
            mascot.refreshPromptFocus()
            NSLog("[MascotFocusFixture] canvas active=\(NSApp.isActive) key=\(window.isKeyWindow) responderSame=\(window.firstResponder === prompt) editing=\(mascot.motion.editingPrompt) marked=\(prompt.hasMarkedText()) editable=\(prompt.isEditable) hidden=\(prompt.isHiddenOrHasHiddenAncestor)")
            check(mascot.motion.editingPrompt && prompt.hasMarkedText(),
                  "Mascot canvas prompt focus retains Chinese input method marked text")
            window.makeFirstResponder(nil);mascot.refreshPromptFocus()
            check(!mascot.motion.editingPrompt,"Mascot canvas prompt blur releases fixed gaze")
        } else { check(false,"Mascot native canvas prompt editor is mounted") }
        host.removeFromSuperview()
        if let previous { window.makeFirstResponder(previous) }
        mascot.refreshPromptFocus()
        var latencyMS:[Double]=[]
        for index in 0..<20 {
            let point=NSPoint(x:index%2==0 ? 20 : root.bounds.maxX-20,y:root.bounds.midY)
            let started=ProcessInfo.processInfo.systemUptime*1000
            if let event=NSEvent.mouseEvent(with:.mouseMoved,location:root.convert(point,to:nil),
                modifierFlags:[],timestamp:started/1000,windowNumber:window.windowNumber,
                context:nil,eventNumber:0,clickCount:0,pressure:0) {
                mascot.mouseMoved(with:event)
                for _ in 0..<200 {
                    if (mascot.optimizationDiagnostics["displayIssuedAtMS"] as? Double ?? 0)>=started {
                        latencyMS.append(ProcessInfo.processInfo.systemUptime*1000-started);break
                    }
                    try? await Task.sleep(for:.milliseconds(5))
                }
            }
        }
        let ordered=latencyMS.sorted()
        let p95=ordered.count==20 ? ordered[18] : Double.infinity
        let latency:[String:Any]=["samples_ms":latencyMS,"p95_ms":p95.isFinite ? p95 : -1,
            "scope":"posted native pointer event to a presented frame submitted after that event",
            "physical_input_or_display_scanout_measured":false]
        try? JSONSerialization.data(withJSONObject:latency,options:[.prettyPrinted,.sortedKeys])
            .write(to:directory.appendingPathComponent("event-latency.json"))
        check(latencyMS.count==20,"Mascot every posted pointer event receives a new rendered frame")
        check(p95<=50,"Mascot posted pointer event to new rendered frame P95 at most 50ms")
    } else { check(false,"Mascot prompt-focus fixture has a hosting window") }
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
    for _ in 0..<40 {
        if mascot.renderCount>count { break }
        try? await Task.sleep(for:.milliseconds(25))
    }
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
        check(view.motion.agentWorking == (expected == .busy || expected == .waiting),
              "Mascot \(expected.rawValue) binding drives the working logo independently")
        if expected == .busy || expected == .waiting {
            let pose=view.motion.sample(at:ProcessInfo.processInfo.systemUptime*1000+1000)
            check(pose.logoIntensity==1 && pose.opacity==1,
                  "Mascot native \(expected.rawValue) binding keeps the emitted logo fully visible")
        }
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
