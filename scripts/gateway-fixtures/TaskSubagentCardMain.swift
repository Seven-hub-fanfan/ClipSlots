import AppKit
import SwiftUI
import Vision
import ClipSlotsKit

@main enum TaskSubagentCardMain {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2,
              CommandLine.arguments[1].hasPrefix("/tmp/clipslots-task-card-"),
              ProcessInfo.processInfo.environment["CLIPSLOTS_ISOLATED_CARD_RENDER"] == "1" else { exit(2) }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        _ = NSApplication.shared
        var rendering: [[String: Any]] = [], failures: [String] = []
        let plan = try AgentTaskPlanSnapshot(validating: ["schema_version": "agent_task_snapshot.v1", "plan_ready": true,
            "tasks": [["task_id": "one", "subject": "检查画布引用", "status": "completed"],
                      ["task_id": "two", "subject": "整理图像生成参数", "status": "in_progress"]]])
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width in [240, 480] {
                for status in ["plan", "running", "completed", "failed", "stopped", "ended_unknown"] {
                    var projection = AgentTaskSubagentProjection()
                    if status == "plan" {
                        _ = try projection.receiveTasks(plan, eventID: "plan", runID: "render", anchor: nil)
                    } else {
                        let payload: JSONValue = ["schema_version": "subagent_event.v1", "subagent_id": "child",
                            "parent_tool_call_id": "parent", "agent_type": "分析子任务",
                            "task_description": "检查引用与连线", "phase": "started"]
                        _ = try projection.receiveSubagent(payload, eventID: "start", runID: "render", anchor: nil)
                        var value = payload.objectValue!
                        value["phase"] = "content"; value["text"] = "已核对画布引用。"
                        _ = try projection.receiveSubagent(.object(value), eventID: "text|2", runID: "render", anchor: nil)
                        value["phase"] = "tool_completed"
                        value["tool_event"] = ["schema_version": "tool_event.v1", "type": "tool_event",
                            "tool_call_id": "tool", "tool": "Read", "status": "completed",
                            "request": ["path": "synthetic"], "response": "已读取"]
                        _ = try projection.receiveSubagent(.object(value), eventID: "tool|3", runID: "render", anchor: nil)
                        if status == "ended_unknown" { projection.finish(runID: "render") }
                        else if status != "running" {
                            value["phase"] = .string(status)
                            _ = try projection.receiveSubagent(.object(value), eventID: "end|4", runID: "render", anchor: nil)
                        }
                    }
                    let entry = projection.entries[0]
                    let name = "task-\(dark ? "dark" : "light")-\(width)-\(status)"
                    FileHandle.standardOutput.write(Data(("RENDER_BEGIN " + name + "\n").utf8))
                    let renderer = ImageRenderer(content: AgentTaskSubagentCard(entry: entry, expanded: true)
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
                    let expected: [String]
                    if status == "plan" { expected = ["任务计划", "计划已就绪", "检查画布引用", "整理图像生成参数"] }
                    else {
                        expected = [AgentSubagentState.Status(rawValue: status)!.label, "分析子任务", "已核对画布引用", "Read"]
                    }
                    if !expected.allSatisfy(text.contains) { failures.append(name + ": label or timeline unreadable") }
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
