#!/bin/bash
# Regenerates the small documents in Tests/PageCaptureCoreTests/Fixtures/documents/ that
# DocumentConverterTests converts with the bundled MarkItDown. Needs build/tools/markitdown
# (scripts/fetch-tools.sh markitdown) for python-pptx and openpyxl, and macOS cupsfilter for the
# PDF. Run it only when the fixtures need to change; the output is committed.
set -euo pipefail
cd "$(dirname "$0")/.."

PY=build/tools/markitdown/bin/python3
OUT=Tests/PageCaptureCoreTests/Fixtures/documents
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

cat > "$OUT/page.html" <<'EOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Fixture page</title></head>
<body>
<h1>Harbour Report</h1>
<p>The lighthouse keeper counts ships.</p>
<table>
<tr><th>Ship</th><th>Tonnage</th></tr>
<tr><td>Northwind</td><td>4200</td></tr>
</table>
</body></html>
EOF

printf 'Migratory Birds of the Lagoon\n\nThe heron arrives in early spring.\n' > "$WORK/text.txt"
cupsfilter -m application/pdf "$WORK/text.txt" > "$OUT/text.pdf" 2>/dev/null

"$PY" -I -B - "$OUT" <<'EOF'
import sys
from pptx import Presentation
from openpyxl import Workbook
out = sys.argv[1]
deck = Presentation()
slide = deck.slides.add_slide(deck.slide_layouts[1])
slide.shapes.title.text = "Volcano Survey"
slide.placeholders[1].text = "Basalt samples collected at dawn"
deck.save(f"{out}/slides.pptx")
book = Workbook()
sheet = book.active
sheet.title = "Inventory"
sheet.append(["Item", "Count"])
sheet.append(["Lanterns", 12])
book.save(f"{out}/sheet.xlsx")

# A minimal WordprocessingML package: a "heading 1" paragraph, a paragraph and a 2x2 table.
import zipfile
W = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
def p(text, style=None):
    ppr = f'<w:pPr><w:pStyle w:val="{style}"/></w:pPr>' if style else ''
    return f'<w:p>{ppr}<w:r><w:t>{text}</w:t></w:r></w:p>'
def row(*cells):
    return '<w:tr>' + ''.join(f'<w:tc>{p(c)}</w:tc>' for c in cells) + '</w:tr>'
body = (p("Quarterly Garden Review", "Heading1") + p("Tomatoes did well this season.")
        + '<w:tbl><w:tblPr/>' + row("Vegetable", "Yield") + row("Courgette", "37 kg") + '</w:tbl>')
files = {
    "[Content_Types].xml": '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>',
    "_rels/.rels": '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
    "word/_rels/document.xml.rels": '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
    "word/styles.xml": f'<?xml version="1.0" encoding="UTF-8"?><w:styles {W}><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style></w:styles>',
    "word/document.xml": f'<?xml version="1.0" encoding="UTF-8"?><w:document {W}><w:body>{body}</w:body></w:document>',
}
with zipfile.ZipFile(f"{out}/document.docx", "w", zipfile.ZIP_DEFLATED) as z:
    for name, data in files.items():
        z.writestr(zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0)), data)
EOF

# Not a zip archive, so not a DOCX: MarkItDown must fail on it.
head -c 4096 /dev/urandom > "$OUT/corrupt.docx"
