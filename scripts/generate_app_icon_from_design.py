#!/usr/bin/env python3
"""从位图设计稿生成 macOS App 图标（assets/AppIcon.png + AppIcon.iconset + AppIcon.icns）。

背景
----
v2.11.6 起图标源从矢量 `assets/AppIcon.svg` 换成位图设计稿 `assets/AppIcon.design.png`
（2048×2048，黑底画布上一块白色 squircle 底板 + 三个 3D 黑色堆叠形状）。
旧的 `scripts/generate_app_icon.sh` 走 SVG→rsvg/qlmanage→sips 的路子，对位图源不适用，
故新增本脚本。两者产出完全相同的三件套，只是输入不同。

为什么不是简单地「抠掉黑色背景」
--------------------------------
设计稿里图形主体本身就是近黑色（L≈30），画布背景是纯黑（L≈1）。按亮度阈值抠图会把
底板上的三个黑色形状一起抠掉，只剩一个空白圆角方块。正确做法是**按几何形状**取 alpha：
底板是一个规整的 squircle，直接解析地构造它的遮罩，遮罩内原样保留像素（白底板 + 黑图形），
遮罩外全透明。

squircle 参数不是拍脑袋定的：把设计稿底板的边缘轮廓拟合到超椭圆 |u|^n+|v|^n=1，
n=5.3 时 RMS 误差最小（≈0.9% 边长，误差集中在圆角处），与 Apple 图标模板的连续曲率
圆角基本重合——所以这里用 n=5.3 重建遮罩，而不是用 PIL 的 `rounded_rectangle`
（那是圆弧圆角，在拐点处会出现可见的曲率突变）。

尺寸遵循 macOS 图标规范：1024 画布内底板占 824×824 居中，四周 100pt 留白
（Apple 模板值，也与本项目历史图标一致）。留白不是浪费——Dock 的放大动画、
Launchpad 的选中态、快速查看的投影都依赖这圈余量。
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"
DESIGN = ASSETS / "AppIcon.design.png"
MASTER_PNG = ASSETS / "AppIcon.png"
ICONSET = ASSETS / "AppIcon.iconset"
ICNS = ASSETS / "AppIcon.icns"

# 超椭圆指数：对设计稿底板轮廓拟合所得（见模块 docstring）。
SQUIRCLE_N = 5.3
# 遮罩超采样倍率。1024 输出下 4× 足够把圆角边缘的锯齿压到看不见。
SUPERSAMPLE = 4
# macOS 图标模板：1024 画布里底板占 824（=1024×0.8047）。
CANVAS = 1024
PLATE = 824
# 内建投影。设计稿自带的投影落在黑画布上、抠图后必然丢失，这里重新合成一层：
# 纯白底板在 Finder 白色列表 / DMG 白窗口里若没有投影会「浮」得没有边界。
SHADOW_OFFSET_Y = 10
SHADOW_BLUR = 14
SHADOW_ALPHA = 46  # 0-255

ICONSET_SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def find_plate_bbox(img: Image.Image) -> tuple[int, int, int, int]:
    """按 50% 亮度阈值定位白色底板的外接框。

    阈值取 121（255 的一半）而不是更低的值：设计稿底板外面有一圈软投影，
    亮度阈值定低了会把投影的过渡带算进底板，底板尺寸会被高估几十像素。
    """
    lum = np.asarray(img.convert("RGB")).astype(float).mean(axis=2)
    mask = lum > 121
    ys, xs = np.nonzero(mask)
    if xs.size == 0:
        raise SystemExit("设计稿里找不到白色底板（没有亮度 > 121 的像素）")
    return int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())


def squircle_alpha(size: int, n: float = SQUIRCLE_N, shrink: float = 0.0,
                   supersample: int = SUPERSAMPLE) -> Image.Image:
    """生成 size×size 的超椭圆遮罩（L 模式，抗锯齿）。

    `shrink` 是归一化半径的收缩量（0.004 ≈ 边长的 0.4%），用于保证遮罩严格落在
    设计稿底板内部，见 `fit_shrink`。
    """
    hi = size * supersample
    axis = ((np.arange(hi) + 0.5) / hi * 2.0 - 1.0) / max(1e-6, 1.0 - shrink)
    u = np.abs(axis)[None, :] ** n
    v = np.abs(axis)[:, None] ** n
    inside = (u + v) <= 1.0
    mask = Image.fromarray((inside * 255).astype(np.uint8))
    return mask.resize((size, size), Image.LANCZOS)


def plate_coverage(plate: Image.Image) -> np.ndarray:
    """设计稿底板自身的实心区域（含内部黑色图形），布尔数组。

    不能直接用亮度阈值：底板上的三个图形是近黑色（L≈30），阈值法会把它们当成背景挖空。
    这里利用「底板是凸形」这一事实——逐行取最左 / 最右白像素之间填满，逐列同理，两者取交集
    就是底板本体。对凸形而言这是精确的，且不依赖 scipy 或 flood fill。
    """
    lum = np.asarray(plate.convert("RGB")).astype(float).mean(axis=2)
    bright = lum > 121

    def span_fill(mask: np.ndarray) -> np.ndarray:
        idx = np.arange(mask.shape[1])[None, :]
        any_row = mask.any(axis=1)
        first = np.where(any_row, np.argmax(mask, axis=1), mask.shape[1])[:, None]
        last = np.where(any_row, mask.shape[1] - 1 - np.argmax(mask[:, ::-1], axis=1), -1)[:, None]
        return (idx >= first) & (idx <= last)

    return span_fill(bright) & span_fill(bright.T).T


def fit_shape(plate: Image.Image, probe: int = 1600) -> tuple[float, float]:
    """挑一组 (n, shrink)：在「遮罩不越出底板」的前提下让遮罩面积最大。

    只拟合 n 不够——n 取拟合 RMS 最小的 5.3 时，误差虽小却集中在圆角，解析曲线在某几个角上
    比设计稿更饱满，直接套会把圆角外的**纯黑画布**框进来，成品左上角挂一弯黑色月牙。
    加上收缩量补救又会整体缩小底板。所以两个参数一起搜：对每个 n 二分出恰好不漏黑边的收缩量，
    再取「有效面积最大」的那组。实测设计稿的圆角比标准 Apple squircle 更圆，
    n≈4.6 几乎不用收缩就能贴合（1.25% → 0.05%）。
    """
    small = plate.resize((probe, probe), Image.LANCZOS)
    covered = plate_coverage(small)
    best = (SQUIRCLE_N, 0.0, -1.0)
    for step in range(0, 26):
        n = 4.0 + step * 0.1
        shrink = fit_shrink(small, n=n, covered=covered)
        area = float((np.asarray(squircle_alpha(probe, n=n, shrink=shrink)) > 200).mean())
        if area > best[2]:
            best = (n, shrink, area)
    n, shrink, area = best
    print(f"    squircle 拟合：n={n:.1f}，收缩 {shrink * 100:.2f}%，"
          f"覆盖设计稿底板的 {area / covered.mean() * 100:.1f}%")
    return n, shrink


def fit_shrink(plate: Image.Image, n: float = SQUIRCLE_N,
               covered: np.ndarray | None = None) -> float:
    """二分求最小收缩量，使解析 squircle 遮罩完全落在设计稿底板内。

    宁可让白色底板缺 0.x% 也不能带进黑边——前者不可见，后者一眼就能看出图标做坏了。
    """
    if covered is None:
        covered = plate_coverage(plate)
    size = plate.size[0]
    total = covered.size
    # 容忍 1e-5 的漏出（约几十个像素）：底板边缘本身有一像素宽的抗锯齿过渡带，
    # 要求绝对零漏出会让收缩量被这条过渡带绑架。
    tol = 1e-5

    def leaks(shrink: float) -> float:
        mask = np.asarray(squircle_alpha(size, n=n, shrink=shrink)) > 200
        return float(np.count_nonzero(mask & ~covered)) / total

    if leaks(0.0) <= tol:
        return 0.0
    lo, hi = 0.0, 0.05
    for _ in range(18):
        mid = (lo + hi) / 2
        if leaks(mid) > tol:
            lo = mid
        else:
            hi = mid
    return hi


def build_master(work: int = CANVAS * SUPERSAMPLE) -> Image.Image:
    """产出 1024×1024 的图标母版（RGBA，透明背景）。"""
    design = Image.open(DESIGN).convert("RGB")
    x0, y0, x1, y1 = find_plate_bbox(design)
    plate_px = work * PLATE // CANVAS

    # 设计稿底板实测 1482×1505（渲染稿本身不是严格正方），强行拉成正方形。
    # 差异 1.5%，肉眼不可见，但图标必须是正方形，否则各尺寸缩放会被 sips 再拉一次。
    plate = design.crop((x0, y0, x1 + 1, y1 + 1)).resize((plate_px, plate_px), Image.LANCZOS)
    n, shrink = fit_shape(plate)

    plate = plate.convert("RGBA")
    plate.putalpha(squircle_alpha(plate_px, n=n, shrink=shrink))

    canvas = Image.new("RGBA", (work, work), (0, 0, 0, 0))
    offset = (work - plate_px) // 2

    # 投影：拿底板自己的 alpha 当形状，避免投影轮廓和底板圆角对不上。
    scale = work / CANVAS
    shadow = Image.new("RGBA", (work, work), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, SHADOW_ALPHA), (offset, offset + int(SHADOW_OFFSET_Y * scale)), plate.getchannel("A"))
    shadow = shadow.filter(ImageFilter.GaussianBlur(SHADOW_BLUR * scale))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(plate, (offset, offset))

    return canvas.resize((CANVAS, CANVAS), Image.LANCZOS)


def verify(master: Image.Image) -> None:
    """出厂自检。图标做坏的几种典型姿势都是「能生成、能打包、装上才发现」，所以这里挡一道。"""
    alpha = np.asarray(master.getchannel("A")).astype(int)
    rgb = np.asarray(master.convert("RGB")).astype(int)

    corner = max(alpha[0, 0], alpha[0, -1], alpha[-1, 0], alpha[-1, -1])
    assert corner == 0, f"画布四角必须全透明，实测 alpha={corner}（黑底没抠干净）"

    cy = cx = CANVAS // 2
    assert alpha[cy, cx] == 255, "图标中心必须不透明"

    # 底板必须是白的：中心偏上一块（在最上面那个黑色形状之上）取样。
    plate_sample = rgb[int(CANVAS * 0.22), int(CANVAS * 0.5)]
    assert plate_sample.min() > 200, f"底板取样点不是白色：{tuple(plate_sample)}"

    # 黑色主体必须还在（如果按亮度阈值抠图，这里会变成白色底板）。
    glyph_sample = rgb[int(CANVAS * 0.68), int(CANVAS * 0.5)]
    assert glyph_sample.max() < 90, f"图形主体取样点不是深色：{tuple(glyph_sample)}（主体被一起抠掉了？）"

    # 底板占比应落在 macOS 模板量级（824/1024 加投影外扩）。
    ys, xs = np.nonzero(alpha > 8)
    span = max(xs.max() - xs.min(), ys.max() - ys.min()) + 1
    assert PLATE - 20 <= span <= CANVAS - 40, f"图标占位 {span}px 偏离 macOS 模板（期望 ≈{PLATE}px + 投影）"
    print(f"    自检通过：占位 {span}px，四角透明，底板白 / 主体黑均在位")


def main() -> int:
    if not DESIGN.exists():
        raise SystemExit(f"缺少设计稿：{DESIGN}")

    print("==> 从设计稿构建图标母版")
    master = build_master()
    verify(master)
    master.save(MASTER_PNG, "PNG")
    print(f"    {MASTER_PNG.relative_to(ROOT)}  {master.size[0]}×{master.size[1]}")

    print("==> 生成 iconset")
    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True)
    for name, size in ICONSET_SIZES:
        # 每一档都从 1024 母版单独 LANCZOS 下采样，不做链式缩放（链式会累积软化）。
        master.resize((size, size), Image.LANCZOS).save(ICONSET / name, "PNG")
        print(f"    {name}  {size}×{size}")

    print("==> 打包 icns")
    ICNS.unlink(missing_ok=True)
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)
    print(f"    {ICNS.relative_to(ROOT)}  {ICNS.stat().st_size} bytes")

    print("==> 完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
