import Foundation

/// Native translation of the locally inspected TRAE pet controller.
/// Timings and hover keyframes are source observations; the native scene
/// supplies reference camera projection and the IP's replacement geometry.
public struct MascotPose: Equatable {
    public var lift = 0.0
    public var legScale = 1.0
    public var legAngle = 0.0
    public var expression = 0.0
    public var blink = 0.0
    public var yaw = 0.0
    public var pitch = 0.0
    public var opacity = 1.0
    public var rotation = 0.0
    public var activityFrame = 0
    public var activityProgress = 0.0
    public var voiceLevel = 0.0
    public var logoIntensity = 0.18
    public init() {}
}

public final class MascotMotion {
    public enum Activity: String { case idle, busy, superBusy, voice, waiting, completed, failed, celebration }
    public static let hoverFrames: [[Double]] = [
        [0,0],[0,0],[-1,1],[-3,3],[-1,4],[2,5],[4,6],[5,7],[6,8],[6,8],
        [5,7],[4,6],[3,5],[-1,4],[-3,4],[-3,3],[-1,1],[1,-1],[1,-1],[1,-1],
        [0,0],[0,0],[-1,1],[-2,2],[0,3],[1,5],[3,6],[4,7],[4,8],[4,6],
        [3,4],[3,3],[1,2],[-1,2],[-1,1],[0,0],[1,-1],[1,-1],[1,-1],[0,0],[0,0],[0,0]
    ]
    public private(set) var pose = MascotPose()
    public private(set) var activity: Activity = .idle
    public private(set) var hovering = false
    public private(set) var dragging = false
    public private(set) var editingPrompt = false
    public private(set) var agentWorking = false
    public var computerGaze = (yaw: 0.0, pitch: 26.0)
    public var computerFocused: Bool { editingPrompt || working }
    private var working: Bool { agentWorking || activity == .busy || activity == .superBusy }
    public var reduceMotion = false
    public var legPixels = 25.0
    public var pointerProjection: ((Double,Double)->(Double,Double))?
    public var random: () -> Double = { Double.random(in: 0...1) }
    private var hoverStart: Double?
    private var hoverEnd = Double.infinity
    private var dragStart = 0.0
    private var transition: (at: Double, pose: MascotPose)?
    private var blinkStart: Double?
    private var reopening: (at: Double, amount: Double)?
    private var nextBlink: Double?
    private var targetYaw = 0.0
    private var targetPitch = 0.0
    private var pointerPresent = false
    private var pointerMovedAt: Double?
    private var previousTime: Double?
    private var activityStart = 0.0
    private var busyStart: Double?
    private var completionUntil: Double?
    private var targetVoiceLevel = 0.0
    private var logoTransition: (at: Double, intensity: Double)?

