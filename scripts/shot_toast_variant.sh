#!/bin/bash
# v2.11.7 hotfix14 截图脚本：多彩皮肤 × 明/暗 两档 Toast。
#
# 用法：bash scripts/shot_toast_variant.sh light shots/hotfix14_toast_colorful_light.png
#
# 做法：切皮肤/明暗 → 重启 App → 写剪贴板 → 走**菜单项**「保存到槽位 1」触发保存通知
# （不用 Opt+1 热键：热键路径会先模拟 Cmd+C 抓选中内容，测试环境剪贴板没变化会被
#  `captureSelectionAndSaveToSlot ignored: clipboard did not change` 直接丢掉）→ 全屏截图后
# 按窗口 frame 裁剪。
set -euo pipefail

MODE="${1:-light}"
OUT="${2:-shots/hotfix14_toast_colorful_${MODE}.png}"
LABEL="${3:-多彩 ${MODE} Toast 验证}"

osascript -e 'tell application "ClipSlots" to quit' >/dev/null 2>&1 || true
sleep 2
pkill -f 'ClipSlots.app/Contents/MacOS/ClipSlots' >/dev/null 2>&1 || true
sleep 1

defaults write com.clipslots.app appearanceSkin -string colorful
defaults write com.clipslots.app appearanceMode -string "$MODE"

open -a /Applications/ClipSlots.app
sleep 6

osascript -e "set the clipboard to \"$LABEL\"" >/dev/null
sleep 1

osascript <<'AS' >/dev/null
tell application "ClipSlots" to activate
delay 1
tell application "System Events" to tell process "ClipSlots"
    set frontmost to true
    repeat with m in menu bars
        repeat with mbi in menu bar items of m
            try
                repeat with mi in menu items of menu 1 of mbi
                    if name of mi contains "保存到槽位 1" then
                        click mi
                        return "clicked"
                    end if
                end repeat
            end try
        end repeat
    end repeat
end tell
AS

sleep 1
TMP=$(mktemp /tmp/clipslots_shot_XXXX.png)
screencapture -x "$TMP"

BOUNDS=$(osascript -e 'tell application "System Events" to tell process "ClipSlots"
  set w to first window whose subrole is "AXStandardWindow"
  set p to position of w
  set s to size of w
  return ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ((item 1 of s) as text) & "," & ((item 2 of s) as text)
end tell' 2>/dev/null || echo "none")

mkdir -p "$(dirname "$OUT")"
if [ "$BOUNDS" = "none" ]; then
    cp "$TMP" "$OUT"
else
    IFS=, read -r X Y W H <<<"$BOUNDS"
    # 只裁窗口顶部 200pt 那一条：Toast 就在那儿，整窗截图会把卡片缩得看不清。
    python3 - "$TMP" "$OUT" "$X" "$Y" "$W" <<'PY'
import subprocess, sys
src, dst, x, y, w = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
# screencapture 输出是物理像素（Retina 2x），窗口坐标是逻辑点。
out = subprocess.run(["sips", "-g", "pixelWidth", src], capture_output=True, text=True).stdout
px = int(out.strip().split(":")[-1])
scale = 2 if px > 2000 else 1
subprocess.run(["sips", "-c", str(200 * scale), str(w * scale),
                "--cropOffset", str(y * scale), str(x * scale), src, "--out", dst], check=True,
               stdout=subprocess.DEVNULL)
PY
fi
rm -f "$TMP"
echo "saved: $OUT  bounds=$BOUNDS"
log show --predicate 'process == "ClipSlots"' --last 30s --style compact 2>/dev/null | grep "notice channel" | tail -3 || true
