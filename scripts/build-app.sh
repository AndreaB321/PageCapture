#!/bin/bash
# Builds build/PageCapture.app from the SwiftPM release build plus the bundled tools, and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

# CFBundleShortVersionString; make-source-bundle.sh names the sources bundle after it.
APP_VERSION=0.2.0

scripts/fetch-tools.sh

swift build -c release --product PageCapture
swift build -c release --product pagecapture-ocr
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/PageCapture.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" \
    "$APP/Contents/Resources/ThirdPartyNotices"
cp "$BIN_DIR/PageCapture" "$APP/Contents/MacOS/PageCapture"
# The sandboxed OCR helper (signed with the other Helpers below).
cp "$BIN_DIR/pagecapture-ocr" "$APP/Contents/Helpers/pagecapture-ocr"
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
# The MarkItDown runtime, a Python tree: Helpers/markitdown/bin/python3 -m markitdown. It sits in
# Resources, because codesign takes every file in Helpers for code and rejects the .py files;
# Helpers/markitdown links to it.
. scripts/tool-pins.sh
[[ -f "$CACHE/markitdown.tree" && "$(md_tree_digest build/tools/markitdown)" == "$(cat "$CACHE/markitdown.tree")" ]] \
    || { echo "build/tools/markitdown changed since it was built; delete it and rerun fetch-tools.sh markitdown" >&2; exit 1; }
cp -R build/tools/markitdown "$APP/Contents/Resources/markitdown"
ln -s ../Resources/markitdown "$APP/Contents/Helpers/markitdown"
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

# Nested code first, each tool on its own, then the app, which seals them in. For markitdown that
# is every Mach-O file in its tree (the interpreter, libpython, extension modules, dylibs).
for tool in "$APP"/Contents/Helpers/*; do
    [[ -L "$tool" ]] || codesign --force -s - "$tool"
done
find "$APP/Contents/Resources/markitdown" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) \
    -print0 | while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q '^Mach-O'; then
        codesign --force -s - "$f"
    fi
done
codesign --force -s - "$APP"
echo "Built $APP"
