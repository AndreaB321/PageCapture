#!/bin/bash
# Builds build/PageCapture.app from the SwiftPM release build plus the bundled tools, and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

# CFBundleShortVersionString; make-source-bundle.sh names the sources bundle after it.
APP_VERSION=0.1.0

scripts/fetch-tools.sh

swift build -c release --product PageCapture
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/PageCapture.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" \
    "$APP/Contents/Resources/ThirdPartyNotices"
cp "$BIN_DIR/PageCapture" "$APP/Contents/MacOS/PageCapture"
# The injected scripts; CaptureScripts looks in the main bundle's Resources first.
cp Sources/PageCaptureCore/Resources/*.js "$APP/Contents/Resources/"
cp Assets/AppIcon.icns Assets/header-avatar.png "$APP/Contents/Resources/"
# The user manual (Help > PageCapture Manual): index.html and its images.
mkdir -p "$APP/Contents/Resources/Manual"
cp -R docs/manual/. "$APP/Contents/Resources/Manual/"
find "$APP/Contents/Resources/Manual" -name .DS_Store -delete
# ffmpeg, ffprobe, yt-dlp and Deno (see Tools.swift), with their licences.
for tool in ffmpeg ffprobe yt-dlp deno; do
    cp "build/tools/$tool" "$APP/Contents/Helpers/$tool"
done
cp build/notices/* "$APP/Contents/Resources/ThirdPartyNotices/"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/ThirdPartyNotices/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleExecutable</key><string>PageCapture</string>
    <key>CFBundleIdentifier</key><string>local.pagecapture.PageCapture</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>PageCapture</string>
    <key>CFBundleDisplayName</key><string>PageCapture</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST

# Nested code first, each tool on its own, then the app, which seals them in.
for tool in "$APP"/Contents/Helpers/*; do
    codesign --force -s - "$tool"
done
codesign --force -s - "$APP"
echo "Built $APP"
