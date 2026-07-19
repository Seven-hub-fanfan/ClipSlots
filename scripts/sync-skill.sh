#!/usr/bin/env bash
# sync-skill.sh —— 同步 Skill 草稿到 App bundle 打包源
#
# 作用：把工作草稿 docs/clipslots-cli-skill-draft.md 复制为
#   skills/clipslots-manager/SKILL.md
# 后者是 package_dmg.sh 打包时拷进 App bundle
#   (ClipSlots.app/Contents/Resources/skills/clipslots-manager/SKILL.md) 的唯一来源。
#
# ⚠️ 发版前必须运行本脚本，确保 Agent 通过软链接拿到的 SKILL.md 与最新草稿一致，
#    否则 App bundle 里会残留旧版 Skill（缺少最新 CLI 命令说明）。
#
# 用法：
#   ./scripts/sync-skill.sh          # 执行同步
#   ./scripts/sync-skill.sh --check  # 仅校验两者是否一致（CI 友好，不修改文件）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT_DIR/docs/clipslots-cli-skill-draft.md"
DST="$ROOT_DIR/skills/clipslots-manager/SKILL.md"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$SRC" ] || die "草稿源文件不存在：$SRC"

if [ "${1:-}" = "--check" ]; then
  if [ -f "$DST" ] && diff -q "$SRC" "$DST" >/dev/null 2>&1; then
    echo "OK: SKILL.md 已与草稿保持一致 ($DST)"
    exit 0
  fi
  die "SKILL.md 与草稿不一致，请先运行：./scripts/sync-skill.sh"
fi

mkdir -p "$(dirname "$DST")"
cp -f "$SRC" "$DST"
echo "OK: 已同步草稿 -> $DST"
echo "     源: $SRC"
echo "     发版打包 (package_dmg.sh) 会把它拷进 ClipSlots.app/Contents/Resources/skills/clipslots-manager/SKILL.md"
