import AppKit
import SwiftUI
import Combine
import ClipSlotsKit

struct HeaderMascotView: NSViewRepresentable {
    static let canvasSide: CGFloat = 124
    let model: AgentChatModel
    let canvas: CanvasStore
    let onToggle: () -> Void
    func makeNSView(context: Context) -> HeaderMascotNativeView {
        let view=HeaderMascotNativeView(frame:NSRect(x:0,y:0,width:Self.canvasSide,height:Self.canvasSide))
        view.bind(model:model,canvas:canvas); view.onToggle=onToggle
        return view
    }
    func updateNSView(_ view: HeaderMascotNativeView, context: Context) {
        view.bind(model:model,canvas:canvas); view.onToggle=onToggle
    }
    static func dismantleNSView(_ view: HeaderMascotNativeView, coordinator: ()) { view.dispose() }
}

@MainActor
final class HeaderMascotNativeView: NSView, HeaderMascotRenderOwner {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    let motion=MascotMotion()
    private var service:HeaderMascotRenderService?
    private var renderer:HeaderMascotRenderer {
        if service == nil { service=HeaderMascotRenderService();service?.attach(self) }
        return service!.renderer
    }
    private var frames:MascotFrameScheduler { _=renderer;return service!.frames }
    private let atlas=HeaderMascotLampAtlas()
    private let lamp=HeaderMascotLampPlayer()
    private let floatingLamp=HeaderMascotLampPlayer()
    private var buildSubmitted=false
    private var lastBuildMS=0.0
    private var presentedPose:MascotPose?
    #if DEBUG
    private var displayIssuedAtMS=0.0
    #endif
    private var displayWasLamp=false
    private var dormant=true
    private var failedFrames=0
    private var wakeDeadline=MascotEarliestWake()
    private var budgetObserver:UUID?
    private var sessionSubscriber:AnyCancellable?
    private var constrained=false
    private var constrainedRecovery:Double?
    private var lastHealthMS=0.0
    private var fallbackPolling=false
    private var lastPointerEventMS=0.0
    private var globalPointerMonitor:Any?
    private var scheduledActivity:MascotMotion.Activity?
    private var scheduledSize:Int?
    var onToggle: () -> Void = {}
    private var subscribers=Set<AnyCancellable>()
    private var boundModel: ObjectIdentifier?
    private var boundCanvas: ObjectIdentifier?
    private var notifications: [NSObjectProtocol]=[]
    private var pointerMonitor: Any?
    private var timer: Timer?
    private var tracking: NSTrackingArea?
    private var bitmap: NSBitmapImageRep?
    private var entryBitmap: NSBitmapImageRep?
    private var lastPose: MascotPose?
    private var pressedAt: NSPoint?
    private var moved=false
    private var dragPanel: NSPanel?
    private var detachedView:HeaderMascotFloatingView?
    private var dragOffset=NSPoint.zero
    private var disposed=false
    private var listening=false
    private var running=false
    private var waiting=false
    private var failed=false
    private var canvasRunning=false
    private var canvasFailed=false
    private var canvasWaiting=false
    private var phase=AgentChatModel.RunPhase.idle
    private var previousNodeStates: [String:CanvasNodeState]=[:]
    private var muted:Bool { HeaderMascotSessionState.shared.paused }
    private var lastTick=0.0
    private var lastCursor:NSPoint?
    private var voiceTrace:[[String:Any]]=[]
    private var lastVoiceTraceTime=0.0
    private(set) var frameCount=0
    private(set) var renderCount=0
    private(set) var activeTimer=false
    private(set) var geometryInsideFrustum=true
    private(set) var facialSurfaceValid=true
    private var now: Double { ProcessInfo.processInfo.systemUptime*1000 }
    private var rasterSide:Int {
        max(128,Int(ceil(bounds.width*(window?.backingScaleFactor ?? 2))))
    }

