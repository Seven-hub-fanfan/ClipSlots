#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSET_DIR="$ROOT_DIR/assets"
SVG_PATH="$ASSET_DIR/AppIcon.svg"
PNG_PATH="$ASSET_DIR/AppIcon.png"
ICONSET_DIR="$ASSET_DIR/AppIcon.iconset"
ICNS_PATH="$ASSET_DIR/AppIcon.icns"

echo "==> ClipSlots App Icon Generator"

if [ ! -f "$SVG_PATH" ]; then
  echo "Error: missing $SVG_PATH"
  exit 1
fi

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

# 1. Convert SVG to 1024 PNG
if command -v rsvg-convert >/dev/null 2>&1; then
  echo "==> Using rsvg-convert"
  rsvg-convert -w 1024 -h 1024 "$SVG_PATH" -o "$PNG_PATH"
elif command -v qlmanage >/dev/null 2>&1; then
  echo "==> Using qlmanage preview generator"
  TMP_DIR="$(mktemp -d)"
  qlmanage -t -s 1024 -o "$TMP_DIR" "$SVG_PATH" >/dev/null 2>&1 || true
  GENERATED="$(find "$TMP_DIR" -name "*.png" | head -n 1 || true)"
  if [ -z "$GENERATED" ]; then
    echo "Error: qlmanage failed to convert SVG."
    echo "Please export assets/AppIcon.svg to assets/AppIcon.png manually at 1024x1024, then rerun this script."
    exit 1
  fi
  cp "$GENERATED" "$PNG_PATH"
  rm -rf "$TMP_DIR"
else
  echo "Error: no SVG converter found."
  echo "Install librsvg:"
  echo "  brew install librsvg"
  echo "Or manually export assets/AppIcon.svg to assets/AppIcon.png at 1024x1024."
  exit 1
fi

if [ ! -f "$PNG_PATH" ]; then
  echo "Error: missing generated $PNG_PATH"
  exit 1
fi

echo "==> Generating iconset"

sips -z 16 16       "$PNG_PATH" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32       "$PNG_PATH" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32       "$PNG_PATH" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64       "$PNG_PATH" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128     "$PNG_PATH" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256     "$PNG_PATH" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256     "$PNG_PATH" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512     "$PNG_PATH" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512     "$PNG_PATH" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024   "$PNG_PATH" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

echo "==> Creating icns"
rm -f "$ICNS_PATH"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

echo "==> Done"
echo "Generated:"
echo "  $PNG_PATH"
echo "  $ICNS_PATH"
