#!/bin/bash
# TEMPORARY CI diagnostics for the OCR helper's sandbox on the macos-26 VM. Not to be merged.
set -u
HELPER=$(realpath .build/debug/pagecapture-ocr)
D=$(realpath "$(mktemp -d)")
cat > "$D/mk.swift" <<'EOF'
import CoreGraphics
import CoreText
import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let size = CGSize(width: 612, height: 792), scale: CGFloat = 4
let bitmap = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                       bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
bitmap.setFillColor(gray: 1, alpha: 1)
bitmap.fill(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
bitmap.scaleBy(x: scale, y: scale)
let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
let text = NSAttributedString(string: "PageCapture reads scanned pages", attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
bitmap.textPosition = CGPoint(x: 50, y: 650)
CTLineDraw(CTLineCreateWithAttributedString(text), bitmap)
let image = bitmap.makeImage()!
var box = CGRect(origin: .zero, size: size)
let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
pdf.beginPDFPage(nil)
pdf.draw(image, in: box)
pdf.endPDFPage()
pdf.closePDF()
EOF
swift "$D/mk.swift" "$D/scan.pdf" || exit 0
PROFILE=$(awk '/static let ocrSandboxProfile = """/{f=1;next} f&&/"""/{exit} f' Sources/PageCaptureCore/DocumentConverter.swift)

run() {
    echo "=== $1"
    local start
    start=$(date '+%Y-%m-%d %H:%M:%S')
    (cd "$D" && /usr/bin/time -p env -i PATH=/usr/bin:/bin HOME="$D" TMPDIR="$D" LANG=en_US.UTF-8 \
        sandbox-exec -D WORK_DIR="$D" -D HELPER="$HELPER" -D HELPER_DIR="$(dirname "$HELPER")" -p "$2" \
        "$HELPER" "$D/scan.pdf")
    echo "exit $?"
    sleep 3
    log show --start "$start" --style compact --info --debug \
        --predicate 'eventMessage CONTAINS "pagecapture-ocr" OR process == "pagecapture-ocr"' 2>/dev/null \
        | grep -iE 'deny|sandbox|metal|iokit|gpu|error|fail|paravirt|accel' | sed -E 's/^[0-9-]+ [0-9:.]+ //; s/\[[0-9]+(:[0-9a-f]+)?\]//g; s/[0-9]+:[0-9a-f]+\]/]/g; s/instance = [A-F0-9-]+, //; s/\([0-9]+\)//g' | cut -c1-400 | sort | uniq -c | sort -rn | head -80
}

echo "=== unsandboxed"
(cd "$D" && /usr/bin/time -p "$HELPER" "$D/scan.pdf"); echo "exit $?"
run "profile as is" "$PROFILE"
run "without AppleParavirtDeviceUserClient" "$(echo "$PROFILE" | grep -v AppleParavirtDeviceUserClient)"
run "without MTLCompilerService" "$(echo "$PROFILE" | grep -v MTLCompilerService)"
exit 0
