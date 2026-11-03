#!/bin/bash
# Builds Assets/AppIcon.icns from Assets/icon-source.png (1024×1024 artwork).
# The artwork is scaled into the macOS icon grid (824 px inside 1024) and its corners clipped
# to a rounded square, so the source's white corners become transparent.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="build/icon"
rm -rf "$WORK"
mkdir -p "$WORK/AppIcon.iconset"

swift - Assets/icon-source.png "$WORK/icon-1024.png" <<'SWIFT'
import AppKit
let args = CommandLine.arguments
let source = NSImage(contentsOfFile: args[1])!
let size = 1024, inset = 100.0, side = 824.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: inset, y: inset, width: side, height: side)
NSBezierPath(roundedRect: rect, xRadius: side * 0.225, yRadius: side * 0.225).addClip()
source.draw(in: rect)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
SWIFT

for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o Assets/AppIcon.icns
rm -rf "$WORK"
echo "Built Assets/AppIcon.icns"
