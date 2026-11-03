#!/bin/bash
# Builds build/PageCapture.dmg: the app plus an Applications link to drag it onto.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

STAGE="build/dmg-stage"
DMG="build/PageCapture.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/PageCapture.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname PageCapture -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
