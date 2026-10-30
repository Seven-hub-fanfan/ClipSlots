import AppKit
import SwiftUI
import Vision
import ClipSlotsKit

/// Dedicated synchronous rendering executable: compiles the actual production
/// card and palette. No App initialization, windows or production preferences.
@main enum CompactionCardMain {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2,
              CommandLine.arguments[1].hasPrefix("/tmp/clipslots-compact-card-"),
              ProcessInfo.processInfo.environment["CLIPSLOTS_ISOLATED_CARD_RENDER"] == "1"
        else { exit(2) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        guard FileManager.default.fileExists(atPath: directory.path) else { exit(2) }
        _ = NSApplication.shared
        var rendering: [[String: Any]] = [], failures: [String] = []
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width in [240, 480] {
                for phase: AgentContextCompactionPhase in [.started, .finished] {
                    var cards = AgentContextCompactionLifecycle()
                    cards.receive(phase, eventID: "render", runID: "synthetic")
                    let name = "compact-\(dark ? "dark" : "light")-\(width)-\(phase.rawValue)"
                    FileHandle.standardOutput.write(Data(("RENDER_BEGIN " + name + "\n").utf8))
                    let renderer = ImageRenderer(content: AgentCompactionCard(entry: cards.entries[0])
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .frame(width: CGFloat(width)).padding(8))
                    renderer.scale = 2
                    guard let image = renderer.cgImage,
                          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    else { failures.append(name + ": no image"); continue }
                    try png.write(to: directory.appendingPathComponent(name + ".png"))
                    let request = VNRecognizeTextRequest()
                    request.recognitionLanguages = ["zh-Hans", "en-US"]
                    request.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let text = (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined()
                    let expected = phase == .finished ? "上下文已压缩" : "正在压缩上下文"
                    if !text.contains(expected) { failures.append(name + ": label unreadable") }
                    rendering.append(["name": name, "width": image.width, "height": image.height,
                                      "recognizedText": text, "pngBytes": png.count, "gui": false])
                }
            }
        }
        if !NSApp.windows.isEmpty { failures.append("unexpected AppKit windows") }
        let report: [String: Any] = ["rendering": rendering, "passed": rendering.count - failures.count,
                                     "failures": failures, "gui": false, "remote": false, "providerRequests": 0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        exit(failures.isEmpty ? 0 : 1)
    }
}
