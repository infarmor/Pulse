#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="${1:-release}"
EXEC_NAME="PulseBar"
APP_DISPLAY_NAME="PulseBar"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_DISPLAY_NAME.app"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"

echo "Building $APP_DISPLAY_NAME ($CONFIG)..."
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN_PATH="$BIN_DIR/$EXEC_NAME"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "Error: executable not found at $BIN_PATH" >&2
    exit 1
fi

rm -rf "$APP_BUNDLE" "$ICONSET_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

if command -v iconutil >/dev/null 2>&1; then
    swift "$ROOT_DIR/scripts/generate_icon.swift" "$ICONSET_DIR"
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET_DIR"
fi

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "Built bundle: $APP_BUNDLE"
