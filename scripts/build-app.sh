#!/usr/bin/env bash
# Builds HeatWatch.app into ./build. Pass --install to copy it to
# /Applications and (re)launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/HeatWatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/HeatWatch "$APP/Contents/MacOS/HeatWatch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/HeatWatch.app"
    pkill -x HeatWatch 2>/dev/null || true
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "Installed and launched $DEST"
fi
