// macOS JXA input check. Coordinates must come from a fresh fixture screenshot.
// Usage: osascript -l JavaScript verify-attachment-drag.js PID WINDOW_ID x,y x,y[,holdSeconds] ...
ObjC.import("Cocoa");
ObjC.import("CoreGraphics");
function run(args) {
    const pid = Number(args[0]), windowID = Number(args[1]);
    const windows = ObjC.deepUnwrap(ObjC.castRefToObject(
        $.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, $.kCGNullWindowID)));
    const target = windows.find(w => w.kCGWindowNumber === windowID && w.kCGWindowOwnerPID === pid);
    if (!target) throw Error("Observed fixture window no longer exists");
    const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(pid);
    if (ObjC.unwrap(app.bundleIdentifier) !== "com.clipslots.app.attachment-regression")
        throw Error("Only the isolated attachment fixture may receive test events");
    if (ObjC.unwrap($.NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier) === "com.apple.loginwindow")
        throw Error("The desktop is locked; mouse input cannot validate the fixture");
    const capture = args.find(s => s.startsWith("--capture="))?.slice(10);
    if (capture && !capture.startsWith("/private/tmp/clipslots-editor-"))
        throw Error("Screenshots must stay in the isolated fixture output");
    const points = args.slice(2).filter(s => !s.startsWith("--capture=")).map(s => s.split(",").map(Number));
    const b = target.kCGWindowBounds;
    if (points.some(p => p[0] < b.X || p[0] > b.X+b.Width || p[1] < b.Y || p[1] > b.Y+b.Height))
        throw Error("A point is outside the observed window");
    app.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
    delay(0.2);
    if (!app.active || $.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier !== pid)
        throw Error("Fixture did not become the active application; no mouse events sent");
    function event(type, p) {
        const e = $.CGEventCreateMouseEvent(null, type, $.CGPointMake(p[0],p[1]), $.kCGMouseButtonLeft);
        $.CGEventPost($.kCGHIDEventTap, e);
    }
    let last = points[0];
    event($.kCGEventMouseMoved,last);
    event($.kCGEventLeftMouseDown,last);
    try {
        delay(0.08);
        for (const next of points.slice(1)) {
            for (let i=1; i<=24; ++i) {
                event($.kCGEventLeftMouseDragged, [last[0]+(next[0]-last[0])*i/24,last[1]+(next[1]-last[1])*i/24]);
                delay(0.012);
            }
            last = next;
            if (next[2]) {
                if (capture) {
                    const task = $.NSTask.alloc.init;
                    task.launchPath = "/usr/sbin/screencapture";
                    task.arguments = ["-x", "-R"+[b.X,b.Y,b.Width,b.Height].join(","), capture];
                    task.launch;
                    task.waitUntilExit;
                }
                delay(next[2]);
            }
        }
    } finally {
        event($.kCGEventLeftMouseUp,last);
    }
    return JSON.stringify({pid,windowID,points,eventSequenceDelivered:true});
}
