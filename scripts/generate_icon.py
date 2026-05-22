#!/usr/bin/env python3
"""Generate a macOS-style app icon for ClipSlots using Pillow."""

import math
from PIL import Image, ImageDraw

SIZE = 1024
PAD = 80  # padding inside squircle
img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)


# ---- helpers ----
def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(4))


def squircle_mask(size, radius_frac=0.225):
    """Return a 2D list of alpha values for a squircle shape."""
    mask = Image.new("L", (size, size), 0)
    mdraw = ImageDraw.Draw(mask)
    r = int(size * radius_frac)
    # approximate squircle with a rounded rectangle
    mdraw.rounded_rectangle([0, 0, size - 1, size - 1], r, fill=255)
    return mask


def draw_gradient_bg(draw, w, h, top, btm):
    """Vertical linear gradient."""
    for y in range(h):
        t = y / h
        color = lerp(top, btm, t)
        draw.line([(0, y), (w, y)], fill=color)


# ---- 1. Squircle background ----
bg_mask = squircle_mask(SIZE)
bg_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
bg_draw = ImageDraw.Draw(bg_layer)

# Deep indigo to vibrant blue-purple gradient
top_color = (72, 67, 190, 255)     # deep indigo
btm_color = (55, 50, 160, 255)     # slightly darker
draw_gradient_bg(bg_draw, SIZE, SIZE, top_color, btm_color)

# Apply squircle mask
bg_layer.putalpha(bg_mask)
img.paste(bg_layer, (0, 0), bg_layer)

# ---- 2. Subtle inner shadow rim ----
rim = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
rim_draw = ImageDraw.Draw(rim)
for i in range(6):
    alpha = 40 - i * 6
    r = int(SIZE * 0.225) - i
    rim_draw.rounded_rectangle(
        [i, i, SIZE - 1 - i, SIZE - 1 - i], r, outline=(255, 255, 255, alpha), width=1
    )
img.paste(rim, (0, 0), rim)

# ---- 3. Stacked cards (clipboard slots metaphor) ----
# Card dimensions
card_w, card_h = 520, 380
card_center = (SIZE // 2, SIZE // 2 + 20)

card_colors = [
    (255, 255, 255, 240),   # top card - white
    (240, 238, 255, 210),   # second - light lavender
    (228, 225, 250, 170),   # third
    (218, 214, 245, 130),   # bottom
]

offsets = [(0, 0), (12, 14), (24, 28), (36, 42)]
angles = [0, -3, -6, -9]  # degrees

for i, ((ox, oy), angle) in enumerate(zip(offsets, angles)):
    card = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    cdraw = ImageDraw.Draw(card)

    # Card shadow
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow)
    sx, sy = card_center[0] - card_w // 2 + ox + 6, card_center[1] - card_h // 2 + oy + 6
    sdraw.rounded_rectangle(
        [sx, sy, sx + card_w, sy + card_h], 28,
        fill=(0, 0, 0, 25 - i * 5)
    )
    img.paste(shadow, (0, 0), shadow)

    # Card body
    cx, cy = card_center[0] - card_w // 2 + ox, card_center[1] - card_h // 2 + oy
    cdraw.rounded_rectangle(
        [cx, cy, cx + card_w, cy + card_h], 28,
        fill=card_colors[i],
        outline=(200, 198, 220, 60), width=2
    )

    # Card content: horizontal lines representing text
    if i == 0:
        line_color = (180, 178, 210, 180)
        for j in range(6):
            ly = cy + 80 + j * 42
            lw = card_w - 120 if j < 5 else card_w - 240
            cdraw.rounded_rectangle(
                [cx + 60, ly, cx + 60 + lw, ly + 14], 7, fill=line_color
            )

        # 3x3 grid of numbered circles on the top card
        grid_ox, grid_oy = cx + 340, cy + 50
        dot_size = 28
        gap = 46
        dot_colors = [
            (99, 91, 255, 230),  (120, 112, 255, 220), (142, 134, 255, 210),
            (80, 72, 235, 230),  (106, 97, 250, 220),  (128, 119, 255, 210),
            (65, 58, 215, 230),  (88, 80, 240, 220),   (110, 102, 250, 210),
        ]
        for row in range(3):
            for col in range(3):
                idx = row * 3 + col
                dx = grid_ox + col * gap
                dy = grid_oy + row * gap
                cdraw.ellipse(
                    [dx, dy, dx + dot_size, dy + dot_size],
                    fill=dot_colors[idx],
                    outline=(255, 255, 255, 120), width=2
                )

    img.paste(card, (0, 0), card)

# ---- 4. Top highlight (macOS glossy effect) ----
highlight = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
hdraw = ImageDraw.Draw(highlight)
# Semi-ellipse at top
hdraw.ellipse(
    [SIZE * 0.15, -SIZE * 0.15, SIZE * 0.85, SIZE * 0.4],
    fill=(255, 255, 255, 35)
)
# Apply squircle mask to highlight
highlight.putalpha(bg_mask)
img.paste(highlight, (0, 0), highlight)

# ---- Save ----
output_path = "/Users/bytedance/Cursor/ClipSlotsApp/build/icon_1024.png"
img.save(output_path, "PNG")
print(f"Icon saved to {output_path}")
