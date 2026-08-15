#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/GHMenuBar.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/swift_env.sh"

swift build "${SWIFTPM_CACHE_ARGS[@]}" -c release >/dev/null
BIN_DIR="$(swift build "${SWIFTPM_CACHE_ARGS[@]}" -c release --show-bin-path)"
BINARY="$BIN_DIR/GHMenuBar"

if [[ ! -x "$BINARY" ]]; then
  echo "Missing built binary at $BINARY" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY" "$MACOS_DIR/GHMenuBar"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>GHMenuBar</string>
  <key>CFBundleIdentifier</key>
  <string>dev.ghmenubar.GHMenuBar</string>
  <key>CFBundleName</key>
  <string>GHMenuBar</string>
  <key>CFBundleDisplayName</key>
  <string>GHMenuBar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
