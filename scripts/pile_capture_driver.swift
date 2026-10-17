import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// A resident, independent capture process avoids stopping SwiftUI's main actor.
// Each result has wall-clock bounds; a request label is not a frame timestamp.
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let ready = directory.appendingPathComponent("capture-ready")
guard CGPreflightScreenCaptureAccess() else {
    try? "denied".write(to: ready, atomically: true, encoding: .utf8)
    exit(2)
}
try "ready".write(to: ready, atomically: true, encoding: .utf8)
func captureWindow(_ number: CGWindowID) async throws -> CGImage? {
    if #available(macOS 14.0, *) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == number }) else { return nil }
        let configuration = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
    } else {
        return CGWindowListCreateImage(.null, .optionIncludingWindow, number, .boundsIgnoreFraming)
    }
}
var offset = 0
let deadline = Date().addingTimeInterval(300)
while Date() < deadline {
    if let text = try? String(contentsOf: directory.appendingPathComponent("capture-requests.jsonl"), encoding: .utf8) {
        let lines = text.split(separator: "\n")
        while offset < lines.count {
            let request = try JSONSerialization.jsonObject(with: Data(lines[offset].utf8)) as! [String: Any]
            guard let name = request["name"] as? String,
                  name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil,
                  let number = request["window"] as? UInt32,
                  let pid = request["pid"] as? Int,
                  let app = NSRunningApplication(processIdentifier: pid_t(pid)),
                  app.bundleIdentifier == "com.clipslots.app.canvas-v2174-test" else { exit(5) }
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]]
            guard info?.first?[kCGWindowOwnerPID as String] as? Int == pid else { exit(6) }
            let started = Date().timeIntervalSince1970
            var result = request
            let destination = directory.appendingPathComponent(name + ".png")
            if let image = try? await captureWindow(number),
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try data.write(to: destination, options: .atomic)
                result["png"] = destination.lastPathComponent
                result["result"] = 0
            } else { result["result"] = 1 }
            result["startedUnixSeconds"] = started
            result["finishedUnixSeconds"] = Date().timeIntervalSince1970
            result["evidenceLimit"] = "Capture bounded by these wall-clock times, not by request label."
            let log = directory.appendingPathComponent("capture-results.jsonl")
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: log)
            handle.seekToEndOfFile()
            handle.write(try JSONSerialization.data(withJSONObject: result, options: .sortedKeys))
            handle.write(Data([10])); try handle.close()
            offset += 1
        }
    }
    try await Task.sleep(nanoseconds: 10_000_000)
}
