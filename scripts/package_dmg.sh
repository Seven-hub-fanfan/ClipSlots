#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClipSlots"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
STAGING_DIR="$BUILD_DIR/dmg_staging"
TMP_DMG="$BUILD_DIR/tmp.dmg"

echo "==> Clean"
rm -rf "$APP_DIR" "$STAGING_DIR"
rm -f "$DMG_PATH" "$TMP_DMG"

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

echo "==> Re-sign app bundle (adhoc)"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Validate app bundle"
plutil -lint "$APP_DIR/Contents/Info.plist"
file "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "==> Prepare DMG staging"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Create and layout DMG"
# Ensure no stale mount
hdiutil detach "/Volumes/$APP_NAME" 2>/dev/null || true
sleep 1

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDRW \
  -size 100m \
  "$TMP_DMG"

# Mount to a specific mountpoint to avoid name conflicts
MNTPNT="/Volumes/$APP_NAME"
hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen -mountpoint "$MNTPNT" 2>/dev/null

# Set up Finder view via AppleScript
osascript -e "
tell application \"Finder\"
  tell disk \"$APP_NAME\"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 200, 900, 580}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set position of item \"$APP_NAME.app\" to {120, 140}
    set position of item \"Applications\" to {380, 140}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
" 2>/dev/null || true

sleep 2
hdiutil detach "$MNTPNT" 2>/dev/null || true
sleep 1

echo "==> Convert to compressed DMG"
rm -f "$DMG_PATH"
hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG_PATH" >/dev/null
rm -f "$TMP_DMG"

echo "==> Verify dmg"
hdiutil verify "$DMG_PATH"

echo "==> SHA256"
shasum -a 256 "$DMG_PATH"

echo "==> Done"
echo "$DMG_PATH"