    public init() {}
    public static func smooth(_ amount: Double) -> Double {
        let x = min(1, max(0, amount)); return x*x*(3-2*x)
    }
    public static func hoverSample(milliseconds: Double, channel: Int) -> Double {
        let phase = max(0,milliseconds).truncatingRemainder(dividingBy: 1680)/40
        let n = Int(phase), t = phase-Double(n)
        func f(_ offset: Int) -> Double { hoverFrames[(n+offset+42)%42][channel] }
        let w=f(-1), v=f(0), h=f(1), u=f(2)
        if v == 0 && h == 0 { return 0 }
        return v+0.5*t*(h-w+t*(2*w-5*v+4*h-u+t*(3*(v-h)+u-w)))
    }
    public func setHover(_ value: Bool, at time: Double) {
        guard hovering != value else { return }
        hovering = value
        if !dragging && !computerFocused && activity == .idle {
            if value { hoverStart = hoverStart ?? time; hoverEnd = .infinity }
            else if let start = hoverStart, hoverEnd == .infinity {
                let elapsed=time-start, base=floor(elapsed/1680)*1680, phase=elapsed-base
                hoverEnd=base+(phase <= 800 ? 800 : phase < 880 ? phase : 1680)
            }
        }
        interruptBlink(at: time)
    }
    public func setDrag(_ value: Bool, at time: Double) {
        guard dragging != value else { return }
        transition=(time,pose); dragging=value
        if value { dragStart=time; hoverStart=nil; interruptBlink(at: time) }
        else { hoverStart=hovering && activity == .idle ? time : nil }
        hoverEnd = .infinity
    }
    public func setPointer(x: Double?, y: Double?, at time: Double) {
        pointerPresent = x != nil && y != nil
        pointerMovedAt = pointerPresent ? time : nil
        if let x, let y, hypot(x,y) >= 8 {
            if let pointerProjection {
                (targetYaw,targetPitch)=pointerProjection(x,y)
            } else {
                targetYaw=min(65,max(-65,atan2(x,180)*180 / .pi))
                targetPitch=min(30,max(-30,atan2(y,hypot(x,180))*180 / .pi))
            }
        } else { targetYaw=0; targetPitch=0 }
        if pointerPresent && !computerFocused { interruptBlink(at: time) }
    }
    public func setPromptEditing(_ value: Bool, at time: Double) {
        guard editingPrompt != value else { return }
        editingPrompt=value
        if computerFocused { hoverStart=nil; hoverEnd = .infinity }
        else if hovering && activity == .idle { hoverStart=time }
    }
    public func setAgentWorking(_ value: Bool, at time: Double) {
        guard agentWorking != value else { return }
        let wasWorking=working
        agentWorking=value
        if wasWorking != working { logoTransition=(time,pose.logoIntensity) }
        if computerFocused { hoverStart=nil; hoverEnd = .infinity }
    }
    public func setVoiceLevel(_ value: Double) {
        targetVoiceLevel = value.isFinite ? min(1,max(0,value)) : 0
    }
    public func setActivity(_ value: Activity, at time: Double) {
        guard value != activity else { return }
        let wasWorking=working
        if value == .completed { completionUntil=time+1800 }
        else { completionUntil=nil }
        if value == .busy && activity != .superBusy { busyStart=time }
        else if value != .superBusy { busyStart=nil }
        activity=value; activityStart=time
        if wasWorking != working { logoTransition=(time,pose.logoIntensity) }
        if value != .voice { targetVoiceLevel=0 }
        if value != .idle {
            hoverStart=nil; hoverEnd = .infinity
            interruptBlink(at: time)
        } else if hovering { hoverStart=time }
    }
    private var gaze: (yaw: Double, pitch: Double) {
        if dragging { return (0,0) }
        if computerFocused { return computerGaze }
        return (targetYaw,targetPitch)
    }
    public var highFrameRate: Bool {
        let (yaw,pitch)=gaze
        return !reduceMotion && (hoverStart != nil || dragging || transition != nil ||
            blinkStart != nil || reopening != nil || abs(pose.yaw-yaw)>0.03 ||
            abs(pose.pitch-pitch)>0.03 || ![.idle,.failed].contains(activity))
    }
    public var continuous: Bool { !reduceMotion }
    public var nextWake: Double? { nextBlink }
    public func reset(at time: Double) {
        hovering=false; dragging=false; hoverStart=nil; transition=nil; blinkStart=nil
        reopening=nil; nextBlink=nil; pointerPresent=false; previousTime=nil
        targetYaw=0; targetPitch=0; targetVoiceLevel=0; pointerMovedAt=nil; pose=MascotPose()
        editingPrompt=false; agentWorking=false; logoTransition=nil
    }
    private func interruptBlink(at time: Double) {
        nextBlink=nil
        if blinkStart != nil || reopening != nil {
            blinkStart=nil; reopening=(time,pose.blink)
        }
    }
    @discardableResult public func sample(at time: Double) -> MascotPose {
        if let until=completionUntil, time >= until {
            completionUntil=nil; setActivity(.idle,at:time)
        }
        if let start=busyStart {
            let elapsed=time-start
            if elapsed >= 180000 && elapsed.truncatingRemainder(dividingBy:180000) < 10000 {
                if activity != .superBusy { activity = .superBusy; activityStart=time }
            } else if activity == .superBusy { activity = .busy; activityStart=time }
        }
        if reduceMotion {
            pose=MascotPose()
            if computerFocused { (pose.yaw,pose.pitch)=computerGaze }
            pose.logoIntensity=working ? 1 : 0.55
            previousTime=time; nextBlink=nil; logoTransition=nil; return pose
        }
        var result=MascotPose()
        let dt=min(0.1,max(0,(time-(previousTime ?? time-1000/60))/1000))
        previousTime=time
        let easing=1-exp(-dt/0.12)
        let (yaw,pitch)=gaze
        result.yaw=abs(pose.yaw-yaw)<0.03 ? yaw : pose.yaw+(yaw-pose.yaw)*easing
        result.pitch=abs(pose.pitch-pitch)<0.03 ? pitch : pose.pitch+(pitch-pose.pitch)*easing
        let breath=0.18+0.82*(1-cos(time*2 * .pi/3200))/2
        result.logoIntensity=working ? 1 : breath
        if let current=logoTransition {
            let p=Self.smooth((time-current.at)/240)
            result.logoIntensity=current.intensity+(result.logoIntensity-current.intensity)*p
            if p == 1 { logoTransition=nil }
        }
        let voice=activity == .voice ? targetVoiceLevel : 0
        let voiceEase=1-exp(-dt/(voice>pose.voiceLevel ? 0.07 : 0.18))
        result.voiceLevel=abs(pose.voiceLevel-voice)<0.002 ? voice :
            pose.voiceLevel+(voice-pose.voiceLevel)*voiceEase
        if dragging {
            result.legAngle=0.32*sin((time-dragStart)*2 * .pi/280); result.expression=1
        } else if let start=hoverStart {
            let elapsed=time-start
            if elapsed >= hoverEnd { hoverStart=nil; hoverEnd = .infinity }
            else {
                result.lift=Self.hoverSample(milliseconds:elapsed,channel:0)*80/230
                result.legScale=min(1.1,max(0.5,1-Self.hoverSample(milliseconds:elapsed,channel:1)*80/230/max(1,legPixels)))
            }
        }
        if let current=transition {
            let p=min(1,max(0,(time-current.at)/220)), s=Self.smooth(p)
            result.lift=current.pose.lift+(result.lift-current.pose.lift)*s
            result.legScale=current.pose.legScale+(result.legScale-current.pose.legScale)*s
            result.legAngle=current.pose.legAngle+(result.legAngle-current.pose.legAngle)*s
            result.expression=current.pose.expression+(result.expression-current.pose.expression)*s
            if p == 1 { transition=nil }
        }
        let pointerQuiet = computerFocused || !pointerPresent || time-(pointerMovedAt ?? time)>=800
        let idle = activity == .idle && !hovering && !dragging && pointerQuiet && hoverStart == nil
        if idle && nextBlink == nil && blinkStart == nil && reopening == nil {
            nextBlink=time+2000+random()*2000
        }
        if let next=nextBlink, time >= next, idle { nextBlink=nil; blinkStart=time }
        if let current=reopening {
            let t=min(1,max(0,(time-current.at)/100))
            result.blink=current.amount*(1-Self.smooth(t))
            if t == 1 { reopening=nil }
        } else if let start=blinkStart {
            let elapsed=max(0,time-start)
            result.blink=elapsed<50 ? Self.smooth(elapsed/50) : elapsed<80 ? 1 :
                1-Self.smooth(min(1,(elapsed-80)/100))
            if elapsed >= 180 {
                blinkStart=nil; result.blink=0
                if idle { nextBlink=time+7000+random()*5000 }
            }
        }
        let elapsed=max(0,time-activityStart)
        switch activity {
        case .waiting:
            let p=(1-cos(elapsed*2 * .pi/1800))/2
            result.opacity=working ? 1 : 1-0.45*p; result.lift=2*p
        case .completed:
            let p=(1-cos(elapsed.truncatingRemainder(dividingBy:600)*2 * .pi/600))/2
            result.lift=9*p; result.rotation = -4*p
        case .busy, .superBusy, .voice:
            let count=activity == .busy ? 25 : activity == .superBusy ? 50 : 76
            result.activityFrame=Int(elapsed/40)%count
            result.activityProgress=(elapsed/40).truncatingRemainder(dividingBy:1)
        case .celebration:
            // Same prepare/reveal/play/return/settle intervals; appearance is IP-specific.
            if elapsed < 1100 { result.lift=3*Self.smooth(elapsed/600) }
            else if elapsed < 1950 { result.rotation=12*Self.smooth((elapsed-1100)/850) }
            else if elapsed < 7300 { result.rotation=12*sin((elapsed-1950)*2 * .pi/900); result.lift=5*abs(sin(elapsed * .pi/900)) }
            else if elapsed < 7950 { result.rotation=12*(1-Self.smooth((elapsed-7300)/650)) }
            else if elapsed < 8750 { result.lift=3*(1-Self.smooth((elapsed-7950)/800)) }
            else { setActivity(.idle,at:time) }
        case .idle, .failed: break
        }
        pose=result; return result
    }
}

public enum MascotResources {
    public static let identifiers=["idle","head","body","left-leg","right-leg","left-arm","right-arm","left-eye","right-eye",
        "stickers","cloth","cloth-normal","cloth-roughness","face","eyeLeft","eyeRight"]
    public static func url(_ identifier: String) -> URL? {
        guard identifiers.contains(identifier) || ["activity-motion","scene","scene-mesh"].contains(identifier) else { return nil }
        let ext=identifier == "activity-motion" || identifier == "scene" ? "json" : identifier == "scene-mesh" ? "mesh" : "png"
        let name=identifier == "scene-mesh" ? "scene" : identifier
        let relative="ClipSlots_ClipSlotsKit.bundle/Resources/Mascot/\(name).\(ext)"
        for url in [Bundle.main.resourceURL?.appendingPathComponent(relative),
                    Bundle.main.bundleURL.appendingPathComponent(relative)].compactMap({$0}) {
            if FileManager.default.fileExists(atPath:url.path) { return url }
        }
        return Bundle.module.url(forResource:name,withExtension:ext,subdirectory:"Resources/Mascot")
    }
}
