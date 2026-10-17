#!/usr/bin/env python3
"""Compare global vs per-segment breathing without tuning on held-out frames."""
import json
import cv2
import numpy as np
import creative_visual_metrics as v

OUT = v.REPO / "build/research/creative-residual-20261006/white-breath"
OUT.mkdir(parents=True, exist_ok=True)
images = v.recording()
radial, angles = v.rays(images)
time = 54 + np.arange(len(images)) / 30
train = (time >= 56.3) & (time < 62.3) & ~((time > 58.05) & (time < 58.6))
validation = time >= 62.3
starts = np.arange(56.4, 58.7, 1 / 30)
first = np.array([np.interp(starts, time, radial[:, j]) for j in range(256)]).T
second = np.array([np.interp(starts+v.PERIOD, time, radial[:, j]) for j in range(256)]).T
ratio = np.median(second / np.maximum(first, 1), axis=1)
spatial = np.column_stack([np.ones(256)] + [
    f(angles*h) for h in range(1, v.HARMONICS+1) for f in (np.cos, np.sin)])
matrix = v.basis(time)
difference = np.eye(v.KNOTS) - 2*np.roll(np.eye(v.KNOTS), 1, axis=1) + np.roll(np.eye(v.KNOTS), 2, axis=1)


def ease(x):
    lo, hi = np.zeros_like(x), np.ones_like(x)
    for _ in range(24):
        t = (lo+hi)/2
        value = 3*(1-t)**2*t*.42 + 3*(1-t)*t*t*.58 + t**3
        lo, hi = np.where(value < x, t, lo), np.where(value < x, hi, t)
    t = (lo+hi)/2
    return 3*(1-t)*t*t + t**3


def breath(t, origin, mode):
    phase = np.mod((t-origin)/2, 1)
    if mode == "cosine":
        return 1-.05*np.cos(phase*2*np.pi)
    if mode == "global_ease":
        progress = 2*ease(phase)
        return .95+.1*np.minimum(progress, 2-progress)
    progress = np.where(phase < .5, ease(phase*2), 1-ease(phase*2-1))
    return .95+.1*progress


masks = []
for image in images:
    n, labels, stats, _ = cv2.connectedComponentsWithStats((image > 127).astype(np.uint8))
    masks.append(labels == 1+np.argmax(stats[1:, 4]) if n > 1 else np.zeros_like(image, dtype=bool))


def raster(radii):
    points = np.column_stack([99.5+radii*np.cos(angles), 99.5+radii*np.sin(angles)])
    large = np.zeros((800, 800), np.uint8)
    cv2.fillPoly(large, [np.round((points+.5)*4-.5).astype(np.int32)], 255, lineType=cv2.LINE_AA)
    return cv2.resize(large, (200, 200), interpolation=cv2.INTER_AREA)


result = []
for mode in ["cosine", "segment_ease", "global_ease"]:
    loss, origin = min((np.median(abs(
        breath(starts+v.PERIOD, origin, mode)/breath(starts, origin, mode)-ratio)), float(origin))
        for origin in np.arange(54, 56, .01))
    coefficients = (radial / breath(time, origin, mode)[:, None] / 128) @ np.linalg.pinv(spatial).T
    controls = np.linalg.lstsq(np.vstack([matrix[train], .08*difference]),
        np.vstack([coefficients[train], np.zeros((v.KNOTS, 1+v.HARMONICS*2))]), rcond=None)[0]
    predicted = (matrix @ controls @ spatial.T) * breath(time, origin, mode)[:, None] * 128
    scores = []
    for i in range(70, 360):
        if not train[i] and not validation[i]:
            continue
        image = raster(predicted[i])
        actual, ref = image > 127, masks[i]
        scores.append(dict(time=float(time[i]), iou=float((actual & ref).sum()/(actual | ref).sum()),
                           training=bool(train[i])))
    candidate = dict(mode=mode, breath_origin=origin, ratio_median_error=float(loss),
                     training_mean_iou=float(np.mean([s["iou"] for s in scores if s["training"]])),
                     validation_mean_iou=float(np.mean([s["iou"] for s in scores if not s["training"]])),
                     scores=scores, controls=controls.tolist())
    (OUT / (mode+".json")).write_text(json.dumps(candidate, indent=2)+"\n")
    result.append({k: val for k, val in candidate.items() if k not in ["controls", "scores"]})
summary = dict(scope="Diagnostic polygon raster with train-only curve origin; requires actual native path/display verification",
               training=[56.3, 62.3], held_out=[62.3, 65.9666667], candidates=result)
(OUT / "summary.json").write_text(json.dumps(summary, indent=2)+"\n")
print(json.dumps(summary, indent=2))
