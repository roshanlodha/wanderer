#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$ROOT_DIR/Wanderer.swiftpm"
BUILD_DIR="$ROOT_DIR/.build"
ARCHIVE_PATH="$BUILD_DIR/Wanderer.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
TEMP_DMG_DIR="$BUILD_DIR/dmg-root"
DMG_PATH="$ROOT_DIR/Wanderer.dmg"
APP_NAME="Wanderer.app"

echo "Building Wanderer..."
mkdir -p "$BUILD_DIR" "$EXPORT_PATH"

pushd "$PROJECT_DIR" >/dev/null
xcodebuild \
  -scheme Wanderer \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  archive

cat > "$BUILD_DIR/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>export</string>
    <key>method</key>
    <string>mac-application</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>87QG8P4C9A</string>
</dict>
</plist>
PLIST

xcodebuild \
  -archivePath "$ARCHIVE_PATH" \
  -exportArchive \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_PATH"
popd >/dev/null

APP_BUNDLE="$EXPORT_PATH/$APP_NAME"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Expected exported app at $APP_BUNDLE" >&2
  exit 1
fi

rm -rf "$TEMP_DMG_DIR"
mkdir -p "$TEMP_DMG_DIR"
cp -R "$APP_BUNDLE" "$TEMP_DMG_DIR/"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "Wanderer" \
  -srcfolder "$TEMP_DMG_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$TEMP_DMG_DIR"

echo "Created $DMG_PATH"