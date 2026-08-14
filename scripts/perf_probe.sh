#!/usr/bin/env bash
# v2.10.93 · 流畅度取数脚本（先测量、再改代码）
#
# 为什么需要它：v2.10.87~90 连续四轮「读代码猜热点」全部打偏（其中一轮还是负优化），v2.10.91 改成
# 「先加测量再动手」一测即中。本脚本把那套取数流程固化下来，让任意一轮优化都能拿到 前/后 可比数字。
#
# 隔离约束（v2.10.92 起的硬规定）：
#   • 绝不碰用户日常在用的 /Applications/ClipSlots.app；本脚本只在 build/perf 下临时组一个 bundle。
#   • bundle id 用 com.clipslots.app.perf → UserDefaults 域独立，测「切主题」不会改用户的主题偏好。
#   • CLIPSLOTS_DATA_DIR 指向 /tmp/cs-perf/data（真实库的副本），不动真实数据。
#
# 用法：
#   scripts/perf_probe.sh <标签> [场景] [轮数]
#   scripts/perf_probe.sh baseline resize,theme 2
# 场景取值（逗号分隔）：group / settings / resize / theme
#
# 输出：build/perf/<标签>.log（全量 NSLog）+ 终端上打印的 SUMMARY 摘要。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="${1:-run}"
SCENARIO="${2:-resize,theme}"
ROUNDS="${3:-2}"
DATA_DIR="${CLIPSLOTS_PERF_DATA_DIR:-/tmp/cs-perf/data}"
OUT_DIR="$ROOT_DIR/build/perf"
APP="$OUT_DIR/ClipSlots-perf.app"
LOG="$OUT_DIR/$LABEL.log"

mkdir -p "$OUT_DIR"
[ -d "$DATA_DIR" ] || { echo "ERROR: 数据目录不存在：$DATA_DIR（先从真实库复制一份）" >&2; exit 1; }

echo "==> build release"
cd "$ROOT_DIR"
swift build -c release >/dev/null

echo "==> assemble $APP (bundle id com.clipslots.app.perf)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT_DIR/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.clipslots.app.perf' "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Set :CFBundleName ClipSlotsPerf' "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName ClipSlotsPerf' "$APP/Contents/Info.plist" >/dev/null
cp -f "$ROOT_DIR/.build/release/ClipSlots" "$APP/Contents/MacOS/ClipSlots"
[ -f "$ROOT_DIR/build/ClipSlots.app/Contents/Resources/AppIcon.icns" ] \
  && cp -f "$ROOT_DIR/build/ClipSlots.app/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/" || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "==> run scenario=$SCENARIO rounds=$ROUNDS  (log: $LOG)"
set +e
CLIPSLOTS_PERF_LOG=1 \
CLIPSLOTS_PERF_AUTOTEST=1 \
CLIPSLOTS_PERF_AUTOTEST_SCENARIO="$SCENARIO" \
CLIPSLOTS_PERF_AUTOTEST_ROUNDS="$ROUNDS" \
CLIPSLOTS_DATA_DIR="$DATA_DIR" \
"$APP/Contents/MacOS/ClipSlots" >"$LOG" 2>&1
set -e

echo "==> SUMMARY"
grep -E "phase END|SUMMARY|runs=" "$LOG" | sed 's/^.*\[Perf\] //' || true
