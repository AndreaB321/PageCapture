# Document fixtures

Small documents that `DocumentConverterTests` converts with the bundled MarkItDown. They are made
by `scripts/make-document-fixtures.sh`; run it only when they need to change, and commit the output.

| File | Made with | Text the tests look for |
|---|---|---|
| `text.pdf` | `cupsfilter` from a plain text file | "Migratory Birds of the Lagoon" |
| `document.docx` | a hand-written WordprocessingML package (Python `zipfile`) | heading "Quarterly Garden Review", table cell "37 kg" |
| `slides.pptx` | python-pptx from the bundled runtime | slide title "Volcano Survey" |
| `sheet.xlsx` | openpyxl from the bundled runtime | sheet "Inventory", cell "Lanterns" |
| `page.html` | written by hand | heading "Harbour Report", table cell "Northwind" |
| `corrupt.docx` | 4 KB from `/dev/urandom` | none: conversion must fail |

The PDF without text for the fallback test is drawn by the test itself with CoreGraphics.
