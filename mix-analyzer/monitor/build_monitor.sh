#!/bin/bash
# Compila o monitor visual (SwiftUI, arquivo único) num .app nesta pasta.
set -euo pipefail
cd "$(dirname "$0")"
APP="DMusic Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -parse-as-library -O MixMonitor.swift -o "$APP/Contents/MacOS/DMusicMonitor"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DMusic Monitor</string>
    <key>CFBundleIdentifier</key><string>com.diniz.dmusic-monitor</string>
    <key>CFBundleExecutable</key><string>DMusicMonitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "ok: $(pwd)/$APP"
