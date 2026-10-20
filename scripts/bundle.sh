#!/bin/bash
# Builds a universal "007 Notes.app" and zips it. Runs on macOS (GitHub Actions or locally).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(cat VERSION)
BUILD=${GITHUB_RUN_NUMBER:-1}
APP="build/007 Notes.app"

swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/AppIcon.iconset
cp "$BIN_DIR/Notes007" "$APP/Contents/MacOS/Notes007"

for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d Resources/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/background.jpg "$APP/Contents/Resources/background.jpg"

sed "s/__VERSION__/$VERSION/g; s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
ditto -c -k --keepParent "$APP" "build/007-Notes-$VERSION.zip"
echo "Built build/007-Notes-$VERSION.zip"
