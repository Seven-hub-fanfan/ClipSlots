#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClipSlots"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
STAGING_DIR="$BUILD_DIR/dmg_staging"
TMP_DMG="$BUILD_DIR/tmp.dmg"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Info.plist" 2>/dev/null || echo "dev")"
# 版本化命名，匹配 GitHub Release 资产命名约定 (ClipSlots_v<version>.dmg)
DMG_PATH="$BUILD_DIR/${APP_NAME}_v${VERSION}.dmg"
VOLUME_NAME="$APP_NAME v$VERSION"
DMG_SIZE="260m"
BACKGROUND_DIR="$BUILD_DIR/dmg_background"
BACKGROUND_PNG="$BACKGROUND_DIR/background.png"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

die() { echo "ERROR: $*" >&2; exit 1; }
detach_if_mounted() { hdiutil detach "$1" 2>/dev/null || true; }
ensure_applications_symlink() {
  local dir="$1"
  rm -rf "$dir/Applications"
  ln -s /Applications "$dir/Applications"
  test -L "$dir/Applications" || die "Applications symlink missing in $dir"
  test "$(readlink "$dir/Applications")" = "/Applications" || die "Applications symlink target invalid in $dir"
}
verify_app_bundle() {
  local app="$1"
  test -d "$app" || die "$app missing"
  test -x "$app/Contents/MacOS/$APP_NAME" || die "$APP_NAME executable missing or not executable"
  test -x "$app/Contents/MacOS/clipslots-cli" || die "bundled clipslots-cli missing or not executable in $app"
  test -f "$app/Contents/Resources/skills/clipslots-manager/SKILL.md" || die "bundled skill missing in $app"
  plutil -lint "$app/Contents/Info.plist" >/dev/null
  test -f "$app/Contents/Resources/AppIcon.icns" || die "AppIcon.icns missing in app bundle"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist" >/dev/null || die "CFBundleIconFile missing"
  codesign --verify --deep --strict --verbose=2 "$app"
}
sign_app_bundle() {
  local app="$1"
  if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> Sign app with Developer ID: $SIGN_IDENTITY"
    codesign --force --deep --timestamp --options runtime --sign "$SIGN_IDENTITY" "$app"
  else
    echo "==> Sign app adhoc (set SIGN_IDENTITY for Gatekeeper-safe release)"
    codesign --force --deep --timestamp=none --sign - "$app"
  fi
  verify_app_bundle "$app"
}
notarize_and_staple_if_configured() {
  local dmg="$1"
  if [ "$SKIP_NOTARIZE" = "1" ]; then
    echo "==> Skip notarization by SKIP_NOTARIZE=1"
    return
  fi
  if [ -z "$SIGN_IDENTITY" ] || [ -z "$NOTARY_PROFILE" ]; then
    die "Release DMG is not notarized. Set SIGN_IDENTITY='Developer ID Application: ...' and NOTARY_PROFILE='...' or explicitly set SKIP_NOTARIZE=1 for local-only testing."
  fi
  echo "==> Notarize DMG"
  xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Staple DMG"
  xcrun stapler staple "$dmg"
  echo "==> Gatekeeper assess"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
}
export BACKGROUND_PNG
create_dmg_background() {
mkdir -p "$BACKGROUND_DIR"
python3 - <<'PY'
from pathlib import Path
import os, struct, zlib
out = Path(os.environ["BACKGROUND_PNG"])
W,H = 640,360
def chunk(t, data):
    return struct.pack('>I', len(data)) + t + data + struct.pack('>I', zlib.crc32(t + data) & 0xffffffff)
rows=[]
for y in range(H):
    t=y/H
    r=int(248-t*8); g=int(249-t*9); b=int(251-t*7)
    row=bytearray([0])
    for x in range(W):
        row.extend((r,g,b))
    rows.append(bytes(row))
raw=b''.join(rows)
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB', W,H,8,2,0,0,0))+chunk(b'IDAT', zlib.compress(raw,9))+chunk(b'IEND', b'')
out.write_bytes(png)
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
  die "AppIcon.icns not found; release would lose app icon"
fi
test -s "$APP_DIR/Contents/Resources/AppIcon.icns" || die "AppIcon.icns is empty"

chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# ---------------------------------------------------------------------------
# v2.9.28: 把内置 CLI 二进制 (clipslots-cli) 打进 App bundle。
# 根因：v2.9.27 打包脚本重写后遗漏了 CLI 拷贝，导致「设置 -> 安装 CLI」报错
#       "找不到内置 CLI 二进制 (clipslots-cli)"（CLIInstallManager 期望路径
#        <bundle>/Contents/MacOS/clipslots-cli）。
# 说明：SPM 可执行 target 名为 ClipSlotsCLI，产物为 .build/release/ClipSlotsCLI，
#       但因大小写不敏感文件系统会与 GUI 二进制 ClipSlots 同名冲突，故落地为
#       clipslots-cli。此处固化为永久步骤，每次发版都会打包 CLI。
# ---------------------------------------------------------------------------
CLI_SRC="$ROOT_DIR/.build/release/ClipSlotsCLI"
CLI_DST="$APP_DIR/Contents/MacOS/clipslots-cli"
test -f "$CLI_SRC" || die "CLI binary not found at $CLI_SRC (SPM target ClipSlotsCLI). Did 'swift build -c release' succeed?"
cp "$CLI_SRC" "$CLI_DST"
chmod +x "$CLI_DST"
codesign --force --timestamp=none --sign - "$CLI_DST"
test -x "$CLI_DST" || die "bundled clipslots-cli missing or not executable at $CLI_DST"
echo "  OK: bundled clipslots-cli -> $CLI_DST"

# ---------------------------------------------------------------------------
# v2.9.28: 把内置 Skill 目录打进 App bundle。
# 根因：同上，v2.9.27 脚本重写遗漏了 skills 拷贝，导致 Skill 市场"安装到 Agent"
#       找不到内置 Skill 源目录（AgentSkillInstallManager 期望
#        <bundle>/Contents/Resources/skills/clipslots-manager）。
# ---------------------------------------------------------------------------
if [ -d "$ROOT_DIR/skills/clipslots-manager" ]; then
  mkdir -p "$APP_DIR/Contents/Resources/skills"
  ditto "$ROOT_DIR/skills/clipslots-manager" "$APP_DIR/Contents/Resources/skills/clipslots-manager"
  test -f "$APP_DIR/Contents/Resources/skills/clipslots-manager/SKILL.md" || die "bundled skill SKILL.md missing"
  echo "  OK: bundled skill -> $APP_DIR/Contents/Resources/skills/clipslots-manager"
else
  die "skills/clipslots-manager not found; Skill install feature would break"
fi


echo "==> Remove quarantine / stale extended attributes from app before DMG"
xattr -cr "$APP_DIR" 2>/dev/null || true

echo "==> Sign app bundle after xattr cleanup"
sign_app_bundle "$APP_DIR"

echo "==> Validate app bundle"
plutil -lint "$APP_DIR/Contents/Info.plist"
file "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "==> Prepare DMG staging"
mkdir -p "$STAGING_DIR"
ditto "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"
ensure_applications_symlink "$STAGING_DIR"
xattr -cr "$STAGING_DIR" 2>/dev/null || true
verify_app_bundle "$STAGING_DIR/$APP_NAME.app"
export BACKGROUND_PNG
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
sign_app_bundle "$MNTPNT/$APP_NAME.app"

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
    set icon size of viewOptions to 112
    try
    set background picture of viewOptions to file ".background:background.png"
    end try
    set position of item \"$APP_NAME.app\" to {150, 176}
    set position of item \"Applications\" to {490, 176}
    set label position of viewOptions to bottom
    update without registering applications
    delay 2
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

notarize_and_staple_if_configured "$DMG_PATH"

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
test -f "$VERIFY_MOUNT/$APP_NAME.app/Contents/Resources/AppIcon.icns" || die "AppIcon.icns missing in final DMG"
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
