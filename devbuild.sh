#!/bin/bash
# Builds the same source WITHOUT LSUIElement, so the app is visible to
# computer-use screenshots (the shipping app is menu-bar-only and is not).
# Quit the real app first - both take the same ~/.oneticker.lock.
set -e
cd "$(dirname "$0")"
APPNAME="OneTicker Dev"
APP="/tmp/devbuild/${APPNAME}.app"
rm -rf /tmp/devbuild
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
swiftc -O -o "${APP}/Contents/MacOS/${APPNAME}" Sources/OneTicker/main.swift
cp icon/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
cat > "${APP}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.petrakovic.oneticker.dev</string>
    <key>CFBundleName</key><string>OneTicker</string>
    <key>CFBundleDisplayName</key><string>OneTicker Dev</string>
    <key>CFBundleExecutable</key><string>OneTicker Dev</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>2.4.0</string>
    <key>CFBundleVersion</key><string>2.4.0</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Ranko Petrakovic. All rights reserved.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --sign - --force "${APP}" 2>&1 | tail -1
rm -rf "/Applications/${APPNAME}.app"
cp -r "${APP}" /Applications/
echo "dev installed: /Applications/${APPNAME}.app"
