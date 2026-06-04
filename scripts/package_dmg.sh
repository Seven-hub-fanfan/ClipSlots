#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClipSlots"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
STAGING_DIR="$BUILD_DIR/dmg_staging"
TMP_DMG="$BUILD_DIR/tmp.dmg"
VOLUME_NAME="$APP_NAME"
DMG_SIZE="160m"

echo "==> Clean"
hdiutil detach "/Volumes/$VOLUME_NAME" 2>/dev/null || true
rm -rf "$APP_DIR" "$STAGING_DIR"
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

echo "==> Re-sign app bundle (adhoc)"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Remove quarantine / stale extended attributes from app before DMG"
xattr -cr "$APP_DIR" 2>/dev/null || true

echo "==> Validate app bundle"
plutil -lint "$APP_DIR/Contents/Info.plist"
file "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "==> Prepare DMG staging"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
xattr -cr "$STAGING_DIR" 2>/dev/null || true

echo "==> Create and layout DMG"
# Ensure no stale mount
hdiutil detach "/Volumes/$VOLUME_NAME" 2>/dev/null || true
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
ln -s /Applications "$MNTPNT/Applications"
xattr -cr "$MNTPNT/$APP_NAME.app" 2>/dev/null || true

# Make sure Finder metadata is writable and volume has a place for custom window layout.
mkdir -p "$MNTPNT/.background"
touch "$MNTPNT/.metadata_never_index" 2>/dev/null || true

# Set up Finder view via AppleScript
osascript -e "
tell application \"Finder\"
  tell disk \"$VOLUME_NAME\"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {420, 220, 920, 560}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set position of item \"$APP_NAME.app\" to {130, 155}
    set position of item \"Applications\" to {370, 155}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
" 2>/dev/null || true

sleep 2
hdiutil detach "$MNTPNT"
sleep 1

echo "==> Convert to compressed DMG"
rm -f "$DMG_PATH"
hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG_PATH" >/dev/null
rm -f "$TMP_DMG"

echo "==> Remove quarantine from generated DMG if present"
xattr -d com.apple.quarantine "$DMG_PATH" 2>/dev/null || true

echo "==> Verify dmg"
hdiutil verify "$DMG_PATH"

echo "==> Verify DMG contents include app and Applications symlink"
VERIFY_MOUNT="/Volumes/${VOLUME_NAME}_verify"
hdiutil detach "$VERIFY_MOUNT" 2>/dev/null || true
hdiutil attach "$DMG_PATH" -readonly -noverify -noautoopen -mountpoint "$VERIFY_MOUNT" 2>/dev/null || true
test -d "$VERIFY_MOUNT/$APP_NAME.app" || { echo "ERROR: $APP_NAME.app missing in DMG"; exit 1; }
test -L "$VERIFY_MOUNT/Applications" || { echo "ERROR: Applications symlink missing in DMG"; exit 1; }
echo "  OK: app and Applications symlink present"
hdiutil detach "$VERIFY_MOUNT" 2>/dev/null || true

echo "==> SHA256"
shasum -a 256 "$DMG_PATH"

echo "==> Done"
echo "$DMG_PATH"
