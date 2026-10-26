#if DEBUG
import AppKit
import ClipSlotsKit

/// Dedicated offline fixture: never calls a model, tool or generation runner.
@MainActor
enum HeaderMascotOptimizationProbe {
    private static var started=false
    static func start(_ view:HeaderMascotNativeView) {
        let env=ProcessInfo.processInfo.environment
        guard !started,view.window != nil,let path=env["CLIPSLOTS_MASCOT_OPTIMIZATION_PROBE"],
              env["CLIPSLOTS_DATA_DIR"]?.hasPrefix("/tmp/")==true,
              Bundle.main.bundleIdentifier != "com.clipslots.app" else { return }
        started=true
        Task { await run(view,directory:URL(fileURLWithPath:path)) }
    }
    private static func run(_ view:HeaderMascotNativeView,directory:URL) async {
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var failures:[String]=[],passed=0
        var observations:[[String:Any]]=[]
        func check(_ value:Bool,_ name:String) {
            if value { passed+=1 } else { failures.append(name) }
            NSLog("[MascotOptimization] \(value ? "PASS" : "FAIL") \(name)")
        }
        func pause(_ seconds:Double) async { try? await Task.sleep(for:.seconds(seconds)) }
        func save(_ filename:String) {
            let report:[String:Any]=["passed":passed,"failures":failures,
                "observations":observations,"diagnostics":view.optimizationDiagnostics]
            try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                .write(to:directory.appendingPathComponent(filename))
        }
        // The launch-only window harness finishes its own activation first.
        await pause(8)
        // Use a real OS focus change instead of NSApp.deactivate(), which can
        // leave app-local activation state inconsistent with WindowServer.
        if let finder=NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier=="com.apple.finder"
        }) {
            finder.activate(options:[.activateIgnoringOtherApps])
        }
        for _ in 0..<40 {
            if !NSApp.isActive { break }
            await pause(0.05)
        }
        check(!NSApp.isActive,"Neutral fixture performs an actual OS focus change")
        view.window?.orderFrontRegardless()
        view.motion.setHover(false,at:ProcessInfo.processInfo.systemUptime*1000)
        view.motion.setPointer(x:nil,y:nil,at:ProcessInfo.processInfo.systemUptime*1000)
        view.optimizationRefresh()
        for _ in 0..<600 {
            observations.append(view.optimizationDiagnostics)
            save("progress.json")
            if view.optimizationDiagnostics["atlasReady"] as? Bool == true ||
               !(view.optimizationDiagnostics["atlasRejection"] as? String ?? "").isEmpty { break }
            await pause(0.1)
        }
        check(abs(view.motion.pose.yaw)<0.00001 && abs(view.motion.pose.pitch)<0.00001,
              "Live neutral validation uses zero pointer deflection")
        check(view.optimizationDiagnostics["atlasReady"] as? Bool == true,
              "Live neutral atlas passes strict raster and full blink validation")
        var quietSince:Double?
        var quietCount=view.renderCount
        var quietVerified=false
        for _ in 0..<80 {
            let time=ProcessInfo.processInfo.systemUptime
            let state=view.optimizationDiagnostics
            if state["lampPlaying"] as? Bool == true &&
               state["inFlight"] as? Bool == false && view.renderCount==quietCount {
                quietSince=quietSince ?? time
                if time-(quietSince ?? time)>=1 { quietVerified=true;break }
            } else { quietSince=nil;quietCount=view.renderCount }
            await pause(0.05)
        }
        check(quietVerified,"Live idle lamp stops full-scene submissions between blinks")
        check(view.optimizationDiagnostics["lampPlaying"] as? Bool == true,
              "Live Core Animation player is installed")
        check((view.optimizationDiagnostics["atlasBytes"] as? Int ?? Int.max)<=512*1024,
              "Live patch cache fits its small working-set cap")
        if ProcessInfo.processInfo.environment["CLIPSLOTS_MASCOT_PROBE_HOLD"]=="1" {
            save("ready.json")
            return
        }
        if let root=view.window?.contentView {
            await runHeaderMascotProbe(root:root,directory:directory,check:check)
        }
        HeaderMascotSessionState.shared.togglePause()
        for _ in 0..<40 {
            await pause(0.05)
            if view.optimizationDiagnostics["inFlight"] as? Bool == false &&
               view.motion.reduceMotion { break }
        }
        let pausedCount=view.renderCount
        await pause(0.5)
        check(view.renderCount==pausedCount &&
              view.optimizationDiagnostics["lampPlaying"] as? Bool == false,
              "Pause stops scene submissions and removes layer animations")
        let rebuilt=HeaderMascotNativeView(frame:view.frame)
        check(rebuilt.optimizationDiagnostics["paused"] as? Bool == true,
              "Remount inherits process-session pause")
        rebuilt.dispose()
        view.motion.setActivity(.completed,at:ProcessInfo.processInfo.systemUptime*1000)
        view.optimizationRefresh();await pause(2)
        check(view.motion.activity == .idle,"Paused live completion expires on a single semantic wake")
        for _ in 0..<100 {
            HeaderMascotSessionState.shared.togglePause()
            await Task.yield()
        }
        await pause(0.2)
        check(view.optimizationDiagnostics["paused"] as? Bool == true,
              "One hundred reverse pause changes preserve final state")
        ResourceBudget.shared.setPressure(.critical);await pause(0.2)
        check(view.optimizationDiagnostics["atlasBytes"] as? Int == 0,
              "Critical pressure unloads lamp images and animation values")
        ResourceBudget.shared.setPressure(.normal)
        HeaderMascotSessionState.shared.togglePause()
        await pause(0.1)
        view.isHidden=true;await pause(0.15)
        let hidden=view.renderCount;await pause(0.2)
        check(view.renderCount==hidden && !view.activeTimer,
              "Hidden leaf rejects late frames and cancels all wakes")
        view.isHidden=false
        await pause(0.2)
        check(view.renderCount>hidden,"Unhide presents a fresh generation")
        observations.append(view.optimizationDiagnostics)
        save("report.json")
        NSApp.terminate(nil)
    }
}
#endif
