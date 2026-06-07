#!/usr/bin/env bash
set -euo pipefail

DMG_PATH="${1:-build/ClipSlots.dmg}"
APP_NAME="ClipSlots"

die() { echo "ERROR: $*" >&2; exit 1; }
test -f "$DMG_PATH" || die "DMG not found: $DMG_PATH"

VOLUME_NAME="$(hdiutil imageinfo "$DMG_PATH" | awk -F': ' '/partition-name/ {print $2; exit}')"
if [ -z "${VOLUME_NAME:-}" ]; then
  VOLUME_NAME="ClipSlots_verify"
fi
MOUNT_POINT="/Volumes/${VOLUME_NAME}_verify_$$"

cleanup() { hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> hdiutil verify"
hdiutil verify "$DMG_PATH" >/dev/null

echo "==> mount readonly"
hdiutil attach "$DMG_PATH" -readonly -noverify -noautoopen -mountpoint "$MOUNT_POINT" >/dev/null

echo "==> verify contents"
test -d "$MOUNT_POINT/$APP_NAME.app" || die "$APP_NAME.app missing"
test -L "$MOUNT_POINT/Applications" || die "Applications symlink missing"
test "$(readlink "$MOUNT_POINT/Applications")" = "/Applications" || die "Applications symlink target invalid"

echo "==> verify app bundle"
test -x "$MOUNT_POINT/$APP_NAME.app/Contents/MacOS/$APP_NAME" || die "executable missing"
plutil -lint "$MOUNT_POINT/$APP_NAME.app/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict --verbose=2 "$MOUNT_POINT/$APP_NAME.app"

echo "OK: DMG contains app + Applications symlink and app signature verifies"
