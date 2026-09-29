import Foundation
import CoreGraphics
import AppKit

// Independent event producer: inherits the terminal's granted event-posting permission.
// Post only while the isolated test app is foreground; stop if focus cannot be acquired.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let ready = directory.appendingPathComponent("mouse-ready")
guard CGPreflightPostEventAccess() else {
    try? "denied".write(to: ready, atomically: true, encoding: .utf8)
    exit(2)
}
try "ready".write(to: ready, atomically: true, encoding: .utf8)
var offset = 0
let deadline = Date().addingTimeInterval(180)
while Date() < deadline {
    let file = directory.appendingPathComponent("mouse-events.jsonl")
    if let text = try? String(contentsOf: file, encoding: .utf8) {
        let lines = text.split(separator: "\n")
        while offset < lines.count {
            guard let data = String(lines[offset]).data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = value["pid"] as? Int,
                  let number = value["window"] as? Int,
                  let rawType = value["type"] as? UInt32,
                  let type = CGEventType(rawValue: rawType),
                  let x = value["x"] as? Double, let y = value["y"] as? Double else { break }
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                      mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) else { exit(3) }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid_t(pid) {
                NSRunningApplication(processIdentifier: pid_t(pid))?.activate(options: [.activateIgnoringOtherApps])
                for _ in 0..<30 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid) { break }
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(pid) else { exit(4) }
            event.flags = CGEventFlags(rawValue: (value["flags"] as? UInt64) ?? 0)
            event.setIntegerValueField(.mouseEventClickState, value: Int64((value["clicks"] as? Int) ?? 1))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(number))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(number))
            event.post(tap: .cghidEventTap)
            offset += 1
        }
    }
    Thread.sleep(forTimeInterval: 0.01)
}
