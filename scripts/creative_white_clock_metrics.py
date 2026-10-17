#!/usr/bin/env python3
"""Audit the loading mark with a shared morph/breath clock.

Uses previously rasterized native contours; this is a temporal diagnostic,
not an actual display capture. The held-out range never tunes parameters.
"""
import json
from pathlib import Path
import cv2
import numpy as np
import creative_visual_metrics as visual

ROOT = visual.REPO
OUT = ROOT / "build/research/creative-active-20261006/white-clock"
OUT.mkdir(parents=True, exist_ok=True)
fit = json.loads((visual.OUT / "contour-fit.json").read_text())
images = visual.recording()
native = np.array([cv2.imread(str(visual.OUT / "optimized" / f"{i:03}.png"), 0) for i in range(344)])
masks = []
for ref in images:
    _, components, stats, _ = cv2.connectedComponentsWithStats((ref > 127).astype(np.uint8))
    masks.append(components == 1 + np.argmax(stats[1:, 4]) if len(stats) > 1 else np.zeros_like(ref, dtype=bool))


def ease(x):
    lo, hi = 0.0, 1.0
    for _ in range(24):
        t = (lo + hi) / 2
        value = 3 * (1-t)**2 * t * .42 + 3 * (1-t) * t*t * .58 + t**3
        if value < x:
            lo = t
        else:
            hi = t
    t = (lo + hi) / 2
    return 3 * (1-t) * t*t + t**3


def score(index, alignment, lag, independent=False):
    time = 54 + index / 30
    elapsed = time - visual.ORIGIN + alignment
    phase = elapsed % visual.PERIOD / visual.PERIOD
    if independent:
        scale = 1 - .05 * np.cos(np.pi * (time-fit["breath_origin"]))
    else:
        breath = (elapsed - lag) % 2
        scale = .95 + .1 * ease(breath) if breath < 1 else 1.05 - .1 * ease(breath - 1)
    image = native[int(round(phase * 344)) % 344]
    image = cv2.warpAffine(image, cv2.getRotationMatrix2D((99.5, 99.5), 0, scale), (200, 200))
    mask = masks[index]
    actual = image > 127
    return float((actual & mask).sum() / max(1, (actual | mask).sum()))


training = [i for i in range(70, 249, 3) if not 58.05 < 54+i/30 < 58.6]
validation = list(range(249, 360))
variants = [
    ("previous_geometry_diagnostic", 0, True),
    ("current_shared_clock", 0, False),
    ("training_derived_breath_lag", fit["breath_origin"] - visual.ORIGIN, False),
]
result = {
    "scope": "Native contour rasters with simulated CA easeInEaseOut breath; not display pixels or whole UI",
    "training_seconds": [56.3, 62.3], "validation_seconds": [62.3, 65.9666667],
    "variants": [],
}
for label, lag, independent in variants:
    alignment = max((np.mean([score(i, shift, lag, independent) for i in training]), float(shift))
                    for shift in np.arange(-.16, .161, .01))[1]
    values = [score(i, alignment, lag, independent) for i in validation]
    result["variants"].append(dict(label=label, breath_lag_seconds=lag, alignment_seconds=alignment,
                                   mean_iou=float(np.mean(values)), p05_iou=float(np.percentile(values, 5))))
(OUT / "metrics.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