    override init(frame frameRect:NSRect) {
        super.init(frame:frameRect)
        wantsLayer=true
        layer?.addSublayer(lamp.layer)
        sessionSubscriber=HeaderMascotSessionState.shared.$paused.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.invalidateDisplay();self?.refreshVisibility() }
        }
        budgetObserver=ResourceBudget.shared.observe { [weak self] in
            Task { @MainActor in self?.wake() }
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("斗篷小助手")
        setAccessibilityIdentifier("header-ip-mascot")
        setAccessibilityHelp("点击开关项目 Agent；悬停、拖动与右键可互动")
        let center=NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification,NSApplication.didResignActiveNotification,
                     NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification,NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification,NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification,NSWindow.didChangeBackingPropertiesNotification,
                     ProcessInfo.thermalStateDidChangeNotification] {
            notifications.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibility() }
            })
        }
        notifications.append(center.addObserver(forName:AgentVoiceInput.activityChangedNotification,
            object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {
                    let wasListening=self?.listening == true
                    self?.listening=AgentVoiceInput.anyRecording
                    self?.motion.setVoiceLevel(AgentVoiceInput.recordingLevel)
                    self?.updateActivity()
                    if wasListening && !AgentVoiceInput.anyRecording { self?.saveVoiceTrace() }
                }
            })
        notifications.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName:NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object:nil,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            })
        notifications.append(center.addObserver(forName:NSTextView.didChangeSelectionNotification,
            object:nil,queue:.main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let editor=note.object as? NSTextView,
                          editor.window === self.window else { return }
                    self.refreshPromptFocus()
                }
            })
        notifications.append(center.addObserver(forName:NSWindow.didUpdateNotification,
            object:nil,queue:.main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self,note.object as? NSWindow === self.window else { return }
                    self.refreshPromptFocus()
                }
            })
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func bind(model:AgentChatModel,canvas:CanvasStore) {
        guard boundModel != ObjectIdentifier(model) || boundCanvas != ObjectIdentifier(canvas) else { return }
        boundModel=ObjectIdentifier(model); boundCanvas=ObjectIdentifier(canvas)
        subscribers.removeAll()
        running=model.isRunning || model.isPolishing
        waiting = !model.pendingInteractions.isEmpty
        failed=model.errorText != nil && !running
        phase=model.runPhase
        model.$isRunning.combineLatest(model.$isPolishing).removeDuplicates { $0 == $1 }
            .receive(on:RunLoop.main).sink { [weak self] values in
                self?.running=values.0 || values.1; self?.updateActivity()
            }.store(in:&subscribers)
        model.$pendingInteractions.map { !$0.isEmpty }.removeDuplicates()
            .receive(on:RunLoop.main).sink { [weak self] value in
                self?.waiting=value; self?.updateActivity()
            }.store(in:&subscribers)
        model.$errorText.map { $0 != nil }.removeDuplicates().receive(on:RunLoop.main)
            .sink { [weak self] value in self?.failed=value; self?.updateActivity() }.store(in:&subscribers)
        model.$runPhase.removeDuplicates().receive(on:RunLoop.main).sink { [weak self] value in
            guard let self else { return }
            let completed=value == .applied && self.phase != .applied
            self.phase=value
            self.updateActivity(completed:completed)
        }.store(in:&subscribers)
        previousNodeStates=Dictionary(uniqueKeysWithValues:canvas.nodes.map { ($0.id,$0.state) })
        canvasRunning=canvas.nodes.contains { if case .running = $0.state { return true }; return false }
        canvasWaiting=canvas.nodes.contains { if case .queued = $0.state { return true }; return false }
        canvasFailed=canvas.nodes.contains { if case .failed = $0.state { return true }; return false }
        canvas.nodeChanges.receive(on:RunLoop.main).sink { [weak self] nodes in
            guard let self else { return }
            var busy=false, queued=false, failure=false, completed=false
            for node in nodes {
                if case .running = node.state { busy=true }
                if case .queued = node.state { queued=true }
                if case .failed = node.state { failure=true }
                if case .running? = self.previousNodeStates[node.id],
                   case .succeeded = node.state { completed=true }
            }
            let changed=busy != self.canvasRunning || queued != self.canvasWaiting ||
                failure != self.canvasFailed || completed
            self.previousNodeStates=Dictionary(uniqueKeysWithValues:nodes.map { ($0.id,$0.state) })
            self.canvasRunning=busy; self.canvasFailed=failure
            self.canvasWaiting=queued
            if changed { self.updateActivity(completed:completed) }
        }.store(in:&subscribers)
        listening=AgentVoiceInput.anyRecording
        motion.setVoiceLevel(AgentVoiceInput.recordingLevel)
        updateActivity()
    }
    private func updateActivity(completed:Bool=false) {
        prepareInput()
        motion.setAgentWorking(running || waiting || canvasRunning || canvasWaiting,at:now)
        let activity:MascotMotion.Activity
        if listening { activity = .voice }
        else if (running && !waiting) || canvasRunning { activity = .busy }
        else if waiting || canvasWaiting { activity = .waiting }
        else if failed || canvasFailed || phase == .failed { activity = .failed }
        else if completed { activity = .completed }
        else if motion.activity == .completed { wake(); return }
        else { activity = .idle }
        if motion.activity == .superBusy && activity == .busy { wake(); return }
        motion.setActivity(activity,at:now)
        setAccessibilityValue(activity.rawValue)
        wake()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            let next=HeaderMascotRenderService.forWindow(window)
            if service !== next {
                service?.detach(self);service=next;next.attach(self)
                atlas.clear();buildSubmitted=false;presentedPose=nil;lastPose=nil
            }
            motion.legPixels=renderer.legPixels
            motion.computerGaze=renderer.computerGaze
            motion.pointerProjection={ [weak self] x,y in self?.renderer.pointer(x:x,y:y) ?? (0,0) }
        } else { service?.detach(self) }
        refreshVisibility()
        #if DEBUG
        HeaderMascotOptimizationProbe.start(self)
        #endif
    }
    override func viewDidHide() { super.viewDidHide(); refreshVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshVisibility() }
    private var visible:Bool {
        !disposed && !isHiddenOrHasHiddenAncestor && !NSApp.isHidden &&
        window != nil && ((window!.isVisible && !window!.isMiniaturized &&
        window!.occlusionState.contains(.visible)) ||
        (dragPanel?.isVisible == true && dragPanel?.occlusionState.contains(.visible) == true))
    }
    private var screenCenter:NSPoint {
        guard let window else { return .zero }
        return window.convertToScreen(convert(NSRect(x:bounds.midX,y:bounds.midY,width:0,height:0),to:nil)).origin
    }
    private var interactionCenter:NSPoint {
        dragPanel.map { NSPoint(x:$0.frame.midX,y:$0.frame.midY) } ?? screenCenter
    }
    private func refreshVisibility() {
        if visible {
            motion.setAgentWorking(running || waiting || canvasRunning || canvasWaiting,at:now)
            refreshPromptFocus()
            if pointerMonitor == nil,NSApp.isActive,!muted {
                pointerMonitor=NSEvent.addLocalMonitorForEvents(matching:[.mouseMoved,.leftMouseDragged]) { [weak self] event in
                    MainActor.assumeIsolated {
                        if let self,(event.window === self.window || event.window === self.dragPanel),
                           self.visible,self.pressedAt == nil {
                            self.lastPointerEventMS=self.now
                            self.follow(event)
                        }
                    }
                    return event
                }
                window?.acceptsMouseMovedEvents=true
                globalPointerMonitor=NSEvent.addGlobalMonitorForEvents(matching:.mouseMoved) { [weak self] _ in
                    Task { @MainActor in
                        guard let self,self.visible,NSApp.isActive,!self.muted,self.pressedAt==nil else { return }
                        self.lastPointerEventMS=self.now
                        self.updatePointer(at:NSEvent.mouseLocation)
                    }
                }
                fallbackPolling=pointerMonitor==nil || globalPointerMonitor==nil
            }
            if !NSApp.isActive || muted {
                removePointerMonitors()
                prepareInput();motion.setHover(false,at:now);entryBitmap=nil
                if lastCursor != nil {
                    prepareInput();lastCursor=nil;motion.setPointer(x:nil,y:nil,at:now)
                }
            } else if lastCursor == nil {
                pollCursor()
            }
            wake()
        } else {
            stopTimer()
            invalidateDisplay();removePointerMonitors();lastCursor=nil
            dragPanel?.orderOut(nil);pressedAt=nil;dormant=true
            motion.setPointer(x:nil,y:nil,at:now)
            motion.setHover(false,at:now);motion.setDrag(false,at:now)
            lastPose=nil;entryBitmap=nil
        }
    }
    private func removePointerMonitors() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor);self.pointerMonitor=nil }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor);self.globalPointerMonitor=nil }
        fallbackPolling=false
    }
    private func invalidateDisplay() {
        if displayWasLamp,let frozen=atlas.presentationBitmap(timeMS:now) {
            bitmap=frozen;needsDisplay=true;detachedView?.needsDisplay=true
        }
        service?.frames.invalidate();lamp.stop();floatingLamp.stop()
        displayWasLamp=false;lastPose=nil;presentedPose=nil;buildSubmitted=false;failedFrames=0
    }
    func dispose() {
        disposed=true; stopTimer(); subscribers.removeAll()
        invalidateDisplay();service?.detach(self);service=nil
        atlas.clear();sessionSubscriber=nil
        if let budgetObserver { ResourceBudget.shared.removeObserver(budgetObserver) }
        budgetObserver=nil
        notifications.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }; notifications=[]
        removePointerMonitors()
        dragPanel?.orderOut(nil); dragPanel=nil
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking=NSTrackingArea(rect:.zero,options:[.inVisibleRect,.mouseEnteredAndExited,.mouseMoved,.activeInActiveApp],owner:self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    private func alphaHit(_ point:NSPoint, rep:NSBitmapImageRep?) -> Bool {
        guard bounds.contains(point), let rep, bounds.width>0, bounds.height>0 else { return false }
        let x=min(rep.pixelsWide-1,max(0,Int(point.x/bounds.width*CGFloat(rep.pixelsWide))))
        let y=min(rep.pixelsHigh-1,max(0,Int(point.y/bounds.height*CGFloat(rep.pixelsHigh))))
        return (rep.colorAt(x:x,y:y)?.alphaComponent ?? 0)*255 >= 16
    }
    override func hitTest(_ point:NSPoint) -> NSView? {
        let local=convert(point,from:superview)
        return alphaHit(local,rep:bitmap) ? self : nil
    }
    private func follow(_ event:NSEvent) {
        updatePointer(at:eventScreenPoint(event))
    }
    private func updatePointer(at mouse:NSPoint) {
        guard visible,!muted,NSApp.isActive,mouse != lastCursor else { return }
        prepareInput();lastCursor=mouse
        refreshPromptFocus()
        let origin=interactionCenter
        let dx=mouse.x-origin.x,dy=origin.y-mouse.y
        let local=NSPoint(x:bounds.midX+dx,y:bounds.midY+dy)
        let hover=alphaHit(local,rep:bitmap) || (motion.hovering && alphaHit(local,rep:entryBitmap))
        if hover != motion.hovering {
            entryBitmap=hover ? bitmap : nil
            motion.setHover(hover,at:now)
        }
        motion.setPointer(x:Double(dx),y:Double(dy),at:now)
        wake()
    }
    override func mouseEntered(with event:NSEvent) { follow(event) }
    override func mouseMoved(with event:NSEvent) { follow(event) }
    override func mouseExited(with event:NSEvent) {
        prepareInput()
        motion.setHover(false,at:now); entryBitmap=nil
        pollCursor();wake()
    }
    private func pollCursor() {
        refreshPromptFocus()
        guard visible,pressedAt==nil,!muted else { return }
        guard NSApp.isActive else {
            if lastCursor != nil { lastCursor=nil;motion.setPointer(x:nil,y:nil,at:now);wake() }
            return
        }
        let mouse=NSEvent.mouseLocation
        guard mouse != lastCursor else { return }
        updatePointer(at:mouse)
    }
    func refreshPromptFocus() {
        let editor=window?.firstResponder as? NSTextView
        let prompt=editor is AgentDraftEditor.Editor || CanvasPromptEditor.owns(editor)
        let focused=visible && NSApp.isActive && window?.isKeyWindow == true &&
            prompt && editor?.isEditable == true && editor?.isHiddenOrHasHiddenAncestor == false
        guard focused != motion.editingPrompt else { return }
        prepareInput()
        motion.setPromptEditing(focused,at:now)
        wake()
    }
    override func mouseDown(with event:NSEvent) {
        guard alphaHit(convert(event.locationInWindow,from:nil),rep:bitmap) else { return }
        beginDrag(at:eventScreenPoint(event))
    }
    fileprivate func eventScreenPoint(_ event:NSEvent)->NSPoint {
        guard let eventWindow=event.window else { return NSEvent.mouseLocation }
        return eventWindow.convertToScreen(NSRect(origin:event.locationInWindow,size:.zero)).origin
    }
    fileprivate func beginDrag(at point:NSPoint) {
        pressedAt=point;moved=false
        let origin=dragPanel?.frame.origin ?? NSPoint(x:screenCenter.x-bounds.width/2,y:screenCenter.y-bounds.height/2)
        dragOffset=NSPoint(x:pressedAt!.x-origin.x,y:pressedAt!.y-origin.y)
    }
    override func mouseDragged(with event:NSEvent) {
        guard let start=pressedAt else { return }
        let mouse=eventScreenPoint(event)
        if !moved && abs(mouse.x-start.x)<3 && abs(mouse.y-start.y)<3 { return }
        if !moved {
            prepareInput()
            moved=true; motion.setDrag(true,at:now)
            if dragPanel == nil {
            let panel=NSPanel(contentRect:NSRect(origin:.zero,size:bounds.size),
                styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=false
            panel.acceptsMouseMovedEvents=true
            panel.level = .floating; panel.isReleasedWhenClosed=false
            let floating=HeaderMascotFloatingView(frame:NSRect(origin:.zero,size:bounds.size))
            floating.owner=self;panel.contentView=floating;detachedView=floating
            floating.wantsLayer=true;floating.layer?.addSublayer(floatingLamp.layer)
            dragPanel=panel;window?.addChildWindow(panel,ordered:.above)
            }
        }
        dragPanel?.setFrameOrigin(NSPoint(x:mouse.x-dragOffset.x,y:mouse.y-dragOffset.y))
        dragPanel?.orderFront(nil); wake()
    }
    override func mouseUp(with event:NSEvent) {
        guard pressedAt != nil else { return }
        if moved {
            prepareInput()
            motion.setHover(false,at:now); motion.setDrag(false,at:now)
            lastCursor=nil
            wake()
        } else { onToggle() }
        pressedAt=nil; moved=false
    }
    override func accessibilityPerformPress() -> Bool { onToggle(); return true }
    override func rightMouseDown(with event:NSEvent) {
        let menu=NSMenu()
        for (title,selector) in [
            ("打开／收起项目 Agent",#selector(toggleAgent)),
            (muted ? "开启动画" : "暂停动画",#selector(toggleAnimation)),
            ("回到原位",#selector(returnHome))] {
            let item=NSMenuItem(title:title,action:selector,keyEquivalent:""); item.target=self; menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    @objc private func toggleAgent() { onToggle() }
    @objc private func toggleAnimation() { HeaderMascotSessionState.shared.togglePause() }
    @objc private func returnHome() {
        invalidateDisplay();atlas.clear()
        motion.reset(at:now);dragPanel?.orderOut(nil)
        if let dragPanel { window?.removeChildWindow(dragPanel) }
        dragPanel=nil;detachedView=nil;needsDisplay=true;wake()
    }
    private func stopTimer() {
        timer?.invalidate();timer=nil;activeTimer=false;wakeDeadline.consume()
    }
    private func schedule(at time:Double) {
        guard wakeDeadline.request(time) else { return }
        timer?.invalidate()
        let value=Timer(timeInterval:max(0.001,(time-now)/1000),repeats:false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer=nil;self?.activeTimer=false;self?.wakeDeadline.consume();self?.wake()
            }
        }
        timer=value;activeTimer=true;RunLoop.main.add(value,forMode:.common)
    }
    private func prepareInput() {
        let time=now
        if failedFrames>=3 { failedFrames=0;lastPose=nil }
        if dormant { motion.rebaseIntegratorAfterSleep(at:time) }
        _=motion.sample(at:time)
        if lamp.isPlaying || floatingLamp.isPlaying {
            motion.synchronizePresentedLampIntensity(lamp.brightness(at:time))
        }
    }
    private func wake() {
        guard visible,!disposed else { return }
        let time=now
        let budget=ResourceBudget.shared.schedulingSnapshot
        let thermal=ProcessInfo.processInfo.thermalState
        let critical=budget.pressure == .critical || thermal == .critical
        let limited=budget.pressure != .normal || budget.lowPower || thermal == .serious || critical
        if limited { constrained=true;constrainedRecovery=nil }
        else if constrained {
            constrainedRecovery=constrainedRecovery ?? time+5000
            if time >= constrainedRecovery! { constrained=false;constrainedRecovery=nil }
        }
        let reduced=muted || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || critical
        if motion.reduceMotion != reduced { invalidateDisplay();dormant=true }
        motion.reduceMotion=reduced
        if critical { atlas.clear();lamp.stop();floatingLamp.stop() }
        if NSApp.isActive,!reduced,time-lastHealthMS >= (fallbackPolling ? 50 : 250) {
            lastHealthMS=time
            let mouse=NSEvent.mouseLocation
            if let lastCursor,mouse != lastCursor,time-lastPointerEventMS>100 { fallbackPolling=true }
            else if time-lastPointerEventMS<250 { fallbackPolling=false }
            pollCursor()
        }
        tick()
        let hint=motion.schedulingHint(at:time)
        var deadlines:[Double]=[]
        if let deadline=reduced ? hint.nextSemanticDeadlineMS : hint.nextDeadlineMS { deadlines.append(deadline) }
        if let recovery=constrainedRecovery { deadlines.append(recovery) }
        if !reduced {
            if !displayWasLamp,failedFrames<3 {
                let fps=hint.work == .lampOnly ? (constrained ? 15.0 : 30.0) : (constrained ? 30.0 : 60.0)
                deadlines.append(max(time+1,lastTick+1000/fps))
            }
            if atlas.key != nil,!atlas.ready,atlas.rejection==nil {
                deadlines.append(max(time+20,lastBuildMS+200))
            }
            if NSApp.isActive { deadlines.append(lastHealthMS+(fallbackPolling ? 50 : 250)) }
        } else if failedFrames>0,failedFrames<3 { deadlines.append(time+250) }
        if let deadline=deadlines.min() { schedule(at:deadline) }
        else { stopTimer() }
    }
    private func tick() {
        let time=now
        if dormant { motion.rebaseIntegratorAfterSleep(at:time) }
        let pose=motion.sample(at:time)
        let hint=motion.schedulingHint(at:time)
        guard failedFrames<3 else { return }
        let lampOnly=hint.work == .lampOnly && !motion.agentWorking
        let key=MascotLampKey(side:rasterSide,pose:pose,activity:motion.activity,
            appearance:effectiveAppearance.name.rawValue,
            display:window?.screen?.colorSpace?.iccProfileData ?? Data())
        // Blinks may temporarily suspend a build, but the full trajectory is
        // verified before a normalized blink key can ever be played.
        if lampOnly { atlas.reset(key) }
        else if atlas.key != key { atlas.reset(nil);buildSubmitted=false }
        let scale=(dragPanel ?? window)?.backingScaleFactor ?? 2
        // Preserve the original 128px minimum raster on non-Retina windows.
        // A resampled base cannot safely share an independently resampled ROI.
        let pixelAligned=rasterSide==Int(ceil(bounds.width*scale))
        let useLamp=lampOnly && pixelAligned && atlas.ready && atlas.key==key &&
            ProcessInfo.processInfo.environment["CLIPSLOTS_MASCOT_DISABLE_ATLAS"] != "1"
        if useLamp {
            if !displayWasLamp {
                frames.invalidate();bitmap=atlas.base;presentedPose=pose
                needsDisplay=true;detachedView?.needsDisplay=true
            }
            if dragPanel == nil {
                floatingLamp.stop();lamp.play(atlas,in:bounds,scale:window?.backingScaleFactor ?? 2,timeMS:time)
            } else {
                lamp.stop();floatingLamp.play(atlas,in:bounds,
                    scale:dragPanel?.backingScaleFactor ?? 2,timeMS:time)
            }
            displayWasLamp=true;dormant=true;return
        }
        if displayWasLamp { invalidateDisplay() }
        lamp.stop();floatingLamp.stop()
        dormant=motion.reduceMotion
        let fps=hint.work == .lampOnly ? (constrained ? 15.0 : 30.0) : (constrained ? 30.0 : 60.0)
        let interval=1000/fps
        if time-lastTick<interval-0.75 && bitmap != nil && !motion.reduceMotion {
            submitAtlasPartIfIdle(at:time,lampOnly:lampOnly);return
        }
        lastTick=time;frameCount+=1
        if listening,ProcessInfo.processInfo.environment["CLIPSLOTS_VOICE_DIAGNOSTICS_DIRECTORY"] != nil,
           time-lastVoiceTraceTime>=45,voiceTrace.count<1600 {
            lastVoiceTraceTime=time
            voiceTrace.append(["time_ms":time,"activity":motion.activity.rawValue,
                "input_level":AgentVoiceInput.recordingLevel,"smoothed_level":pose.voiceLevel,
                "yaw":pose.yaw,"pitch":pose.pitch,"frame":pose.activityFrame,
                "frame_progress":pose.activityProgress])
        }
        let side=rasterSide, activity=motion.activity
        if scheduledActivity != activity || scheduledSize != side {
            frames.invalidate()
            scheduledActivity=activity;scheduledSize=side;lastPose=nil;buildSubmitted=false
        }
        if pose != lastPose || bitmap == nil {
            frames.submit(MascotFrameRequest(pose:pose,size:side,activity:activity))
            lastPose=pose
        }
        submitAtlasPartIfIdle(at:time,lampOnly:lampOnly)
    }
    private func submitAtlasPartIfIdle(at time:Double,lampOnly:Bool,afterDisplay:Bool=false) {
        if lampOnly,!motion.reduceMotion,!atlas.ready,atlas.rejection==nil,
           !buildSubmitted,(!frames.inFlight || afterDisplay),time-lastBuildMS>=200,
           ProcessInfo.processInfo.environment["CLIPSLOTS_MASCOT_DISABLE_ATLAS"] != "1",
           let part=atlas.pose(for:atlas.nextIndex) {
            buildSubmitted=true;lastBuildMS=time
            frames.submit(.init(pose:part,size:rasterSide,activity:motion.activity,
                target:.atlas(epoch:atlas.epoch,index:atlas.nextIndex)))
        }
    }
    func receiveMascotFrame(_ request:MascotFrameRequest,_ frame:MascotRenderedFrame) {
        guard visible,!disposed else { return }
        switch request.target {
        case let .atlas(epoch,index):
            guard epoch==atlas.epoch,request.size==rasterSide else { buildSubmitted=false;return }
            buildSubmitted=false
            atlas.accept(index:index,frame:frame,
                limit:min(512*1024,ResourceBudget.shared.bytes(for:.auxiliary)/4))
            schedule(at:now+1)
        case .display:
            guard !displayWasLamp,request.activity==motion.activity,request.size==rasterSide else { return }
            guard let image=frame.bitmap else {
                lastPose=nil;failedFrames+=1
                if failedFrames>=3 { atlas.clear();buildSubmitted=false }
                if failedFrames<3 { schedule(at:now+250) };return
            }
            bitmap=image;presentedPose=request.pose;failedFrames=0
            #if DEBUG
            displayIssuedAtMS=request.issuedAtMS
            #endif
            geometryInsideFrustum=frame.geometryInsideFrustum;facialSurfaceValid=frame.facialSurfaceValid
            renderCount+=1;needsDisplay=true;detachedView?.needsDisplay=true
            let hint=motion.schedulingHint(at:now)
            if hint.work == .lampOnly,atlas.key != nil {
                submitAtlasPartIfIdle(at:now,lampOnly:true,afterDisplay:true)
            }
            // Give cache work a chance immediately after a display completes.
            if atlas.key != nil,!atlas.ready,atlas.rejection==nil {
                schedule(at:now+1)
            }
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance();invalidateDisplay();atlas.clear();wake()
    }
    private func saveVoiceTrace() {
        guard let path=ProcessInfo.processInfo.environment["CLIPSLOTS_VOICE_DIAGNOSTICS_DIRECTORY"],
              !voiceTrace.isEmpty else { return }
        let report:[String:Any]=["scope":"native mascot samples from the app hardware meter",
            "samples":voiceTrace,"recording_ended":!listening]
        try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            .write(to:URL(fileURLWithPath:path).appendingPathComponent("mascot-voice-link.json"))
        voiceTrace=[];lastVoiceTraceTime=0
    }
    override func draw(_ dirtyRect:NSRect) {
        guard dragPanel == nil, let image=bitmap?.cgImage else { return }
        NSImage(cgImage:image,size:bounds.size).draw(in:bounds,from:.zero,
            operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
    }
    /// Synchronous deterministic probe; the live timer always uses async frames.
    /// It shares the same serial renderer, so probes cannot race the live graph.
    func render(_ pose:MascotPose,size:Int) -> NSBitmapImageRep? {
        let frame=renderer.renderSynchronously(MascotFrameRequest(pose:pose,size:size,activity:motion.activity))
        geometryInsideFrustum=frame.geometryInsideFrustum
        facialSurfaceValid=frame.facialSurfaceValid
        return frame.bitmap
    }
    fileprivate func drawFloating() {
        guard let image=bitmap?.cgImage else { return }
        NSImage(cgImage:image,size:bounds.size).draw(in:bounds,from:.zero,operation:.sourceOver,
            fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
    }
    fileprivate func floatingHit(_ point:NSPoint)->Bool { alphaHit(point,rep:bitmap) }
    #if DEBUG
    var optimizationDiagnostics:[String:Any] {
        ["renders":renderCount,"samples":frameCount,"atlasReady":atlas.ready,
         "atlasIndex":atlas.nextIndex,"atlasRejection":atlas.rejection ?? "",
         "lampPlaying":displayWasLamp,"atlasBytes":atlas.byteCost,
         "roi":NSStringFromRect(atlas.rect),"side":rasterSide,"paused":muted,
         "yaw":motion.pose.yaw,"pitch":motion.pose.pitch,
         "hovering":motion.hovering,"activity":motion.activity.rawValue,
         "work":String(describing:motion.schedulingHint(at:now).work),
         "visible":visible,"inFlight":service?.frames.inFlight ?? false,
         "displayIssuedAtMS":displayIssuedAtMS]
    }
    func optimizationRefresh() { lastCursor=nil;wake() }
    #endif
}

struct MascotFrameRequest {
    #if DEBUG
    let issuedAtMS=ProcessInfo.processInfo.systemUptime*1000
    #endif
    let pose:MascotPose
    let size:Int
    let activity:MascotMotion.Activity
    enum Target { case display, atlas(epoch:UInt64,index:Int) }
    let target:Target
    init(pose:MascotPose,size:Int,activity:MascotMotion.Activity,target:Target = .display) {
        self.pose=pose;self.size=size;self.activity=activity;self.target=target
    }
}

struct MascotRenderedFrame {
    let bitmap:NSBitmapImageRep?
    let geometryInsideFrustum:Bool
    let facialSurfaceValid:Bool
}

/// Only the queue touches the live scene after initialization. Completed bitmaps
/// are transferred to main and never mutated again; no NSView leaves main.
final class HeaderMascotRenderer: @unchecked Sendable {
    private let queue=DispatchQueue(label:"com.clipslots.mascot.render",qos:.userInitiated)
    private let scene=HeaderMascotScene()
    var legPixels:Double { scene.legPixels }
    var computerGaze:(yaw:Double,pitch:Double) { scene.computerGaze }
    func pointer(x:Double,y:Double)->(Double,Double) { scene.pointer(x:x,y:y) }
    private func raster(_ request:MascotFrameRequest)->MascotRenderedFrame {
        autoreleasepool {
            let bitmap=scene.render(request.pose,size:request.size,activity:request.activity)
            return MascotRenderedFrame(bitmap:bitmap,geometryInsideFrustum:scene.geometryInsideFrustum,
                                       facialSurfaceValid:scene.facialSurfaceValid)
        }
    }
    func render(_ request:MascotFrameRequest,completion:@escaping @MainActor (MascotRenderedFrame)->Void) {
        queue.async { [self] in
            let frame=raster(request)
            DispatchQueue.main.async { completion(frame) }
        }
    }
    func renderSynchronously(_ request:MascotFrameRequest)->MascotRenderedFrame {
        queue.sync { raster(request) }
    }
}

/// At most one frame in flight and one latest pending pose. Invalidation drops
/// pre-hide, old-activity and old-size results without blocking the UI or GPU.
@MainActor
final class MascotFrameScheduler {
    typealias Completion = @MainActor (MascotRenderedFrame)->Void
    private let render:(MascotFrameRequest,@escaping Completion)->Void
    private let present:(MascotFrameRequest,MascotRenderedFrame)->Void
    private var generation:UInt64=0
    private var pending:MascotFrameRequest?
    private(set) var inFlight=false
    private(set) var coalesced=0
    private(set) var discarded=0
    var onIdle:(()->Void)?
    init(render:@escaping (MascotFrameRequest,@escaping Completion)->Void,
         present:@escaping (MascotFrameRequest,MascotRenderedFrame)->Void) {
        self.render=render;self.present=present
    }
    func invalidate() { generation &+= 1;pending=nil }
    func submit(_ request:MascotFrameRequest) {
        if inFlight {
            if pending != nil { coalesced+=1 }
            pending=request
        } else { launch(request) }
    }
    private func launch(_ request:MascotFrameRequest) {
        inFlight=true
        let epoch=generation
        render(request) { [weak self] frame in
            guard let self else { return }
            if epoch == self.generation { self.present(request,frame) }
            else { self.discarded+=1 }
            self.inFlight=false
            if let next=self.pending { self.pending=nil;self.launch(next) }
            else { self.onIdle?() }
        }
    }
}

@MainActor
private final class HeaderMascotFloatingView:NSView {
    weak var owner:HeaderMascotNativeView?
    override var isFlipped:Bool { true }
    override var mouseDownCanMoveWindow:Bool { false }
    override func hitTest(_ point:NSPoint)->NSView? {
        owner?.floatingHit(convert(point,from:superview)) == true ? self : nil
    }
    override func draw(_ rect:NSRect) { owner?.drawFloating() }
    override func mouseDown(with event:NSEvent) {
        guard let owner else { return }
        owner.beginDrag(at:owner.eventScreenPoint(event))
    }
    override func mouseDragged(with event:NSEvent) { owner?.mouseDragged(with:event) }
    override func mouseUp(with event:NSEvent) { owner?.mouseUp(with:event) }
    override func rightMouseDown(with event:NSEvent) { owner?.rightMouseDown(with:event) }
}
