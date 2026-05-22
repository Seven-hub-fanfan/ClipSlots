#!/usr/bin/env python3
"""Black squircle + white SF Symbol tray icon composited."""

from PIL import Image, ImageDraw

RENDER = 4096
OUTPUT = 1024
MARGIN_RATIO = 0.08
RADIUS_RATIO = 0.22

margin = int(RENDER * MARGIN_RATIO)
r = int(RENDER * RADIUS_RATIO)

# Black squircle canvas
img = Image.new("RGBA", (RENDER, RENDER), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)
draw.rounded_rectangle(
    [margin, margin, RENDER - margin, RENDER - margin],
    r, fill=(0, 0, 0, 255)
)

# Load SF Symbol (rendered by Swift)
sf = Image.open("/Users/bytedance/Cursor/ClipSlotsApp/build/sf_symbol.png")
# SF is 2048px but we need to paste it at RENDER=4096 scale
# Scale SF symbol to fit inside the squircle
sf_zone = int(RENDER * 1.20)  # 120% - bleed past squircle
sf_resized = sf.resize((sf_zone, sf_zone), Image.LANCZOS)

# Center and paste
sf_x = (RENDER - sf_zone) // 2
sf_y = (RENDER - sf_zone) // 2
img.paste(sf_resized, (sf_x, sf_y), sf_resized)

# Downsample
img = img.resize((OUTPUT, OUTPUT), Image.LANCZOS)

output = "/Users/bytedance/Cursor/ClipSlotsApp/build/icon_1024.png"
img.save(output, "PNG")
print(f"Saved {output}")
