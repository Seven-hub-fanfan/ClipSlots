import AppKit
import ApplicationServices
import Foundation

// Keep the permission identity of the terminal harness; the isolated test app
// intentionally has a different bundle ID and no inherited accessibility grant.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let ready = directory.appendingPathComponent("ax-ready")
guard AXIsProcessTrusted() else {
    try? "denied".write(to: ready, atomically: true, encoding: .utf8)
    exit(2)
}
try "ready".write(to: ready, atomically: true, encoding: .utf8)
var offset = 0
let deadline = Date().addingTimeInterval(300)
while Date() < deadline {
    let requests = directory.appendingPathComponent("ax-button-requests.jsonl")
    if let text = try? String(contentsOf: requests, encoding: .utf8) {
        let lines = text.split(separator: "\n")
        while offset < lines.count {
            let value = try JSONSerialization.jsonObject(with: Data(lines[offset].utf8)) as! [String: Any]
            guard let pid = value["pid"] as? Int, let identifier = value["identifier"] as? String,
                  let token = value["token"] as? String, UUID(uuidString: token) != nil,
                  let app = NSRunningApplication(processIdentifier: pid_t(pid)),
                  app.bundleIdentifier == "com.clipslots.app.canvas-v2174-test" else { exit(5) }
            let root = AXUIElementCreateApplication(pid_t(pid))
            _ = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            var diagnostic: [[String: String]] = []
            var visited = 0
            func visit(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
                guard depth < 40 else { return nil }
                visited += 1
                var id: CFTypeRef?; var role: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, "AXIdentifier" as CFString, &id)
                _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                let name = id as? String ?? ""
                if name.contains("gallery") || name.contains("pile-") {
                    diagnostic.append(["identifier": name, "role": role as? String ?? ""])
                }
                if name == identifier && role as? String == kAXButtonRole as String { return element }
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                   let array = children as? [AXUIElement] {
                    for child in array { if let found = visit(child, depth + 1) { return found } }
                }
                return nil
            }
            var windows: CFTypeRef?
            let windowsError = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows)
            let windowList = windows as? [AXUIElement] ?? []
            var target = visit(root, 0)
            if target == nil {
                for window in windowList { if let found = visit(window, 0) { target = found; break } }
            }
            let result = target.map { AXUIElementPerformAction($0, kAXPressAction as CFString).rawValue } ?? -1
            let output: [String: Any] = ["identifier": identifier, "token": token, "result": result,
                                        "trusted": true, "tree": diagnostic, "visitedElements": visited,
                                        "windowsError": windowsError.rawValue, "windowCount": windowList.count]
            try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("ax-button-\(token).json"), options: .atomic)
            offset += 1
        }
    }
    Thread.sleep(forTimeInterval: 0.01)
}
