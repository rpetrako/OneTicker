#!/bin/bash
set -e
cd "$(dirname "$0")"

APPNAME="OneTicker"
BUNDLEID="com.petrakovic.oneticker"
APP="dist_swift/${APPNAME}.app"

rm -rf dist_swift
mkdir -p "${APP}/Contents/MacOS"

# Compile
swiftc -O -o "${APP}/Contents/MacOS/${APPNAME}" Sources/OneTicker/main.swift

# Info.plist
cat > "${APP}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLEID}</string>
    <key>CFBundleName</key>
    <string>${APPNAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APPNAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APPNAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>2.4.0</string>
    <key>CFBundleVersion</key>
    <string>2.4.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Ranko Petrakovic. All rights reserved.</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# App icon. The .icns is derived and not in git, so build it on demand.
if [ ! -f icon/AppIcon.icns ] && [ -f icon/AppIcon-1024.png ]; then
  echo "AppIcon.icns missing, generating from master"
  bash icon/make_icns.sh > /dev/null
fi
if [ -f icon/AppIcon.icns ]; then
  mkdir -p "${APP}/Contents/Resources"
  cp icon/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
else
  echo "warning: no icon master at icon/AppIcon-1024.png, building without an app icon"
fi

# Ad-hoc sign so macOS runs it without prompts
codesign --sign - --force "${APP}"

echo "Built ${APP}"

# Install
rm -rf "/Applications/${APPNAME}.app"
cp -r "${APP}" "/Applications/"
echo "Installed to /Applications/${APPNAME}.app"
