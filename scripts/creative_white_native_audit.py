#!/usr/bin/env python3
"""Capture actual paused CA morph/breath clocks with ScreenCaptureKit.

No validation frame adjusts geometry, clock origin or relative breath phase.
The fixed-time captures measure pixels, not animation cadence.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

import cv2
import numpy as np
import creative_visual_metrics as v

OUT = v.REPO / "build/research/creative-residual-20261006/white-native"
SWIFT = r'''
import ScreenCaptureKit
_ = NSApplication.shared
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let mode = CommandLine.arguments[2]
let host = CreativeLoadingMark.Host(frame: CGRect(x: 18, y: 18, width: 64, height: 64))
class Surface: NSView { override var isFlipped: Bool { true } }
let surface = Surface(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
surface.wantsLayer = true; surface.layer?.backgroundColor = NSColor.black.cgColor
surface.addSubview(host); host.shape.fillColor = NSColor.white.cgColor
let window = NSWindow(contentRect: CGRect(x: 150, y: 200, width: 100, height: 100),
    styleMask: .borderless, backing: .buffered, defer: false)
window.isReleasedWhenClosed = false; window.contentView = surface
window.orderFront(nil); NSApp.activate(ignoringOtherApps: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
host.synchronize()
host.startAnimations()
guard let morph = host.shape.animation(forKey: "morph")?.copy() as? CAAnimation,
      let originalBreath = host.shape.animation(forKey: "breath")?.copy() as? CAAnimation else { throw CocoaError(.fileReadUnknown) }
let breath: CAAnimation
if mode == "baseline" {
    let segmented = CreativeMotion.keyframes("transform.scale", values: [0.95, 1.05, 0.95],
        times: [0, 0.5, 1], duration: 2, repeats: true)
    segmented.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 2)
    breath = segmented
} else if mode == "product" {
    breath = originalBreath
} else {
    let global = CreativeMotion.entranceOpacity([0.95, 1.05, 0.95],
        times: [0, 0.5, 1], curve: CAMediaTimingFunction(name: .easeInEaseOut))
    global.keyPath = "transform.scale"; global.duration = 2; global.repeatCount = .infinity
    breath = global
}
morph.beginTime = 1; breath.beginTime = 1
if mode == "global-lag" { breath.timeOffset = 2 - 0.19 }
host.shape.removeAllAnimations()
host.shape.speed = 0
host.shape.add(morph, forKey: "morph"); host.shape.add(breath, forKey: "breath")
var target: SCWindow?
var ready = false
Task { @MainActor in
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    target = content.windows.first(where: { $0.windowID == window.windowNumber })
    ready = true
}
while !ready { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
guard let target else { throw CocoaError(.fileReadUnknown) }
let filter = SCContentFilter(desktopIndependentWindow: target)
let configuration = SCStreamConfiguration()
configuration.width = 200; configuration.height = 200; configuration.showsCursor = false
configuration.colorSpaceName = CGColorSpace.sRGB
var states: [[String: Double]] = []
for index in 69..<360 {
    let time = 54 + Double(index) / 30
    if time > 58.05 && time < 58.6 { continue }
    CATransaction.begin(); CATransaction.setDisableActions(true)
    host.shape.timeOffset = 1 + time - 55.24
    CATransaction.commit(); CATransaction.flush()
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    var finished = false
    Task { @MainActor in
        defer { finished = true }
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: directory.appendingPathComponent(String(format: "%03d.png", index)))
            states.append(["time": time, "scale": Double(host.shape.presentation()?.transform.m11 ?? 0)])
        } catch { NSLog("Capture failed: %@", String(describing: error)) }
    }
    let deadline = Date().addingTimeInterval(10)
    while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    guard finished else { throw CocoaError(.fileReadUnknown) }
}
try JSONSerialization.data(withJSONObject: states, options: .prettyPrinted).write(to: directory.appendingPathComponent("states.json"))
window.close()
'''


def run(mode):
    directory = OUT / mode
    directory.mkdir(parents=True, exist_ok=True)
    source = (v.REPO / "Sources/ClipSlots/CreativeMotion.swift").read_text().split("struct ComposerEntranceGlow")[0]
    if mode == "product":
        geometry = (v.REPO / "Sources/ClipSlots/CreativeLoadingGeometry.swift").read_text()
    elif mode == "baseline":
        geometry = (v.OUT / "CreativeLoadingGeometry.swift").read_text()
    else:
        candidate = json.loads((OUT.parent / "white-breath/global_ease.json").read_text())
        rows = ["[" + ",".join(f"{n:.6f}" for n in row) + "]" for row in candidate["controls"]]
        geometry = "enum CreativeLoadingGeometry { static let harmonics = 8; static let controls: [[Double]] = [" + ",".join(rows) + "] }\n"
    runner = directory / "snapshot.swift"
    runner.write_text(source + geometry + SWIFT)
    subprocess.run(["swift", str(runner), str(directory), mode], check=True)
    images = v.recording()
    scores, contact = [], []
    for path in sorted(directory.glob("[0-9][0-9][0-9].png")):
        index = int(path.stem)
        ref = images[index]
        actual_image = cv2.imread(str(path), 0)
        assert actual_image.shape == ref.shape
        _, labels, stats, _ = cv2.connectedComponentsWithStats((ref > 127).astype(np.uint8))
        mask = labels == 1 + np.argmax(stats[1:, 4])
        actual = actual_image > 127
        union = actual | mask
        scores.append(dict(time=54+index/30, training=index < 249,
                           iou=float((actual & mask).sum()/union.sum()),
                           foreground_similarity=float(1-np.abs(actual_image.astype(float)-ref)[union].mean()/255)))
        if index >= 249 and index % 10 == 9:
            diff = np.zeros((200, 200, 3), np.uint8)
            diff[:, :, 1] = (actual & mask)*160; diff[:, :, 2] = (actual != mask)*255
            contact.append(np.hstack([cv2.cvtColor(ref, cv2.COLOR_GRAY2BGR),
                                      cv2.cvtColor(actual_image, cv2.COLOR_GRAY2BGR), diff]))
    result = dict(mode=mode, scope="Actual fixed-time SCK pixels; shared origin 55.24, no per-frame alignment. Not FPS or whole UI.",
                  training_iou=float(np.mean([r["iou"] for r in scores if r["training"]])),
                  validation_iou=float(np.mean([r["iou"] for r in scores if not r["training"]])),
                  validation_count=sum(not r["training"] for r in scores), scores=scores)
    (directory / "metrics.json").write_text(json.dumps(result, indent=2)+"\n")
    cv2.imwrite(str(directory / "contact.png"), np.vstack(contact))
    # #region debug-point G:white-native-clock
    import urllib.request
    url = os.environ.get("CLIPSLOTS_CREATIVE_DEBUG_URL")
    if url:
        body = dict(sessionId="creative-frame-cadence", runId=mode+"-sck", hypothesisId="G",
                    msg="[DEBUG] Native CA white clock pixels", data={k: val for k, val in result.items() if k != "scores"})
        urllib.request.urlopen(urllib.request.Request(url, data=json.dumps(body).encode(),
                               headers={"Content-Type": "application/json"}), timeout=5).read()
    # #endregion
    print(json.dumps({k: val for k, val in result.items() if k != "scores"}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["baseline", "global-shared", "global-lag", "product"])
    run(parser.parse_args().mode)
