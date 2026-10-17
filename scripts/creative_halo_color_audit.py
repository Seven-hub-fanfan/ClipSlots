#!/usr/bin/env python3
"""Color-only acceptance: preserve coverage and visible chroma, protect text."""
import argparse
import json
from pathlib import Path
import urllib.request

import numpy as np
from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser()
parser.add_argument("original", type=Path)
parser.add_argument("muted", type=Path)
parser.add_argument("current", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--debug-url")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
checks, measurements = {}, {}
luma = np.array([.2126, .7152, .0722])
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)

def image(folder, name):
    return Image.open(folder / name).convert("RGB")

for mode in ["canvas", "agent"]:
    stem = f"creative-halo-light-{mode}"
    shots = {name: image(folder, f"{stem}-8.png") for name, folder in [
        ("original", args.original), ("muted", args.muted), ("current", args.current)]}
    bg = (80, 1500, 880, 1570) if mode == "canvas" else (240, 1470, 1640, 1520)
    text = (40, 1580, 840, 1640) if mode == "canvas" else (180, 1560, 1720, 1620)
    results = {}
    for name, shot in shots.items():
        rgb = np.array(shot.crop(bg)).astype(float).mean(axis=(0, 1))
        results[name] = {"mean_rgb": rgb.tolist(), "blue_minus_red": float(rgb[2]-rgb[0])}
    idle = np.array(image(args.current, f"{stem}-25.png").crop(text)).astype(float)
    active = np.array(shots["current"].crop(text)).astype(float)
    ink = (idle @ luma < 125) & (np.ptp(idle, axis=2) < 12)
    assert ink.any()
    results["foreground_absolute_rgb_change"] = float(np.abs(active[ink]-idle[ink]).mean())
    results["chroma_vs_original"] = results["current"]["blue_minus_red"] / results["original"]["blue_minus_red"]
    results["chroma_vs_muted"] = results["current"]["blue_minus_red"] / results["muted"]["blue_minus_red"]
    checks[mode + "_visible_chroma_preserved"] = results["chroma_vs_original"] >= .95
    checks[mode + "_foreground_stable"] = results["foreground_absolute_rgb_change"] < 1
    for kind in ["bottom", "sweep"]:
        dark = np.array(Image.open(args.current / f"creative-halo-dark-{mode}-texture-{kind}.png").convert("RGBA"))
        light = np.array(Image.open(args.current / f"{stem}-texture-{kind}.png").convert("RGBA"))
        checks[f"{mode}_{kind}_alpha_identical"] = np.array_equal(dark[..., 3], light[..., 3])
        substantial = light[..., 3] > 32
        checks[f"{mode}_{kind}_bright_blue_retained"] = bool(substantial.any() and (light[..., 2][substantial] >= 254).all())
        results[kind + "_peak_alpha_0_255"] = int(light[..., 3].max())
    measurements[mode] = results
    for shade in ["light", "dark"]:
        current = np.array(image(args.current, f"creative-halo-{shade}-{mode}-8.png")).astype(float)
        switched = np.array(image(args.current, f"creative-halo-{shade}-{mode}-roundtrip.png")).astype(float)
        y = 1400 if mode == "canvas" else 1330
        delta = float(np.abs(current[y:] - switched[y:]).mean())
        checks[f"{shade}_{mode}_roundtrip_identical"] = delta == 0
        results[shade + "_roundtrip_delta"] = delta
        if shade == "dark":
            previous = np.array(image(args.muted, f"creative-halo-dark-{mode}-8.png")).astype(float)
            delta = float(np.abs(current[y:] - previous[y:]).mean())
            results["dark_composer_delta_from_21781109"] = delta
            checks[f"dark_{mode}_unchanged"] = delta == 0
    crops = []
    for shot in shots.values():
        cropped = shot.crop((0, 1350 if mode == "canvas" else 1270, shot.width, shot.height))
        crops.append(cropped.resize((760, round(cropped.height*760/cropped.width)), Image.Resampling.LANCZOS))
    cw, ch = crops[0].size
    board = Image.new("RGB", (cw*3 + 64, ch+106), "white")
    draw = ImageDraw.Draw(board)
    draw.text((16, 12), f"Light Agent / {mode} / same 0.8 s state", font=font, fill="#20252c")
    for i, (label, crop) in enumerate(zip(
            ["Original 21781108", "21781109 / too faint", "New / color corrected"], crops)):
        x = 16 + i*(cw+16)
        draw.text((x, 48), label, font=font, fill="#656b75")
        board.paste(crop, (x, 82))
    board.save(args.output / f"three-way-{mode}.png")

report = {
    "method": "Native fixed-state screenshot RGB; complete PNG alpha masks; no screen/FPS claim",
    "intent": "Preserve halo strength and geometry; change light-mode color, not reduce opacity",
    "measurements": measurements, "checks": checks, "passed": all(checks.values()),
}
(args.output / "color-audit.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
if args.debug_url:
    payload = {"sessionId": "light-agent-halo", "runId": "color-only-pixels", "hypothesisId": "A2-B2-C2-D2",
               "msg": "[DEBUG] Color-only halo intensity and hue acceptance", "data": report}
    urllib.request.urlopen(urllib.request.Request(args.debug_url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}), timeout=5).read()
print(json.dumps(report, ensure_ascii=False, indent=2))
raise SystemExit(0 if report["passed"] else 1)
