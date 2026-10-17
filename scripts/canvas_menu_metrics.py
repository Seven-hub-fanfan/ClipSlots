#!/usr/bin/env python3
"""Compare ScreenCaptureKit pixels using their presentation timestamps."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import imageio_ffmpeg
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("before", type=Path)
parser.add_argument("after", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 20)
metrics = {}


def load(folder, scenario):
    items = json.loads((folder / f"{scenario}-0-frames.json").read_text())
    return [(item["relative_ms"], Image.open(folder / item["file"]).convert("RGB")) for item in items]


def frame_at(frames, time):
    return next((image for stamp, image in reversed(frames) if stamp <= time), frames[0][1])


for scenario in ("double", "drag"):
    sequences = [load(folder, scenario) for folder in (args.before, args.after)]
    # This region includes both the baseline's shifted menu and its final bounds.
    roi = (900, 225 if scenario == "double" else 390, 1290, 876)
    for label, sequence in zip(("before", "after"), sequences):
        target = np.asarray(sequence[-1][1].crop(roi), dtype=float)
        initial = np.asarray(sequence[0][1].crop(roi), dtype=float)
        initial_error = np.abs(initial - target).mean()
        errors = [float(np.abs(np.asarray(image.crop(roi), dtype=float) - target).mean())
                  for _, image in sequence]
        # Fully settled pixels: mean RGB error <= 0.5/255 for every later frame.
        settled = next((i for i in range(len(errors)) if max(errors[i:]) <= 0.5), None)
        changed = [stamp for (stamp, _), error in zip(sequence, errors)
                   if stamp >= 0 and error > 0.5]
        visible_steps = [sequence[i][0] for i in range(1, (settled or 0) + 1)
                         if sequence[i][0] >= 0 and abs(errors[i] - errors[i - 1]) > 0.15]
        step_gaps = [b - a for a, b in zip(visible_steps, visible_steps[1:])]
        metrics[f"{scenario}_{label}"] = {
            "complete_frames": len(sequence),
            "settled_pixels_ms": sequence[settled][0] if settled is not None else None,
            "last_changing_frame_ms": max(changed, default=None),
            "initial_error_rgb": initial_error,
            "visible_step_times_ms": visible_steps,
            "max_visible_step_gap_ms": max(step_gaps, default=None),
            "visible_step_definition": "change in mean RGB error >0.15/255; not whole-app FPS",
            "roi": roi,
            "method": "SCK presented timestamps; mean RGB error <=0.5/255 against final menu for all remaining frames",
            "samples": [{"ms": stamp, "mean_rgb_error": error}
                        for (stamp, _), error in zip(sequence, errors)],
        }
    width, height = 300, int((roi[3] - roi[1]) * 300 / (roi[2] - roi[0]))
    times = [0, 50, 100, 150, 225, 300]
    sheet = Image.new("RGB", (width * len(times), (height + 55) * 2), "#16191f")
    draw = ImageDraw.Draw(sheet)
    for row, (label, sequence) in enumerate(zip(("Before", "After"), sequences)):
        for col, time in enumerate(times):
            x, y = col * width, row * (height + 55)
            draw.text((x + 12, y + 16), f"{label}  {time} ms", font=font, fill="white")
            sheet.paste(frame_at(sequence, time).crop(roi).resize((width, height)), (x, y + 55))
    sheet.save(args.output / f"{scenario}-comparison.png")

    # Replays the measured frames side by side at real speed, with a short hold.
    movie_size = (800, 744)
    command = [imageio_ffmpeg.get_ffmpeg_exe(), "-y", "-f", "rawvideo", "-vcodec", "rawvideo",
               "-s", f"{movie_size[0]}x{movie_size[1]}", "-pix_fmt", "rgb24", "-r", "60", "-i", "-",
               "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p",
               str(args.output / f"{scenario}-comparison.mp4")]
    with subprocess.Popen(command, stdin=subprocess.PIPE, stderr=subprocess.DEVNULL) as process:
        for repeat in range(3):
            for index in range(90):
                time = min(index * 1000 / 60, 450)
                canvas = Image.new("RGB", movie_size, "#16191f")
                draw = ImageDraw.Draw(canvas)
                for col, (label, sequence) in enumerate(zip(("Before", "After"), sequences)):
                    image = frame_at(sequence, time).crop(roi)
                    image.thumbnail((390, 675))
                    canvas.paste(image, (col * 400 + 5, 60))
                    draw.text((col * 400 + 12, 20), f"{label}   {time:.0f} ms", fill="white", font=font)
                process.stdin.write(canvas.tobytes())
        process.stdin.close()
        process.wait()
        if process.returncode:
            raise RuntimeError("Video encoder failed")

(args.output / "presented-pixels.json").write_text(json.dumps(metrics, indent=2) + "\n")
for name, result in metrics.items():
    print(name, "settled pixels:", result["settled_pixels_ms"], "ms")
