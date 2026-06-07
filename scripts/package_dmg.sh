#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClipSlots"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
STAGING_DIR="$BUILD_DIR/dmg_staging"
TMP_DMG="$BUILD_DIR/tmp.dmg"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist" 2>/dev/null || echo "dev")"
VOLUME_NAME="$APP_NAME v$VERSION"
DMG_SIZE="260m"
BACKGROUND_DIR="$BUILD_DIR/dmg_background"
BACKGROUND_PNG="$BACKGROUND_DIR/background.png"

die() { echo "ERROR: $*" >&2; exit 1; }
detach_if_mounted() { hdiutil detach "$1" 2>/dev/null || true; }
ensure_applications_symlink() {
  local dir="$1"
  rm -rf "$dir/Applications"
  ln -s /Applications "$dir/Applications"
  test -L "$dir/Applications" || die "Applications symlink missing in $dir"
}
verify_app_bundle() {
  local app="$1"
  test -d "$app" || die "$app missing"
  test -x "$app/Contents/MacOS/$APP_NAME" || die "$APP_NAME executable missing or not executable"
  plutil -lint "$app/Contents/Info.plist" >/dev/null
  codesign --verify --deep --strict --verbose=2 "$app"
}
create_dmg_background() {
mkdir -p "$BACKGROUND_DIR"
python3 - <<PY
from pathlib import Path
try:
    from PIL import Image, ImageDraw, ImageFont
except Exception:
    raise SystemExit(0)
out = Path("$BACKGROUND_PNG")
W,H = 640,360
img = Image.new("RGB", (W,H), (250,250,248))
d = ImageDraw.Draw(img)
for x in range(W):
    c = int(250 - x/W*10)
    d.line([(x,0),(x,H)], fill=(c,c,c+2))
d.rounded_rectangle([250,120,390,205], radius=42, outline=(185,185,185), width=3)
d.polygon([(382,162),(360,148),(360,176)], fill=(185,185,185))
try:
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 18)
    small = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 13)
except Exception:
    font = small = None
d.text((238,232), "拖动 ClipSlots 到 Applications", fill=(90,90,90), font=font)
d.text((252,258), "Drag to install", fill=(135,135,135), font=small)
img.save(out)
PY
}

echo "==> Clean"
detach_if_mounted "/Volumes/$VOLUME_NAME"
rm -rf "$APP_DIR" "$STAGING_DIR" "$BACKGROUND_DIR"
rm -f "$DMG_PATH" "$TMP_DMG" "$TMP_DMG.dmg"

echo "==> Build release"
swift build -c release --package-path "$ROOT_DIR"

echo "==> Create app bundle"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/.build/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

if [ -f "$ROOT_DIR/assets/AppIcon.icns" ]; then
  cp "$ROOT_DIR/assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
elif [ -f "$ROOT_DIR/build/AppIcon.icns" ]; then
  cp "$ROOT_DIR/build/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
else
  echo "Warning: AppIcon.icns not found"
fi

chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "==> Remove quarantine / stale extended attributes from app before DMG"
xattr -cr "$APP_DIR" 2>/dev/null || true

echo "==> Re-sign app bundle (adhoc) after xattr cleanup"
codesign --force --deep --timestamp=none --sign - "$APP_DIR"
verify_app_bundle "$APP_DIR"

echo "==> Validate app bundle"
plutil -lint "$APP_DIR/Contents/Info.plist"
file "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "==> Prepare DMG staging"
mkdir -p "$STAGING_DIR"
ditto "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ensure_applications_symlink "$STAGING_DIR"
xattr -cr "$STAGING_DIR" 2>/dev/null || true
verify_app_bundle "$STAGING_DIR/$APP_NAME.app"
create_dmg_background

echo "==> Create and layout DMG"
# Ensure no stale mount
detach_if_mounted "/Volumes/$VOLUME_NAME"
sleep 1

hdiutil create \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -size "$DMG_SIZE" \
  -ov \
  "$TMP_DMG"

# Mount to a specific mountpoint to avoid name conflicts
MNTPNT="/Volumes/$VOLUME_NAME"
hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen -mountpoint "$MNTPNT"

