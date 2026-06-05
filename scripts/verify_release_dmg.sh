#!/usr/bin/env bash
set -euo pipefail

DMG_PATH="${1:-build/ClipSlots.dmg}"
APP_NAME="ClipSlots"
VOLUME_NAME="${2:-ClipSlots_verify_release}"
MNTPNT="/Volumes/$VOLUME_NAME"

die() { echo "ERROR: $*" >&2; exit 1; }

test -f "$DMG_PATH" || die "DMG not found: $DMG_PATH"
hdiutil detach "$MNTPNT" 2>/dev/null || true
hdiutil verify "$DMG_PATH"
hdiutil attach "$DMG_PATH" -readonly -noverify -noautoopen -mountpoint "$MNTPNT" >/dev/null
trap 'hdiutil detach "$MNTPNT" 2>/dev/null || true' EXIT

test -d "$MNTPNT/$APP_NAME.app" || die "$APP_NAME.app missing"
test -L "$MNTPNT/Applications" || die "Applications symlink missing"
codesign --verify --deep --strict --verbose=2 "$MNTPNT/$APP_NAME.app"

echo "OK: release DMG contains $APP_NAME.app + Applications symlink and app signature verifies."
