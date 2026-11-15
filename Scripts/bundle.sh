#!/bin/bash
# Builds Focal.app into ./build. Usage: Scripts/bundle.sh [run]
# Signs with the "Focal Dev" identity when present (stable, so the Accessibility grant survives rebuilds),
# otherwise ad-hoc (which resets the grant on every build). Override with SIGN_ID.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/Focal.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Focal "$APP/Contents/MacOS/Focal"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.focal.app</string>
  <key>CFBundleName</key><string>Focal</string>
  <key>CFBundleExecutable</key><string>Focal</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ -z "${SIGN_ID:-}" ]; then
  if security find-identity -v -p codesigning | grep -q "Focal Dev"; then SIGN_ID="Focal Dev"; else SIGN_ID="-"; fi
fi
codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $APP"
[ "${1:-}" = "run" ] && open "$APP"