echo "==> Copy app and Applications link into mounted DMG"
ditto "$APP_DIR" "$MNTPNT/$APP_NAME.app"
ensure_applications_symlink "$MNTPNT"
xattr -cr "$MNTPNT/$APP_NAME.app" 2>/dev/null || true
codesign --force --deep --timestamp=none --sign - "$MNTPNT/$APP_NAME.app"
verify_app_bundle "$MNTPNT/$APP_NAME.app"

test -d "$MNTPNT/$APP_NAME.app" || die "$APP_NAME.app missing before layout"
test -L "$MNTPNT/Applications" || die "Applications symlink missing before layout"

# Make sure Finder metadata is writable and volume has a place for custom window layout.
mkdir -p "$MNTPNT/.background"
if [ -f "$BACKGROUND_PNG" ]; then
  cp "$BACKGROUND_PNG" "$MNTPNT/.background/background.png"
fi
touch "$MNTPNT/.metadata_never_index" 2>/dev/null || true

# Set up Finder view via AppleScript
osascript -e "
tell application \"Finder\"
  tell disk \"$VOLUME_NAME\"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {360, 180, 1000, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    try
    set background picture of viewOptions to file ".background:background.png"
    end try
    set position of item \"$APP_NAME.app\" to {145, 170}
    set position of item \"Applications\" to {495, 170}
    set label position of viewOptions to bottom
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
" 2>/dev/null || true

echo "==> Re-open mounted DMG to confirm Finder-visible installer items"
test -d "$MNTPNT/$APP_NAME.app" || die "$APP_NAME.app missing after layout"
test -L "$MNTPNT/Applications" || die "Applications symlink missing after layout"
if [ -f "$BACKGROUND_PNG" ]; then
  test -f "$MNTPNT/.background/background.png" || die "DMG background missing after layout"
fi

sleep 2
hdiutil detach "$MNTPNT" || { sleep 2; hdiutil detach "$MNTPNT" -force; }
sleep 1

echo "==> Convert to compressed DMG"
rm -f "$DMG_PATH"
hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG_PATH" >/dev/null
rm -f "$TMP_DMG"

echo "==> Remove quarantine from generated DMG if present"
xattr -cr "$DMG_PATH" 2>/dev/null || true
xattr -d com.apple.quarantine "$DMG_PATH" 2>/dev/null || true

echo "==> Verify dmg"
hdiutil verify "$DMG_PATH"

echo "==> Verify DMG contents include app and Applications symlink"
VERIFY_MOUNT="/Volumes/${VOLUME_NAME}_verify"
detach_if_mounted "$VERIFY_MOUNT"
hdiutil attach "$DMG_PATH" -readonly -noverify -noautoopen -mountpoint "$VERIFY_MOUNT" >/dev/null
test -d "$VERIFY_MOUNT/$APP_NAME.app" || die "$APP_NAME.app missing in DMG"
test -L "$VERIFY_MOUNT/Applications" || die "Applications symlink missing in DMG"
test "$(readlink "$VERIFY_MOUNT/Applications")" = "/Applications" || die "Applications symlink target invalid"
if [ -f "$BACKGROUND_PNG" ]; then
  test -f "$VERIFY_MOUNT/.background/background.png" || die "DMG background missing in final image"
fi
verify_app_bundle "$VERIFY_MOUNT/$APP_NAME.app" || die "codesign verify failed inside DMG"
echo "  OK: app and Applications symlink present"
hdiutil detach "$VERIFY_MOUNT" 2>/dev/null || true

echo "==> Optional deep verification"
if [ -x "$ROOT_DIR/scripts/verify_release_dmg.sh" ]; then
  "$ROOT_DIR/scripts/verify_release_dmg.sh" "$DMG_PATH"
fi

echo "==> Gatekeeper note"
echo "  This DMG is ad-hoc signed, not Developer ID notarized."
echo "  If users download via Chrome/Safari, macOS may attach quarantine."
echo "  For zero Gatekeeper warnings, use Developer ID signing + notarization."

echo "==> SHA256"
shasum -a 256 "$DMG_PATH"

echo "==> Done"
echo "$DMG_PATH"
