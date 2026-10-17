#!/usr/bin/env python3
"""Recording-derived contour research and native-raster comparison.

Training and held-out time ranges are disjoint. Scores use the foreground union,
not the large black window. This measures the loading mark, never the whole UI.
No TapNow bundle assets are read or shipped.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

import cv2
import numpy as np

REPO = Path(__file__).resolve().parent.parent
VIDEO = Path("/Users/bytedance/Library/Application Support/LarkShell/screenshot/20261005104323_rec_.mp4")
OUT = REPO / "build/research/creative-optimization-20261005"
ORIGIN = 55.24
PERIOD = 3.44
HARMONICS = 8
KNOTS = 43


def recording():
    OUT.mkdir(parents=True, exist_ok=True)
    cached = OUT / "white-recording.npy"
    if cached.exists():
        return np.load(cached)
    capture = cv2.VideoCapture(str(VIDEO))
    assert (capture.get(3), capture.get(4), capture.get(5)) == (2872, 1764, 30)
    capture.set(cv2.CAP_PROP_POS_FRAMES, 54 * 30)
    images = []
    for _ in range(360):
        ok, bgr = capture.read()
        assert ok
        images.append(cv2.cvtColor(bgr[782:982, 1336:1536], cv2.COLOR_BGR2GRAY))
    capture.release()
    images = np.array(images)
    np.save(cached, images)
    return images


def rays(images):
    angles = np.arange(256) * (2 * np.pi / 256)
    radius = np.arange(0, 98, 0.125)
    x = (99.5 + np.cos(angles[:, None]) * radius).astype(np.float32)
    y = (99.5 + np.sin(angles[:, None]) * radius).astype(np.float32)
    result = []
    for image in images:
        n, labels, stats, _ = cv2.connectedComponentsWithStats((image > 127).astype(np.uint8))
        component = 1 + np.argmax(stats[1:, 4]) if n > 1 else 0
        clean = image * (labels == component)
        values = cv2.remap(clean, x, y, cv2.INTER_LINEAR).astype(float) / max(1, float(clean.max()))
        last = np.max(np.where(values > 0.5, np.arange(len(radius)), 0), axis=1)
        lo, hi = values[np.arange(256), last], values[np.arange(256), np.minimum(last + 1, len(radius) - 1)]
        result.append(radius[last] + 0.125 * (lo - 0.5) / np.maximum(1e-8, lo - hi))
    return np.array(result), angles


def basis(time):
    """Periodic cubic B-spline; fixed topology without per-frame fitting."""
    t = np.mod((time - ORIGIN) / PERIOD, 1) * KNOTS
    i, u = np.floor(t).astype(int), t % 1
    weights = np.array([(1-u)**3, 3*u**3-6*u**2+4, -3*u**3+3*u**2+3*u+1, u**3]).T / 6
    matrix = np.zeros((len(time), KNOTS))
    for j in range(4):
        matrix[np.arange(len(time)), (i + j - 1) % KNOTS] = weights[:, j]
    return matrix


def fit():
    images = recording()
    radial, angles = rays(images)
    time = 54 + np.arange(len(images)) / 30
    train = (time >= 56.3) & (time < 62.3) & ~((time > 58.05) & (time < 58.6))
    # Cross-cycle scale ratios separate the independent 2-second breath from
    # geometry. Median over directions is resistant to cursor/codec edge noise.
    starts = np.arange(56.4, 58.7, 1 / 30)
    first = np.array([np.interp(starts, time, radial[:, j]) for j in range(256)]).T
    second = np.array([np.interp(starts + PERIOD, time, radial[:, j]) for j in range(256)]).T
    ratio = np.median(second / np.maximum(first, 1), axis=1)
    candidates = []
    for phase in np.arange(54, 56, 0.01):
        predicted = (1 - .05 * np.cos(np.pi * (starts + PERIOD - phase))) / (1 - .05 * np.cos(np.pi * (starts - phase)))
        candidates.append((np.median(abs(predicted - ratio)), phase))
    breath_origin = min(candidates)[1]
    breath = 1 - .05 * np.cos(np.pi * (time - breath_origin))
    spatial = np.column_stack([np.ones(256)] + [f(angles * h) for h in range(1, HARMONICS + 1) for f in (np.cos, np.sin)])
    coefficients = (radial / breath[:, None] / 128) @ np.linalg.pinv(spatial).T
    matrix = basis(time)
    difference = np.eye(KNOTS) - 2 * np.roll(np.eye(KNOTS), 1, axis=1) + np.roll(np.eye(KNOTS), 2, axis=1)
    controls = np.linalg.lstsq(np.vstack([matrix[train], .08 * difference]),
                             np.vstack([coefficients[train], np.zeros((KNOTS, 1 + HARMONICS * 2))]), rcond=None)[0]
    payload = dict(origin=ORIGIN, period=PERIOD, breath_origin=breath_origin, harmonics=HARMONICS,
                   knots=KNOTS, controls=controls.tolist(),
                   training_seconds=[56.3, 62.3], excluded_cursor_seconds=[58.05, 58.6],
                   held_out_seconds=[62.3, 65.9666667], recording=str(VIDEO),
                   recording_sha256=hashlib.sha256(VIDEO.read_bytes()).hexdigest())
    (OUT / "contour-fit.json").write_text(json.dumps(payload, indent=2) + "\n")
    # Export coefficients only: compact geometric measurements, no bitmap frames.
    lines = ["// Measured from the user-supplied recording; see scripts/creative_visual_metrics.py.",
             "// Periodic radial harmonics, normalized to a 64pt loading frame.",
             "import Foundation", "", "enum CreativeLoadingGeometry {",
             f"    static let harmonics = {HARMONICS}",
             "    static let controls: [[Double]] = ["]
    lines += ["        [" + ", ".join(f"{v:.6f}" for v in row) + "]," for row in controls]
    lines += ["    ]", "}", ""]
    (OUT / "CreativeLoadingGeometry.swift").write_text("\n".join(lines))
    print(json.dumps({k: v for k, v in payload.items() if k != "controls"}, indent=2))


def render(label):
    """Compile the actual product path generator, not a Python approximation."""
    source = (REPO / "Sources/ClipSlots/CreativeMotion.swift").read_text().split("/// Stops all repeating work")[0]
    geometry = REPO / "Sources/ClipSlots/CreativeLoadingGeometry.swift"
    if geometry.exists():
        source += geometry.read_text()
    directory = OUT / label
    directory.mkdir(exist_ok=True)
    source += r'''
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let space = CGColorSpace(name: CGColorSpace.sRGB)!
for i in 0..<344 {
    let context = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    context.translateBy(x: 36, y: 164); context.scaleBy(x: 1, y: -1)
    context.setFillColor(NSColor.white.cgColor)
    context.addPath(CreativeMotion.loadingPath(phase: Double(i) / 344, size: 128)); context.fillPath()
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(String(format: "%03d.png", i)))
}
'''
    runner = OUT / "native-contour-render.swift"
    runner.write_text(source)
    subprocess.run(["swift", str(runner), str(directory)], check=True)


def compare(label):
    images = recording()
    fit_info = json.loads((OUT / "contour-fit.json").read_text())
    native = np.array([cv2.imread(str(OUT / label / f"{i:03}.png"), 0) for i in range(344)])
    records, contacts = [], []
    # Single global phase alignment may be fitted to training only. Baseline
    # receives the same opportunity, not an intentionally unfavourable phase.
    def metrics(index, offset):
        time = 54 + index / 30
        phase = ((time - ORIGIN + offset) % PERIOD) / PERIOD
        image = native[int(round(phase * 344)) % 344]
        breath = 1 - .05 * np.cos(np.pi * (time - fit_info["breath_origin"]))
        image = cv2.warpAffine(image, cv2.getRotationMatrix2D((99.5, 99.5), 0, breath), (200, 200))
        ref = images[index]
        _, components, stats, _ = cv2.connectedComponentsWithStats((ref > 127).astype(np.uint8))
        mask = components == 1 + np.argmax(stats[1:, 4])
        actual = image > 127
        union = actual | mask
        iou = np.sum(actual & mask) / max(1, np.sum(union))
        mae = np.mean(abs(image.astype(float)[union] - ref.astype(float)[union])) / 255
        return iou, mae, image, mask
    training = [i for i in range(70, 249, 3) if not 58.05 < 54+i/30 < 58.6]
    offsets = np.arange(-0.16, .161, .01) if label != "baseline" else np.arange(-.8, .801, .01)
    alignment = max((np.mean([metrics(i, shift)[0] for i in training]), shift) for shift in offsets)[1]
    for i in range(249, 360):
        iou, mae, image, mask = metrics(i, alignment)
        records.append(dict(time=54+i/30, silhouette_iou=float(iou), foreground_color_similarity=float(1-mae)))
        if (i-249) % 10 == 0:
            rgb = cv2.cvtColor(images[i], cv2.COLOR_GRAY2BGR)
            predicted = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
            diff = np.zeros_like(rgb); diff[:, :, 1] = (mask & (image > 127)) * 160
            diff[:, :, 2] = (mask != (image > 127)) * 255
            contacts.append(np.hstack([rgb, predicted, diff]))
    cv2.imwrite(str(OUT / f"{label}-heldout-contact.png"), np.vstack(contacts))
    score = dict(component="white loading silhouette", label=label, global_alignment_seconds=float(alignment),
                 heldout_frame_count=len(records), heldout_interval=[62.3, 65.9666667],
                 mean_silhouette_iou=float(np.mean([r["silhouette_iou"] for r in records])),
                 p05_silhouette_iou=float(np.percentile([r["silhouette_iou"] for r in records],5)),
                 mean_foreground_color_similarity=float(np.mean([r["foreground_color_similarity"] for r in records])),
                 scores=records, limits="One 30fps recording, fixed registration at (1436,882), 2x scale. Excludes background. Not whole-UI fidelity.")
    (OUT / f"{label}-metrics.json").write_text(json.dumps(score, indent=2) + "\n")
    print(json.dumps({k: v for k, v in score.items() if k != "scores"}, indent=2))


def glow(sample_step=0.05):
    directory = OUT / "glow"
    directory.mkdir(exist_ok=True)
    source = (REPO / "Sources/ClipSlots/CreativeMotion.swift").read_text().split("struct CreativeWelcomeReveal")[0]
    source += (REPO / "Sources/ClipSlots/CreativeLoadingGeometry.swift").read_text()
    source += (REPO / "scripts/creative_glow_snapshot.swift").read_text()
    runner = OUT / "native-glow-render.swift"
    runner.write_text(source)
    subprocess.run(["swift", str(runner), str(directory), str(sample_step)], check=True)
    if os.environ.get("CREATIVE_DIAGNOSTIC_SCREEN") == "1":
        print(f"Screen calibration images: {directory}")
        return
    capture = cv2.VideoCapture(str(VIDEO))
    refs = {}
    for seconds in np.arange(87.4, 90.01, .1):
        capture.set(cv2.CAP_PROP_POS_MSEC, seconds * 1000)
        ok, frame = capture.read()
        assert ok
        refs[round(float(seconds), 1)] = frame[1470:1764, 1920:2872]
    capture.release()
    base = refs[90.0].astype(float)
    native = [cv2.imread(str(directory / f"glow-{i:02d}.png"), cv2.IMREAD_UNCHANGED)
              for i in range(round(2.5 / sample_step) + 1)]
    # Evaluate only the inner color wash, where baseline has no text or buttons.
    roi = np.zeros(base.shape[:2], bool); roi[55:275, 25:925] = True
    quiet = roi & (base.max(axis=2) < 45)
    results = []
    for time in [87.8, 88.0, 88.2, 88.4, 88.6]:
        ref = refs[time].astype(float)
        clean = quiet & (ref.max(axis=2) < 125)
        candidates = []
        for i, image in enumerate(native):
            alpha = image[:, :, 3:4].astype(float) / 255
            composite = image[:, :, :3] * alpha + base * (1-alpha)
            active = clean & (((ref-base).max(axis=2) > 4) | ((composite-base).max(axis=2) > 4))
            error = float(np.abs(composite-ref)[active].sum())
            energy = float(np.abs(ref-base)[active].sum())
            candidates.append((error / max(1, energy), i, composite, active))
        relative_error, index, prediction, active = min(candidates, key=lambda entry: entry[0])
        error = float(np.abs(prediction-ref)[active].mean())
        results.append(dict(recording_seconds=time, native_seconds=index*sample_step,
                            mean_channel_error_255=error, color_similarity=1-error/255,
                            effect_similarity=max(0, 1-relative_error),
                            active_pixels=int(active.sum())))
        difference = np.clip(abs(prediction-ref)*4, 0, 255).astype(np.uint8)
        cv2.imwrite(str(directory / f"compare-{time:.1f}.png"),
                    np.vstack([ref.astype(np.uint8), prediction.astype(np.uint8), difference]))
    report = dict(component="blue inner wash", measurements=results, native_sample_step_seconds=sample_step,
                  mean_color_similarity=float(np.mean([r["color_similarity"] for r in results])),
                  mean_effect_similarity=float(np.mean([r["effect_similarity"] for r in results])),
                  scope="Per-frame nearest phase, RGB MAE on union of active quiet input pixels. Effect similarity normalizes error by reference glow energy; no glow scores zero. Diagnostic only; not temporal acceptance or whole-UI fidelity.")
    # Also expose the stricter result with one start time learned only on the
    # first part of the sweep. Never align each validation frame separately.
    def fixed_score(seconds, origin):
        ref = refs[seconds].astype(float)
        index = int(np.clip(round((seconds-origin)/sample_step), 0, len(native)-1))
        image = native[index]
        alpha = image[:, :, 3:4].astype(float) / 255
        prediction = image[:, :, :3] * alpha + base * (1-alpha)
        clean = quiet & (ref.max(axis=2) < 125)
        active = clean & (((ref-base).max(axis=2) > 4) | ((prediction-base).max(axis=2) > 4))
        error = float(np.abs(prediction-ref)[active].sum())
        energy = float(np.abs(ref-base)[active].sum())
        return error / max(1, energy)
    training = [87.4, 87.6, 87.8]
    origin = min(np.arange(86, 87.41, sample_step / 2),
                 key=lambda start: np.mean([fixed_score(t, start) for t in training]))
    validation = [dict(recording_seconds=t, effect_similarity=max(0, 1-fixed_score(t, origin)))
                  for t in [88.0, 88.2, 88.4, 88.6]]
    report["fixed_timeline"] = dict(
        origin_seconds=float(origin), training_seconds=training, validation=validation,
        mean_effect_similarity=float(np.mean([r["effect_similarity"] for r in validation])),
        limits="One fixed origin; offscreen wash only, excludes outer shadows and actual display cadence.")
    (OUT / "glow-metrics.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["fit", "render", "compare", "glow"])
    parser.add_argument("--label", default="optimized")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--glow-step", type=float, choices=[0.01, 0.05], default=0.05)
    args = parser.parse_args()
    if args.output_dir:
        OUT = args.output_dir.resolve()
        OUT.mkdir(parents=True, exist_ok=True)
    if args.command == "fit":
        fit()
    elif args.command == "render":
        render(args.label)
    elif args.command == "glow":
        glow(args.glow_step)
    else:
        compare(args.label)
