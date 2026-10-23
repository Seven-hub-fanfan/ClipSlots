import Foundation
import CoreGraphics
import AppKit

// Independent event producer: inherits the terminal's granted event-posting permission.
// Post only while the isolated test app is foreground; stop if focus cannot be acquired.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let ready = directory.appendingPathComponent("mouse-ready")
func stop(_ code: Int32, _ reason: String) -> Never {
    let row: [String: Any] = ["exitCode": code, "reason": reason,
        "unixSeconds": Date().timeIntervalSince1970]
    try? JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
        .write(to: directory.appendingPathComponent("mouse-driver-result.json"), options: .atomic)
    exit(code)
}
guard CGPreflightPostEventAccess() else {
    try? "denied".write(to: ready, atomically: true, encoding: .utf8)
    stop(2, "event posting permission unavailable")
}
func requireUnlockedSession() {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    if session?["CGSSessionScreenIsLocked"] as? Bool == true {
        try? "screen-locked".write(to: ready, atomically: true, encoding: .utf8)
        stop(6, "desktop locked during input")
    }
}
requireUnlockedSession()
try "ready".write(to: ready, atomically: true, encoding: .utf8)
var offset = 0
let deadline = Date().addingTimeInterval(180)
while Date() < deadline {
    let file = directory.appendingPathComponent("mouse-events.jsonl")
    if let text = try? String(contentsOf: file, encoding: .utf8) {
        let lines = text.split(separator: "\n")
        while offset < lines.count {
            requireUnlockedSession()
            guard let data = String(lines[offset]).data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = value["pid"] as? Int,
                  let number = value["window"] as? Int,
                  let rawType = value["type"] as? UInt32,
                  let type = CGEventType(rawValue: rawType) else { break }
            guard let app = NSRunningApplication(processIdentifier: pid_t(pid)),
                  app.bundleIdentifier == "com.clipslots.app.canvas-v2174-test" else {
                stop(5, "isolated input target unavailable")
            }
            let produced: CGEvent?
            if type == .keyDown || type == .keyUp, let code = value["keyCode"] as? UInt16 {
                produced = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown)
            } else if let x = value["x"] as? Double, let y = value["y"] as? Double {
                produced = CGEvent(mouseEventSource: nil, mouseType: type,
                                   mouseCursorPosition: CGPoint(x: x, y: y),
                                   mouseButton: type == .rightMouseDown || type == .rightMouseUp ? .right : .left)
            } else { stop(3, "invalid event request") }
            guard let event = produced else { stop(3, "event creation unavailable") }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid_t(pid) {
                app.activate(options: [.activateIgnoringOtherApps])
                for _ in 0..<30 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid) { break }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                // Background activate requests can be declined by macOS.
                // LaunchServices brings this already-running isolated bundle
                // forward without starting a second probe or changing its data.
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid_t(pid),
                   let bundle = app.bundleURL, bundle.path.hasPrefix("/tmp/clipslots-v2174-") {
                    let activate = Process()
                    activate.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    activate.arguments = ["-a", bundle.path]
                    try activate.run()
                    for _ in 0..<100 {
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid) { break }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid) else {
                stop(4, "isolated input target cannot acquire foreground")
            }
            event.flags = CGEventFlags(rawValue: (value["flags"] as? UInt64) ?? 0)
            event.setIntegerValueField(.mouseEventClickState, value: Int64((value["clicks"] as? Int) ?? 1))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(number))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(number))
            event.setIntegerValueField(.eventSourceUserData, value: Int64(offset + 1))
            event.post(tap: .cghidEventTap)
            let result: [String: Any] = ["sourceIndex": offset + 1, "type": rawType,
                "window": number, "pid": pid, "postedUnixSeconds": Date().timeIntervalSince1970]
            let log = directory.appendingPathComponent("mouse-acks.jsonl")
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: log) {
                handle.seekToEndOfFile()
                handle.write(try JSONSerialization.data(withJSONObject: result))
                handle.write(Data([10])); try? handle.close()
            }
            if let token = value["token"] as? String, UUID(uuidString: token) != nil {
                try JSONSerialization.data(withJSONObject: result)
                    .write(to: directory.appendingPathComponent("mouse-ack-\(token).json"), options: .atomic)
            }
            offset += 1
        }
    }
    Thread.sleep(forTimeInterval: 0.01)
}
stop(7, "input driver deadline expired")
