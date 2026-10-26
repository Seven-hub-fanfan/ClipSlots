import Foundation
import ClipSlotsKit

func runMascotMotionTests(_ t:TestRunner) {
    let motion=MascotMotion(); motion.random={0}
    motion.setHover(true,at:0)
    for (index,keyframe) in MascotMotion.hoverFrames.enumerated() {
        let pose=motion.sample(at:Double(index)*40)
        t.check(abs(pose.lift-keyframe[0]*80/230)<0.00001,
                "Mascot source hover lift at frame \(index)")
        t.check(abs(pose.legScale-min(1.1,max(0.5,1-keyframe[1]*80/230/25)))<0.00001,
                "Mascot source leg compression at frame \(index)")
    }
    motion.reset(at:0); motion.setHover(true,at:0); motion.setHover(false,at:100)
    t.check(motion.sample(at:400).lift>0 && motion.sample(at:800).lift==0,
            "Mascot early hover exit completes first 800ms landing")
    motion.reset(at:0); motion.setHover(true,at:0); motion.setHover(false,at:900)
    t.check(motion.sample(at:1100).lift>0 && motion.sample(at:1680).lift==0,
            "Mascot late hover exit completes 1680ms cycle")
    motion.reset(at:0); motion.setDrag(true,at:0)
    t.check(abs(motion.sample(at:110).expression-0.5)<0.00001,
            "Mascot dragging expression uses 220ms smooth transition")
    t.check(motion.sample(at:220).expression==1 && abs(motion.sample(at:350).legAngle-0.32)<0.00001,
            "Mascot dangling legs preserve 280ms source period")
    motion.setDrag(false,at:400); _=motion.sample(at:620)
    t.check(motion.pose.expression==0 && motion.pose.legAngle==0,
            "Mascot drop returns neutral pose in 220ms")
    motion.reset(at:0); _=motion.sample(at:0); _=motion.sample(at:2000)
    t.check(motion.sample(at:2050).blink==1 && motion.sample(at:2080).blink==1 &&
            motion.sample(at:2180).blink==0, "Mascot blink closes50 holds30 opens100")
    t.check(motion.nextWake==9180, "Mascot subsequent blink waits seven seconds")
    motion.reset(at:0); _=motion.sample(at:0); _=motion.sample(at:2000); _=motion.sample(at:2050)
    motion.setPointer(x:400,y:100,at:2050)
    t.check(motion.sample(at:2100).blink==0.5 && motion.sample(at:2150).blink==0,
            "Mascot pointer interrupt reopens in 100ms")
    motion.reset(at:0); motion.setPointer(x:10000,y:10000,at:0)
    for i in 0...100 { _=motion.sample(at:Double(i)*16.7) }
    t.check(abs(motion.pose.yaw-65)<0.001 && abs(motion.pose.pitch-30)<0.001,
            "Mascot pointer limits yaw65 pitch30")
    motion.reset(at:0); motion.setPointer(x:3,y:3,at:0)
    t.check(motion.sample(at:100).yaw==0 && motion.pose.pitch==0,
            "Mascot pointer deadzone is eight source pixels")
    let follow=MascotMotion()
    follow.setPointer(x:900,y:-300,at:0);follow.setHover(true,at:0)
    for i in 0...80 { _=follow.sample(at:Double(i)*17) }
    t.check(follow.pose.yaw>60 && follow.pose.pitch < -15,
            "Mascot hover retains far pointer gaze instead of snapping neutral")
    follow.setActivity(.voice,at:1400);follow.setVoiceLevel(0.9)
    let initial=follow.sample(at:1400)
    let response=follow.sample(at:1460)
    t.check(response.yaw>60 && response.pitch < -15,
            "Mascot microphone activity keeps the pointer head orientation")
    t.check(response.voiceLevel>initial.voiceLevel && response.voiceLevel<0.9,
            "Mascot actual audio energy rises smoothly without a one-frame jump")
    follow.setVoiceLevel(0)
    let release=follow.sample(at:1500)
    t.check(release.voiceLevel>0 && release.voiceLevel<response.voiceLevel,
            "Mascot audio release decays instead of sticking or snapping")
    for i in 1...100 { _=follow.sample(at:1500+Double(i)*17) }
    t.check(follow.pose.voiceLevel==0,"Mascot silence settles completely")
    follow.setActivity(.idle,at:3300);follow.setVoiceLevel(.nan)
    t.check(follow.sample(at:3400).voiceLevel.isFinite,"Mascot invalid meter value cannot poison the scene")
    let interpolation=MascotMotion();interpolation.setActivity(.busy,at:0)
    t.check(interpolation.sample(at:20).activityFrame==0 &&
            interpolation.pose.activityProgress==0.5,
            "Mascot intermediate render retains the source 40ms frame boundaries")
    let resting=MascotMotion();resting.random={0}
    resting.setPointer(x:600,y:0,at:0);_=resting.sample(at:0);_=resting.sample(at:800)
    let expectedBlink=resting.nextWake==2800;_=resting.sample(at:2800)
    t.check(expectedBlink && resting.sample(at:2850).blink==1,
            "Mascot stationary pointer retains gaze and allows natural blinking")
    motion.setActivity(.waiting,at:0)
    t.check(abs(motion.sample(at:900).opacity-0.55)<0.00001 && motion.pose.lift==2,
            "Mascot waiting feedback midpoint of 1800ms")
    motion.setActivity(.completed,at:2000)
    t.check(motion.sample(at:2300).lift==9 && motion.pose.rotation == -4,
            "Mascot completion uses source nine-pixel bounce")
    _=motion.sample(at:3800)
    t.check(motion.activity == .idle, "Mascot completion stops after three600ms cycles")
    motion.setActivity(.completed,at:4000); motion.setActivity(.failed,at:4100)
    _=motion.sample(at:6000)
    t.check(motion.activity == .failed, "Mascot failure cancels completion")
    motion.setActivity(.busy,at:0); _=motion.sample(at:180000)
    t.check(motion.activity == .superBusy, "Mascot superbusy starts after three minutes")
    _=motion.sample(at:190000)
    t.check(motion.activity == .busy, "Mascot superbusy ends after ten seconds")
    motion.reduceMotion=true
    let reduced=motion.sample(at:190500)
    t.check(reduced.pitch==motion.computerGaze.pitch && reduced.logoIntensity==1 &&
            !motion.continuous && !motion.highFrameRate,
            "Mascot reduce motion keeps static working gaze and light without continuous timer")
    let focused=MascotMotion()
    focused.setPromptEditing(true,at:0)
    for i in 0...160 {
        focused.setPointer(x:i%2==0 ? -900 : 900,y:i%3==0 ? -600 : 600,at:Double(i)*17)
        _=focused.sample(at:Double(i)*17)
    }
    t.check(focused.pose.yaw==focused.computerGaze.yaw && focused.pose.pitch==focused.computerGaze.pitch,
            "Mascot editing gaze survives continuous opposite pointer sweeps")
    t.check(focused.pose.logoIntensity<1 && !focused.agentWorking,
            "Mascot editing alone retains idle breathing instead of work light")
    focused.setPromptEditing(false,at:2737)
    let firstRelease=focused.sample(at:2737)
    t.check(abs(firstRelease.yaw)<20 && firstRelease.pitch>focused.computerGaze.pitch && firstRelease.pitch<30,
            "Mascot editor blur starts a smooth return to the latest pointer")
    for i in 1...100 { _=focused.sample(at:2800+Double(i)*17) }
    t.check(focused.pose.yaw < -60 && focused.pose.pitch==30,
            "Mascot editor blur restores idle pointer following")
    focused.setAgentWorking(true,at:4600);focused.setActivity(.waiting,at:4600)
    for i in 0...100 {
        focused.setPointer(x:700,y:-400,at:4600+Double(i)*17)
        _=focused.sample(at:4600+Double(i)*17)
    }
    t.check(focused.pose.yaw==focused.computerGaze.yaw && focused.pose.pitch==focused.computerGaze.pitch &&
            focused.pose.logoIntensity==1,
            "Mascot pending active work retains screen gaze and steady logo")
    t.check(focused.pose.opacity==1,"Mascot pending work cannot dim the steady logo through whole-character opacity")
    focused.setAgentWorking(false,at:6400);focused.setActivity(.idle,at:6400)
    let lightRelease=focused.sample(at:6400)
    t.check(lightRelease.logoIntensity==1,"Mascot end of work does not jump directly to breath minimum")
    _=focused.sample(at:6640)
    t.check(focused.pose.logoIntensity<0.3,"Mascot end of work rejoins the breathing curve after a short fade")
    let lamp=MascotMotion();lamp.random={0}
    for (time,intensity) in [(0.0,0.18),(1600.0,1.0),(3200.0,0.18),(4800.0,1.0)] {
        t.check(abs(lamp.sample(at:time).logoIntensity-intensity)<0.00001,
                "Mascot logo 3200ms breath extremum at \(time)")
    }
    t.check(lamp.continuous && !lamp.highFrameRate,"Mascot idle breathing uses the lower render cadence")
    lamp.setActivity(.busy,at:5000)
    _=lamp.sample(at:5240)
    for time in [5500.0,6400,8000,9600] {
        lamp.setPointer(x:900,y:-900,at:time)
        t.check(lamp.sample(at:time).logoIntensity==1,"Mascot busy logo stays bright at \(time)")
    }
    lamp.setDrag(true,at:9700)
    for i in 0...100 { _=lamp.sample(at:9700+Double(i)*17) }
    t.check(lamp.pose.yaw==0 && lamp.pose.pitch==0 && lamp.pose.logoIntensity==1,
            "Mascot drag takes gaze priority while retaining work light")
    lamp.setDrag(false,at:11500)
    for i in 0...100 { _=lamp.sample(at:11500+Double(i)*17) }
    t.check(lamp.pose.pitch==lamp.computerGaze.pitch,"Mascot drop resumes the working screen gaze")
    lamp.setActivity(.idle,at:13300);lamp.reduceMotion=true
    t.check(lamp.sample(at:14000).logoIntensity==0.55 && !lamp.continuous,
            "Mascot reduced motion uses a static soft idle logo")
    for name in MascotResources.identifiers {
        t.check(MascotResources.url(name).map { FileManager.default.fileExists(atPath:$0.path) } == true,
                "Mascot offline artwork resolves \(name)")
    }
    if let url=MascotResources.url("activity-motion"),
       let data=try? Data(contentsOf:url),
       let tracks=try? JSONSerialization.jsonObject(with:data) as? [String:[String:Any]] {
        for (name,count) in [("busy",25),("superBusy",50),("voice",76)] {
            let track=tracks[name]
            t.check((track?["durations"] as? [Int]) == Array(repeating:40,count:count),
                    "Mascot \(name) original WebP frame durations")
            let rotations=track?["headQuaternion"] as? [[Double]] ?? []
            t.check(rotations.count==count && rotations.allSatisfy {
                $0.count==4 && abs($0.reduce(0) { $0+$1*$1 }-1)<0.0001
            }, "Mascot \(name) recovered normalized head poses")
        }
        let sourceVoice=tracks["voice"]?["headPixels"] as? [[Double]] ?? []
        let ys=sourceVoice.compactMap { $0.count==2 ? $0[1] : nil }
        t.check((ys.max() ?? 0)-(ys.min() ?? 0)>10,
                "Mascot voice source retains low-head and raised-head span")
        let pen=tracks["voice"]?["pen"] as? [[Double]] ?? []
        t.check(pen.count==76 && pen.contains { abs($0[0])+abs($0[1])>0.005 },
                "Mascot voice retains source writing-pen trajectory")
    } else { t.check(false,"Mascot activity source track readable") }
    t.check(MascotResources.url("../idle")==nil, "Mascot resource traversal rejected")
    let scheduled=MascotMotion();scheduled.random={0}
    _=scheduled.sample(at:0)
    t.check(scheduled.schedulingHint(at:0).work == .lampOnly &&
            scheduled.schedulingHint(at:0).nextDeadlineMS==2000,
            "Mascot lamp-only scheduling keeps the exact next blink")
    scheduled.setPointer(x:500,y:0,at:100)
    _=scheduled.sample(at:100)
    t.check(scheduled.schedulingHint(at:100).work == .pose &&
            scheduled.schedulingHint(at:100).nextDeadlineMS==900,
            "Mascot pointer convergence retains the 800ms quiet deadline")
    scheduled.reduceMotion=true;scheduled.setActivity(.completed,at:1000)
    _=scheduled.sample(at:1000)
    t.check(scheduled.schedulingHint(at:1000).nextSemanticDeadlineMS==2800,
            "Mascot paused completion still has a semantic wake")
    _=scheduled.sample(at:2800)
    t.check(scheduled.activity == .idle,"Mascot paused completion expires without visual frames")
    scheduled.setActivity(.celebration,at:3000);_=scheduled.sample(at:11750)
    t.check(scheduled.activity == .idle,"Mascot reduced celebration cannot stick past its end")
    scheduled.setActivity(.busy,at:12000);_=scheduled.sample(at:192000)
    t.check(scheduled.activity == .superBusy &&
            scheduled.schedulingHint(at:192000).nextSemanticDeadlineMS==202000,
            "Mascot paused busy retains the ten-second superbusy deadline")
    _=scheduled.sample(at:202000)
    t.check(scheduled.activity == .busy,"Mascot paused superbusy returns to normal")
    let sleeping=MascotMotion();_=sleeping.sample(at:0)
    sleeping.rebaseIntegratorAfterSleep(at:600000)
    sleeping.setPointer(x:900,y:0,at:600000)
    t.check(sleeping.sample(at:600000).yaw==0,
            "Mascot dormant first input does not introduce a 100ms gaze jump")
    t.check(sleeping.sample(at:600017).yaw>0 && sleeping.pose.yaw<10,
            "Mascot dormant gaze resumes with the original damping")
    sleeping.synchronizePresentedLampIntensity(0.42)
    sleeping.setActivity(.busy,at:600017)
    t.check(abs(sleeping.sample(at:600017).logoIntensity-0.42)<0.00001,
            "Mascot lamp-to-work transition starts at the presented brightness")
    sleeping.synchronizePresentedLampIntensity(.nan)
    t.check(sleeping.pose.logoIntensity.isFinite,"Mascot invalid presentation brightness is ignored")
}
