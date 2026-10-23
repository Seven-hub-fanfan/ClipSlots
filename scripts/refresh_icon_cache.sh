#!/usr/bin/env bash
# 刷新 macOS 图标缓存，让换过的 App 图标在程序坞里立刻生效。
#
# 为什么需要这个脚本
# ------------------
# 换图标后 macOS 各处的更新速度不一致，实测（v2.11.6 换图标时）：
#   - 启动台 / Finder：立刻就是新图标（它们走 LaunchServices，重装时已刷新）
#   - 程序坞：仍然是旧图标，即使 `killall Dock` 也没用
#
# 原因是程序坞有自己的一份位图缓存 `$DARWIN_USER_CACHE_DIR/com.apple.dock.iconcache`
# （通常十几到二十 MB），Dock 重启只会重新读这个缓存文件，不会重新去 App bundle 里取图。
# 所以必须**先删缓存、再重启 Dock**，顺序反了等于没做。
#
# 排查提示：判断到底是「LaunchServices 陈旧」还是「Dock 缓存陈旧」，可以用
# `NSWorkspace.shared.icon(forFile:)` 导一张 PNG 出来看——那走的是 LaunchServices。
# 如果导出来已经是新图标而程序坞还是旧的，就是本脚本要解决的这种情况。

set -euo pipefail

APP_PATH="${1:-/Applications/ClipSlots.app}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: $APP_PATH 不存在" >&2
  exit 1
fi

CACHE_DIR="$(getconf DARWIN_USER_CACHE_DIR)"
echo "==> App: $APP_PATH"
echo "==> 缓存目录: $CACHE_DIR"

# App 在运行时，程序坞图标由运行中的进程持有，必须先退出，否则重启 Dock 后还会挂着旧图。
WAS_RUNNING=0
if pgrep -x "$(basename "$APP_PATH" .app)" >/dev/null 2>&1; then
  WAS_RUNNING=1
  echo "==> 退出运行中的 App"
  pkill -x "$(basename "$APP_PATH" .app)" || true
  sleep 1
fi

echo "==> 删除图标缓存"
rm -rf "$CACHE_DIR/com.apple.dock.iconcache" \
       "$CACHE_DIR/com.apple.iconservices" \
       "$HOME/Library/Caches/com.apple.iconservices.store" 2>/dev/null || true

echo "==> 向 LaunchServices 重新注册 bundle"
"$LSREGISTER" -f "$APP_PATH"

# 更新 bundle 目录的 mtime：程序坞的 persistent-apps 里存着 file-mod-date，
# 用它判断条目是否需要重新取图。
touch "$APP_PATH"

echo "==> 重启程序坞"
killall Dock
sleep 3

if [ "$WAS_RUNNING" = "1" ]; then
  echo "==> 重新启动 App"
  open -a "$APP_PATH"
fi

echo "==> 完成。程序坞图标应已更新（若仍是旧图，把程序坞里的图标拖出去再拖回来）"
