#!/usr/bin/env python3
"""Local evidence only: residual locations and static recording noise floor."""
import json
from pathlib import Path
import cv2
import numpy as np
import creative_visual_metrics as visual

OUT = visual.REPO / "build/research/creative-residual-20261006"
OUT.mkdir(parents=True, exist_ok=True)
native_root = visual.REPO / "build/research/creative-active-20261006/opacity-fine-clock"
report = json.loads((native_root / "glow-metrics.json").read_text())
origin = report["fixed_timeline"]["origin_seconds"]
video = cv2.VideoCapture(str(visual.VIDEO))


def frame(time):
    video.set(cv2.CAP_PROP_POS_MSEC, time * 1000)
    ok, image = video.read()
    assert ok
    return image


base = frame(90.0)[1470:1764, 1920:2872].astype(float)
roi = np.zeros(base.shape[:2], bool)
roi[55:275, 25:925] = True
quiet = roi & (base.max(axis=2) < 45)
y, x = np.indices(quiet.shape)
edge = np.minimum.reduce([x-12, 940-x, y-40, 282-y])
records = []
for time in [87.4, 87.6, 87.8, 88.0, 88.2, 88.4, 88.6]:
    ref = frame(time)[1470:1764, 1920:2872].astype(float)
    index = round((time-origin) / .01)
    image = cv2.imread(str(native_root / "glow" / f"glow-{index:02}.png"), cv2.IMREAD_UNCHANGED)
    alpha = image[:, :, 3:4] / 255.0
    prediction = image[:, :, :3] * alpha + base * (1-alpha)
    active = quiet & (ref.max(axis=2) < 125) & (
        ((ref-base).max(axis=2) > 4) | ((prediction-base).max(axis=2) > 4))
    zones = {}
    for name, mask in [
        ("all", active), ("near_edge", active & (edge < 35)),
        ("center", active & (edge >= 35)), ("upper", active & (y < 160)),
        ("lower", active & (y >= 160)),
    ]:
        difference = (prediction-ref)[mask]
        zones[name] = dict(pixels=int(mask.sum()), mae=float(np.abs(difference).mean()),
                           signed_bgr=difference.mean(axis=0).tolist(),
                           reference_energy=float(np.abs(ref-base)[mask].mean()),
                           share_of_abs_error=float(np.abs(difference).sum() / np.abs(prediction-ref)[active].sum()))
    records.append(dict(time=time, zones=zones))
static = []
for time in [89.6, 89.8, 90.2, 90.4, 90.6]:
    ref = frame(time)[1470:1764, 1920:2872].astype(float)
    mask = quiet & (ref.max(axis=2) < 45)
    diff = np.abs(ref-base)[mask]
    static.append(dict(time=time, mae=float(diff.mean()), p95=float(np.percentile(diff, 95)),
                       max=float(diff.max())))
white = []
for time in range(66, 81, 2):
    image = frame(time)[782:982, 1336:1536]
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    white.append(dict(time=time, bright_pixels=int((gray > 127).sum())))
    cv2.imwrite(str(OUT / f"white-{time}.png"), image)
video.release()
result = dict(scope="Diagnostic only; no fitting or acceptance threshold changes",
              blue_residuals=records, static_recording_deltas=static, later_white_presence=white)
(OUT / "residual-audit.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
