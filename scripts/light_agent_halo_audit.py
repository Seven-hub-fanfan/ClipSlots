#!/usr/bin/env python3
"""Compare native fixed-time composer captures; never infer screen FPS."""
import argparse
import json
from pathlib import Path
import urllib.request

import numpy as np
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser()
parser.add_argument("before", type=Path)
parser.add_argument("after", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--debug-url")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
weights = np.array([0.2126, 0.7152, 0.0722])
metrics = {}
checks = {}
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
for mode in ["canvas", "agent"]:
    name = f"creative-halo-light-{mode}"
    images = {}
    for label, folder in [("before", args.before), ("after", args.after)]:
        images[label] = {t: Image.open(folder / f"{name}-{t}.png").convert("RGB") for t in [8, 25]}
    width, height = images["before"][8].size
    # Fixed quiet interior + bottom toolbar. Identical coordinates for both runs.
    bg = (80, 1500, 880, 1570) if mode == "canvas" else (240, 1470, 1640, 1520)
    text = (40, 1580, 840, 1640) if mode == "canvas" else (180, 1560, 1720, 1620)
    idle = np.array(images["before"][25].crop(text)).astype(float)
    ink = (idle @ weights < 125) & (np.ptp(idle, axis=2) < 12)
    mode_metrics = {"background_roi": bg, "text_roi": text, "text_pixels": int(ink.sum())}
    assert ink.any(), "No foreground text sampled"
    for label in ["before", "after"]:
        on_bg, off_bg = [np.array(images[label][t].crop(bg)).astype(float) for t in [8, 25]]
        on_ink, off_ink = [np.array(images[label][t].crop(text)).astype(float)[ink] for t in [8, 25]]
        mode_metrics[label] = {
            "active_background_rgb": on_bg.mean(axis=(0, 1)).tolist(),
            "idle_background_rgb": off_bg.mean(axis=(0, 1)).tolist(),
            "background_luminance_drop_0_255": float(((off_bg-on_bg) @ weights).mean()),
            "foreground_luminance_change_0_255": float(((on_ink-off_ink) @ weights).mean()),
            "foreground_absolute_rgb_change": float(np.abs(on_ink-off_ink).mean()),
        }
    checks[mode + "_light_background_drop_below_5"] = mode_metrics["after"]["background_luminance_drop_0_255"] < 5
    checks[mode + "_foreground_change_below_1"] = mode_metrics["after"]["foreground_absolute_rgb_change"] < 1
    mode_metrics["background_drop_reduction_percent"] = 100 * (
        1 - mode_metrics["after"]["background_luminance_drop_0_255"] /
        mode_metrics["before"]["background_luminance_drop_0_255"])
    metrics[mode] = mode_metrics
    top = 1350 if mode == "canvas" else 1270
    crop = (0, top, width, height)
    crops = [images[label][8].crop(crop) for label in ["before", "after"]]
    # Preserve each screenshot's aspect ratio and use the same scale.
    for i, image in enumerate(crops):
        if image.width > 960:
            crops[i] = image.resize((960, round(image.height * 960 / image.width)), Image.Resampling.LANCZOS)
    cw, ch = crops[0].size
    board = Image.new("RGB", (cw*2 + 48, ch + 110), "#ffffff")
    draw = ImageDraw.Draw(board)
    draw.text((16, 12), f"Light Agent / {mode} / same 0.8 s animation state", fill="#20252c", font=font)
    for i, label in enumerate(["BEFORE", "AFTER"]):
        x = 16 + i*(cw+16)
        draw.text((x, 48), label, fill="#656b75", font=font)
        board.paste(crops[i], (x, 84))
    board.save(args.output / f"before-after-{mode}.png")

roundtrips = {}
dark_backgrounds = {}
for mode in ["canvas", "agent"]:
    for shade in ["light", "dark"]:
        name = f"creative-halo-{shade}-{mode}"
        current = np.array(Image.open(args.after / f"{name}-8.png").convert("RGB")).astype(float)
        returned = args.after / f"{name}-roundtrip.png"
        if returned.exists():
            switched = np.array(Image.open(returned).convert("RGB")).astype(float)
            y = 1400 if mode == "canvas" else 1330
            delta = float(np.abs(current[y:] - switched[y:]).mean())
            roundtrips[f"{shade}-{mode}"] = delta
            checks[f"{shade}_{mode}_theme_roundtrip_below_1"] = delta < 1
        if shade == "dark":
            previous = np.array(Image.open(args.before / f"{name}-8.png").convert("RGB")).astype(float)
            x0, y0, x1, y1 = metrics[mode]["background_roi"]
            delta = float(np.abs(current[y0:y1, x0:x1] - previous[y0:y1, x0:x1]).mean())
            dark_backgrounds[mode] = delta
            checks[f"dark_{mode}_background_change_below_1"] = delta < 1

report = {
    "method": "AppKit cacheDisplay; real product keyframe scalars at 0.8 s and 2.5 s, same native bounds",
    "scope": "Local compositing regression, not screen capture, FPS or global reference similarity",
    "metrics": metrics, "theme_roundtrip_mean_rgb_delta": roundtrips,
    "dark_background_mean_rgb_delta": dark_backgrounds,
    "checks": checks, "passed": all(checks.values()),
}
(args.output / "pixel-comparison.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
if args.debug_url:
    event = {"sessionId": "light-agent-halo", "runId": "post-fix-pixels", "hypothesisId": "A-D",
             "msg": "[DEBUG] Matched native composer before/after pixels", "data": report}
    urllib.request.urlopen(urllib.request.Request(
        args.debug_url, data=json.dumps(event).encode(), headers={"Content-Type": "application/json"}), timeout=5).read()
print(json.dumps(report, ensure_ascii=False, indent=2))
raise SystemExit(0 if report["passed"] else 1)
