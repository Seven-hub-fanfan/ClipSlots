#!/usr/bin/env python3
"""Normalize screenshot ICC profiles before comparing decoded recording RGB."""
import io
import json
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageCms
import creative_visual_metrics as v

ROOT = v.REPO / "build/research"
OUT = ROOT / "creative-residual-20261006"
SRGB = ImageCms.createProfile("sRGB")


def load(path):
    image = Image.open(path)
    if "icc_profile" in image.info:
        profile = ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"]))
        image = ImageCms.profileToProfile(image, profile, SRGB, outputMode="RGB")
    else:
        assert "srgb" in image.info, f"Missing declared color space: {path}"
        image = image.convert("RGB")
    return np.array(image)[:, :, ::-1].astype(float)


capture = cv2.VideoCapture(str(v.VIDEO))
refs = []
for time in [88, 90]:
    capture.set(cv2.CAP_PROP_POS_MSEC, time*1000)
    ok, frame = capture.read()
    assert ok
    refs.append(frame[1470:1764, 1920:2872].astype(float))
capture.release()
reference = refs[0] - refs[1]
result = {
    "scope": "ICC-normalized sRGB screenshots vs decoded recording RGB, fixed upper edge profile.",
    "recording_metadata": "AVFoundation: color primaries, transfer and YCbCr matrix all ITU_R_709_2. No fitted color gain.",
}
for name, directory in [
    ("baseline", "creative-active-20261006/screen-product/glow"),
    ("product_P3_converted", "creative-residual-20261006/screen-product-inset/glow"),
    ("product_sRGB", "creative-residual-20261006/screen-srgb/glow"),
]:
    first, last = [load(ROOT / directory / f"screen-{index:02}.png") for index in [28, 50]]
    difference = first-last
    result[name] = dict(
        profile_mae=float(abs(difference[25:60, 440:510]-reference[25:60, 440:510]).mean()),
        rows={str(y): difference[y, 440:510].mean(0).tolist() for y in [35, 39, 41, 45, 49, 53]})
    if name == "product_sRGB":
        cv2.imwrite(str(OUT / "edge-srgb-contact.png"), np.vstack([
            refs[0][:75].astype("uint8"), first[:75].astype("uint8"),
            np.clip(abs(difference[:75]-reference[:75])*4, 0, 255).astype("uint8")]))

# White and black lie on the neutral axis of both profiles. Verify the existing
# native white captures instead of silently assuming that their IoU is unchanged.
max_delta = 0
for path in (OUT / "white-native/product").glob("[0-9][0-9][0-9].png"):
    max_delta = max(max_delta, abs(cv2.imread(str(path)).astype(float)-load(path)).max())
result["white_profile_conversion_max_channel_delta"] = float(max_delta)
(OUT / "color-space-audit.json").write_text(json.dumps(result, indent=2)+"\n")
print(json.dumps(result, indent=2))
