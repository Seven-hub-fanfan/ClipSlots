import AppKit
import SwiftUI
import Combine
import ClipSlotsKit

struct HeaderMascotView: NSViewRepresentable {
    static let canvasSide: CGFloat = 104
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
final class HeaderMascotNativeView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    let motion=MascotMotion()
    private let scene=HeaderMascotScene()
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
    private var muted=false
    private var lastTick=0.0
    private var stableSince: Double?
    private var cursorTimer:Timer?
    private var lastCursor:NSPoint?
    private var voiceTrace:[[String:Any]]=[]
    private var lastVoiceTraceTime=0.0
    private(set) var frameCount=0
    private(set) var renderCount=0
    private(set) var activeTimer=false
    var geometryInsideFrustum: Bool { scene.geometryInsideFrustum }
    var facialSurfaceValid: Bool { scene.facialSurfaceValid }
    private var now: Double { ProcessInfo.processInfo.systemUptime*1000 }

    override init(frame frameRect:NSRect) {
        super.init(frame:frameRect)
        motion.legPixels=scene.legPixels
        motion.pointerProjection={ [weak scene] x,y in scene?.pointer(x:x,y:y) ?? (0,0) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("斗篷小助手")
        setAccessibilityIdentifier("header-ip-mascot")
        setAccessibilityHelp("点击开关项目 Agent；悬停、拖动与右键可互动")
        let center=NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification,NSApplication.didResignActiveNotification,
                     NSWindow.didMiniaturizeNotification,NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification,NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
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
                    guard let self, let editor=note.object as? AgentDraftEditor.Editor,
                          editor.window === self.window, editor.window?.firstResponder === editor,
                          !self.motion.hovering, !self.motion.dragging else { return }
                    var range=editor.selectedRange()
                    let caret=editor.firstRect(forCharacterRange:range,actualRange:&range)
                    let origin=self.interactionCenter
                    self.motion.setPointer(x:Double(caret.midX-origin.x),
                                           y:Double(origin.y-caret.midY),at:self.now)
                    self.wake()
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
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshVisibility() }
    override func viewDidHide() { super.viewDidHide(); refreshVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshVisibility() }
    private var visible:Bool {
        !disposed && !isHiddenOrHasHiddenAncestor && !NSApp.isHidden &&
        window != nil && window!.isVisible && !window!.isMiniaturized &&
        window!.occlusionState.contains(.visible)
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
            dragPanel?.orderFront(nil)
            if pointerMonitor == nil {
                pointerMonitor=NSEvent.addLocalMonitorForEvents(matching:[.mouseMoved,.leftMouseDragged]) { [weak self] event in
                    MainActor.assumeIsolated {
                        if let self, event.window === self.window, self.visible, self.pressedAt == nil {
                            self.follow(event)
                        }
                    }
                    return event
                }
                window?.acceptsMouseMovedEvents=true
            }
            wake()
            if cursorTimer == nil {
                let timer=Timer(timeInterval:0.05,repeats:true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pollCursor() }
                }
                cursorTimer=timer;RunLoop.main.add(timer,forMode:.common)
            }
        } else {
            stopTimer()
            cursorTimer?.invalidate();cursorTimer=nil;lastCursor=nil
            if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor); self.pointerMonitor=nil }
            dragPanel?.orderOut(nil);pressedAt=nil
            motion.reset(at:now); lastPose=nil; entryBitmap=nil
        }
    }
    func dispose() {
        disposed=true; stopTimer(); subscribers.removeAll()
        cursorTimer?.invalidate();cursorTimer=nil
        notifications.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }; notifications=[]
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor); self.pointerMonitor=nil }
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
        motion.setHover(false,at:now); entryBitmap=nil
        pollCursor();wake()
    }
    private func pollCursor() {
        guard visible,pressedAt==nil else { return }
        guard NSApp.isActive else {
            if lastCursor != nil { lastCursor=nil;motion.setPointer(x:nil,y:nil,at:now);wake() }
            return
        }
        let mouse=NSEvent.mouseLocation
        guard mouse != lastCursor else { return }
        lastCursor=mouse
        updatePointer(at:mouse)
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
            moved=true; motion.setDrag(true,at:now)
            if dragPanel == nil {
            let panel=NSPanel(contentRect:NSRect(origin:.zero,size:bounds.size),
                styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=false
            panel.level = .floating; panel.isReleasedWhenClosed=false
            let floating=HeaderMascotFloatingView(frame:NSRect(origin:.zero,size:bounds.size))
            floating.owner=self;panel.contentView=floating;detachedView=floating
            dragPanel=panel;window?.addChildWindow(panel,ordered:.above)
            }
        }
        dragPanel?.setFrameOrigin(NSPoint(x:mouse.x-dragOffset.x,y:mouse.y-dragOffset.y))
        dragPanel?.orderFront(nil); wake()
    }
    override func mouseUp(with event:NSEvent) {
        guard pressedAt != nil else { return }
        if moved {
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
    @objc private func toggleAnimation() { muted.toggle(); wake() }
    @objc private func returnHome() {
        motion.reset(at:now);dragPanel?.orderOut(nil)
        if let dragPanel { window?.removeChildWindow(dragPanel) }
        dragPanel=nil;detachedView=nil;needsDisplay=true;wake()
    }
    private func stopTimer() { timer?.invalidate(); timer=nil; activeTimer=false }
    private func wake() {
        guard visible else { return }
        stopTimer(); tick()
        let time=now
        let next=motion.nextWake ?? time+12000
        let delay=motion.continuous ? 1.0/60 : max(0.02,(next-time)/1000)
        guard !muted && !motion.reduceMotion else { return }
        let value=Timer(timeInterval:delay,repeats:false) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        }
        timer=value; activeTimer=true; RunLoop.main.add(value,forMode:.common)
    }
    private func tick() {
        let time=now
        motion.reduceMotion=muted || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fast=motion.dragging || motion.continuous
        if fast { stableSince=nil }
        else { stableSince=stableSince ?? time }
        let interval=fast || time-(stableSince ?? time)<250 ? 1000.0/60 : 1000.0/30
        if time-lastTick<interval-0.75 && bitmap != nil { return }
        lastTick=time; frameCount+=1
        let pose=motion.sample(at:time)
        if listening,ProcessInfo.processInfo.environment["CLIPSLOTS_VOICE_DIAGNOSTICS_DIRECTORY"] != nil,
           time-lastVoiceTraceTime>=45,voiceTrace.count<1600 {
            lastVoiceTraceTime=time
            voiceTrace.append(["time_ms":time,"activity":motion.activity.rawValue,
                "input_level":AgentVoiceInput.recordingLevel,"smoothed_level":pose.voiceLevel,
                "yaw":pose.yaw,"pitch":pose.pitch,"frame":pose.activityFrame,
                "frame_progress":pose.activityProgress])
        }
        if pose != lastPose || bitmap == nil {
            let scale=window?.backingScaleFactor ?? 2
            let rasterSide=max(128,Int(ceil(bounds.width*scale)))
            bitmap=render(pose,size:rasterSide); lastPose=pose; renderCount+=1; needsDisplay=true
            detachedView?.needsDisplay=true
        }
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
    /// One transparent CPU raster at Retina size. No web runtime or per-token page redraw.
    func render(_ pose:MascotPose,size:Int) -> NSBitmapImageRep? {
        return scene.render(pose,size:size,activity:motion.activity)
    }
    fileprivate func drawFloating() {
        guard let image=bitmap?.cgImage else { return }
        NSImage(cgImage:image,size:bounds.size).draw(in:bounds,from:.zero,operation:.sourceOver,
            fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
    }
    fileprivate func floatingHit(_ point:NSPoint)->Bool { alphaHit(point,rep:bitmap) }
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
