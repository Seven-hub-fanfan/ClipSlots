#!/usr/bin/env python3
"""Fit one physical wash-opacity gain and one entrance origin on training only."""
import json
from pathlib import Path
import cv2
import numpy as np
import creative_visual_metrics as visual

OUT = visual.REPO / "build/research/creative-residual-20261006"
OUT.mkdir(parents=True, exist_ok=True)
native_root = visual.REPO / "build/research/creative-active-20261006/opacity-fine-clock/glow"
capture = cv2.VideoCapture(str(visual.VIDEO))


def reference(time):
    capture.set(cv2.CAP_PROP_POS_MSEC, time * 1000)
    ok, frame = capture.read()
    assert ok
    return frame[1470:1764, 1920:2872].astype(np.float32)


base = reference(90)
times = [87.4, 87.6, 87.8, 88.0, 88.2, 88.4, 88.6]
refs = {time: reference(time) for time in times}
capture.release()
roi = np.zeros(base.shape[:2], bool)
roi[55:275, 25:925] = True
quiet = roi & (base.max(axis=2) < 45)
positions = np.zeros_like(quiet)
positions[::5, ::5] = True
positions &= quiet
b = base[positions]
ref_effects = {time: image[positions] - b for time, image in refs.items()}
masks = {time: refs[time][positions].max(axis=1) < 125 for time in times}
effects = []
for index in range(251):
    image = cv2.imread(str(native_root / f"glow-{index:02}.png"), cv2.IMREAD_UNCHANGED)[positions].astype(np.float32)
    effects.append((image[:, :3] - b) * image[:, 3:4] / 255)
effects = np.array(effects)


def error(time, origin, gain):
    ref = ref_effects[time]
    predicted = effects[int(np.clip(round((time-origin) / .01), 0, 250))] * gain
    active = masks[time] & ((ref.max(axis=1) > 4) | (predicted.max(axis=1) > 4))
    return float(np.abs(predicted-ref)[active].sum() / np.abs(ref[active]).sum())


training = times[:3]
best = min((np.mean([error(time, origin, gain) for time in training]), float(origin), float(gain))
           for origin in np.arange(86.4, 86.851, .01)
           for gain in np.arange(.65, 1.051, .01))
_, origin, gain = best
rows = []
for name, start, amplitude in [("baseline", 86.63, 1), ("single_wash_gain", origin, gain)]:
    rows.append(dict(name=name, origin=start, gain=amplitude,
                     training_similarity=1-np.mean([error(t, start, amplitude) for t in training]),
                     validation_similarity=1-np.mean([error(t, start, amplitude) for t in times[3:]]),
                     frames=[dict(time=t, similarity=1-error(t, start, amplitude)) for t in times]))
result = dict(scope="Exploratory physical-opacity gain, 5px sampling; train only on 87.4/87.6/87.8. Requires native render validation.",
              variants=rows)
(OUT / "wash-gain-fit.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
