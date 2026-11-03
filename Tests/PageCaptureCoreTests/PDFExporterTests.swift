import JavaScriptCore
import PDFKit
import WebKit
import XCTest
@testable import PageCaptureCore

/// Prints a long captured fragment to PDF in an off-screen web view and inspects it with PDFKit.
@MainActor
final class PDFExporterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PDFExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(FixtureSchemeHandler(), forURLScheme: FixtureSchemeHandler.scheme)
        return configuration
    }

    /// A long article inside a virtualised-list spacer (padding-top and height of thousands of pixels).
    static func longContent() -> CapturedContent {
        let paragraphs = (0..<80).map { "<p>Paragraph \(String(format: "%03d", $0)) of the long fixture text.</p>" }
        let html = """
        <h1>Long fixture</h1>
        <p>See <a href="https://example.com/target">the target link</a> for details.</p>
        <p><img src="pctest://main.test/img/a.png" alt="pixel" width="40" height="40"></p>
        <div style="padding-top: 20000px; height: 30000px; color: black">\(paragraphs.joined())</div>
        """
        return CapturedContent(
            html: html, baseURL: URL(string: "pctest://main.test/docs/page.html")!, title: "Long fixture",
            stylesheets: [.link(URL(string: "pctest://main.test/styles/main.css")!), .inline("p { margin: 0 0 12px; }")],
            imageURLs: ["pctest://main.test/img/a.png"])
    }

    func testLongCaptureGivesPagesWithTextAndClickableLinks() async throws {
        let url = folder.appendingPathComponent("Long.pdf")
        try await PDFExporter.write(Self.longContent(), localImages: [:], to: url,
                                    configuration: Self.configuration(), paperSize: .a4)

        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        let text = try XCTUnwrap(pdf.string)
        XCTAssertTrue(text.contains("Long fixture"))
        XCTAssertTrue(text.contains("Paragraph 000"))
        XCTAssertTrue(text.contains("Paragraph 079"))
        let links = (0..<pdf.pageCount).flatMap { pdf.page(at: $0)?.annotations ?? [] }.compactMap(\.url)
        XCTAssertTrue(links.contains(URL(string: "https://example.com/target")!), "links: \(links)")
        let size = try XCTUnwrap(pdf.page(at: 0)?.bounds(for: .mediaBox).size)
        XCTAssertEqual(size.width, 595, accuracy: 1)
        XCTAssertEqual(size.height, 842, accuracy: 1)
    }

    /// A long article in grey rounded cards (clipping their content) and two-column flex rows (icon +
    /// text), with a desktop-only rule that must not apply at the printable width.
    static func cardsContent() -> CapturedContent {
        let words = "Network automation keeps every device in the lab consistent, so a change that works on one"
            + " router is applied the same way to all the others without typing it again by hand."
        var sections: [String] = []
        var images: [String] = []
        for n in 0..<8 {
            let paragraphs = (0..<3).map { "<p>Card \(n) paragraph \($0). \(words) \(words) \(words)</p>" }
            let rows = (0..<3).map {
                images.append("pctest://main.test/img/step-\(n)-\($0).png")
                return """
                <div class="step"><img src="pctest://main.test/img/step-\(n)-\($0).png" alt="">\
                <div class="step-text"><b>Step \(n).\($0)</b> \(words)</div></div>
                """
            }
            images.append("pctest://main.test/img/card-\(n).png")
            sections.append("""
            <h2>Section \(n)</h2>
            <p>Intro \(n). \(words) \(words)</p>
            <div class="card">\(paragraphs.joined())</div>
            <div class="card grid"><img src="pctest://main.test/img/card-\(n).png" alt=""><div>\(paragraphs.joined())</div></div>
            <div class="steps">\(rows.joined())</div>
            """)
        }
        let css = """
        body { font: 16px/1.5 Helvetica, Arial, sans-serif; margin: 0; }
        h1 { font-size: 32px; margin: 0 0 16px; } h2 { font-size: 24px; margin: 24px 0 12px; }
        p { margin: 0 0 12px; }
        .card { background: #e8e8e8; border-radius: 16px; overflow: hidden; padding: 24px; margin: 16px 0; }
        .steps { overflow: hidden; border-radius: 8px; }
        .grid { display: grid; grid-template-columns: 48px 1fr; gap: 16px; }
        .grid > img { width: 48px; height: 48px; }
        .article { overflow-y: auto; }
        .step { display: flex; gap: 16px; align-items: center; height: 120px; overflow: hidden; }
        .step img { flex: none; width: 48px; height: 48px; border-radius: 50%; background: #fc0; }
        @media (min-width: 900px) { .article { width: 1100px; } }
        """
        return CapturedContent(
            html: "<div class=\"article\"><h1>Cards fixture</h1>\(sections.joined())</div>",
            baseURL: URL(string: "pctest://main.test/docs/page.html")!, title: "Cards",
            stylesheets: [.inline(css)], imageURLs: images)
    }

    /// Pages lay out their content in tall flex columns, where WebKit ignores `break-inside: avoid`:
    /// a figure (an image in a link) must still not be sliced at a page break.
    func testFiguresInATallFlexColumnAreNotSliced() async throws {
        let icon = folder.appendingPathComponent("figure.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<8 { for y in 0..<8 { bitmap.setColor(NSColor(deviceRed: x < 4 ? 1 : 0, green: 0.4, blue: x < 4 ? 0 : 1, alpha: 1), atX: x, y: y) } }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: icon)
        let words = String(repeating: "Local deployment keeps data inside the network perimeter. ", count: 6)
        var images: [String] = []
        let items = (0..<12).map { n -> String in
            images.append("pctest://main.test/img/figure-\(n).png")
            return """
            <p>Paragraph \(n). \(words)</p>
            <div><figure class="figure"><a href="https://example.com/figure-\(n).png">\
            <img src="pctest://main.test/img/figure-\(n).png" alt="" style="width: 420px; height: 300px"></a></figure></div>
            """
        }
        let content = CapturedContent(
            html: #"<div class="page"><div class="column">\#(items.joined())</div></div>"#,
            baseURL: URL(string: "pctest://main.test/docs/page.html")!, title: "Figures",
            stylesheets: [.inline("""
                body { font: 16px/1.5 Helvetica, sans-serif; margin: 0; }
                .page { display: flex; } .column { display: flex; flex-direction: column; gap: 24px; flex: 1; }
                .figure { display: contents; } p { margin: 0; }
                """)],
            imageURLs: images)
        let url = folder.appendingPathComponent("Figures.pdf")
        try await PDFExporter.write(content, localImages: Dictionary(uniqueKeysWithValues: images.map { ($0, icon) }),
                                    to: url, configuration: Self.configuration(), paperSize: .a4)

        let pdf = try XCTUnwrap(PDFDocument(url: url))
        var drawn = 0
        for index in 0..<pdf.pageCount {
            let page = try XCTUnwrap(pdf.page(at: index))
            let printable = page.bounds(for: .mediaBox).insetBy(dx: 36, dy: 36).insetBy(dx: -0.5, dy: -0.5)
            for image in Self.imageRects(on: try XCTUnwrap(page.pageRef)) {
                drawn += 1
                XCTAssertTrue(printable.contains(image), "page \(index + 1): image at \(image) crosses \(printable)")
            }
        }
        XCTAssertEqual(drawn, images.count, "each figure drawn once, whole")
    }

    /// Text prints at its CSS size, and page breaks fall between text lines and outside images.
    func testCardsPrintAtCSSSizeWithoutSlicingLinesOrImages() async throws {
        let url = folder.appendingPathComponent("Cards.pdf")
        // A two-colour icon: WebKit fills a one-colour image as a rectangle rather than drawing it.
        let icon = folder.appendingPathComponent("icon.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<8 { for y in 0..<8 { bitmap.setColor(NSColor(deviceRed: x < 4 ? 1 : 0, green: 0.4, blue: x < 4 ? 0 : 1, alpha: 1), atX: x, y: y) } }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: icon)
        let content = Self.cardsContent()
        let localImages = Dictionary(uniqueKeysWithValues: content.imageURLs.map { ($0, icon) })
        try await PDFExporter.write(content, localImages: localImages, to: url,
                                    configuration: Self.configuration(), paperSize: .a4)
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(pdf.pageCount, 3)

        func fontSize(_ text: String) throws -> CGFloat {
            let selection = try XCTUnwrap(pdf.findString(text, withOptions: []).first, text)
            let attributed = try XCTUnwrap(selection.attributedString, text)
            let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, text)
            return font.pointSize
        }
        // 16 px → 12 pt, 32 px → 24 pt.
        XCTAssertEqual(try fontSize("Card 3 paragraph 1"), 10, accuracy: 0.5)
        XCTAssertEqual(try fontSize("Step 5.2"), 10, accuracy: 0.5)
        XCTAssertEqual(try fontSize("Cards fixture"), 20, accuracy: 1)

        var images = 0
        for index in 0..<pdf.pageCount {
            let page = try XCTUnwrap(pdf.page(at: index))
            let printable = page.bounds(for: .mediaBox).insetBy(dx: 36, dy: 36).insetBy(dx: -0.5, dy: -0.5)
            let lines = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? []
            XCTAssertFalse(lines.isEmpty, "page \(index + 1) has no text")
            let lowest = lines.min { $0.bounds(for: page).minY < $1.bounds(for: page).minY }
            XCTAssertFalse(lowest?.string?.hasPrefix("Section ") ?? false,
                           "page \(index + 1) ends with the heading \(lowest?.string ?? "")")
            for line in lines {
                let bounds = line.bounds(for: page)
                // Glyphs may overhang the side margins slightly; a page break must not cut through them.
                XCTAssertTrue(bounds.minY >= printable.minY && bounds.maxY <= printable.maxY,
                              "page \(index + 1): line \(line.string ?? "") at \(bounds) crosses \(printable)")
            }
            for image in Self.imageRects(on: try XCTUnwrap(page.pageRef)) {
                images += 1
                XCTAssertTrue(printable.contains(image), "page \(index + 1): image at \(image) crosses \(printable)")
            }
        }
        // Each of the 32 icons is drawn once, wholly on one page.
        XCTAssertEqual(images, 32)
    }

    /// Where each image XObject is drawn on `page`, in page space (form XObjects included).
    static func imageRects(on page: CGPDFPage) -> [CGRect] {
        final class Scan {
            var ctm = CGAffineTransform.identity
            var saved: [CGAffineTransform] = []
            var rects: [CGRect] = []
            let table = CGPDFOperatorTableCreate()!
        }
        let scan = Scan()
        let table = scan.table
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            scan.saved.append(scan.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            scan.ctm = scan.saved.popLast() ?? .identity
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            var values = [CGPDFReal](repeating: 0, count: 6)
            for i in (0..<6).reversed() { CGPDFScannerPopNumber(scanner, &values[i]) }
            let m = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            scan.ctm = m.concatenating(scan.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let scan = Unmanaged<Scan>.fromOpaque(info!).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name)
            else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Image":
                scan.rects.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(scan.ctm))
            case "Form":
                let outer = scan.ctm
                scan.saved.append(outer)
                var matrix: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { CGPDFArrayGetNumber(matrix, i, &v[i]) }
                    scan.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                        .concatenating(scan.ctm)
                }
                var resources: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                let content = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary,
                                                                 CGPDFScannerGetContentStream(scanner))
                let inner = CGPDFScannerCreate(content, scan.table, info)
                CGPDFScannerScan(inner)
                CGPDFScannerRelease(inner)
                CGPDFContentStreamRelease(content)
                scan.ctm = scan.saved.popLast() ?? outer
            default:
                break
            }
        }
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(scan).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        CGPDFOperatorTableRelease(table)
        return scan.rects
    }

    func testCapturedPageScriptsDoNotRunInTheRenderer() async throws {
        let html = """
        <p>Safe text.</p>
        <img src="pctest://main.test/img/a.png" onload="document.body.insertAdjacentText('beforeend', 'INJECTED')">
        """
        let content = CapturedContent(
            html: html, baseURL: URL(string: "pctest://main.test/docs/page.html")!, title: "Scripts",
            stylesheets: [], imageURLs: [])
        let url = folder.appendingPathComponent("Scripts.pdf")
        try await PDFExporter.write(content, localImages: [:], to: url,
                                    configuration: Self.configuration(), paperSize: .a4)

        let text = try XCTUnwrap(PDFDocument(url: url)?.string)
        XCTAssertTrue(text.contains("Safe text."))
        XCTAssertFalse(text.contains("INJECTED"))
    }

    func testBannerHeightIsKeptWhenItsHeadingIsAnchoredToTheBottom() async throws {
        let html = """
        <ul><li>First item</li><li>Last item of the list</li></ul>
        <div style="position: relative; min-height: 160px; background: #03c">
          <h2 style="position: absolute; bottom: 20px; margin: 0">Banner heading</h2>
        </div>
        """
        let content = CapturedContent(
            html: html, baseURL: URL(string: "pctest://main.test/docs/page.html")!, title: "Banner",
            stylesheets: [], imageURLs: [])
        let url = folder.appendingPathComponent("Banner.pdf")
        try await PDFExporter.write(content, localImages: [:], to: url,
                                    configuration: Self.configuration(), paperSize: .a4)

        let pdf = try XCTUnwrap(PDFDocument(url: url))
        func bounds(_ text: String) throws -> CGRect {
            let selection = try XCTUnwrap(pdf.findString(text, withOptions: []).first, text)
            return selection.bounds(for: try XCTUnwrap(selection.pages.first))
        }
        // PDF y grows upwards: the heading must sit wholly below the list.
        XCTAssertLessThan(try bounds("Banner heading").maxY, try bounds("Last item of the list").minY)
    }

    /// Every tab panel prints under its tab's title, also one the page's CSS hides; the tab bar does not.
    /// Pages stack their tab panels for fade effects: absolutely positioned in a fixed-height box, or all
    /// in one grid cell. Printed one after another, no panel may overlap another or what follows.
    func testStackedTabPanelsPrintWithoutOverlapping() async throws {
        func widget(_ id: String, _ style: String) -> String {
            """
            <h2>Widget \(id)</h2>
            <div class="\(style)">
              <div class="pane" role="tabpanel" data-pc-tab-title="\(id) RAM" data-pc-expanded="shown"><p>\(id) ram text.</p></div>
              <div class="pane" role="tabpanel" data-pc-tab-title="\(id) GPU"><p>\(id) gpu text.</p></div>
              <div class="pane" role="tabpanel" data-pc-tab-title="\(id) Storage"><p>\(id) storage text.</p></div>
            </div>
            <h2>After \(id)</h2>
            """
        }
        // Vertical tabs: the fixed height and the stacking sit on boxes above the panels' parent.
        let vertical = """
            <h2>Widget Vertical</h2>
            <div class="vtabs">
              <ul class="vbar" role="tablist" data-pc-tabs=""><li role="tab">Vertical RAM</li></ul>
              <div class="vcontent"><div class="vinner">
                <div class="vslot"><div class="pane" role="tabpanel" data-pc-tab-title="Vertical RAM" data-pc-expanded="shown"><p>Vertical ram text.</p></div></div>
                <div class="vslot"><div class="pane" role="tabpanel" data-pc-tab-title="Vertical GPU"><p>Vertical gpu text.</p></div></div>
                <div class="vslot"><div class="pane" role="tabpanel" data-pc-tab-title="Vertical Storage"><p>Vertical storage text.</p></div></div>
              </div></div>
            </div>
            <h2>After Vertical</h2>
            """
        // Each panel inside a wrapper of its own, in a flex row beside the tab bar.
        let wrapped = """
            <h2>Widget Wrapped</h2>
            <div class="wtabs">
              <ul role="tablist" data-pc-tabs=""><li role="tab">Wrapped RAM</li></ul>
              <div class="wslot"><div class="pane" role="tabpanel" data-pc-tab-title="Wrapped RAM" data-pc-expanded="shown"><p>Wrapped ram text.</p></div></div>
              <div class="wslot"><div class="pane" role="tabpanel" data-pc-tab-title="Wrapped GPU"><p>Wrapped gpu text.</p></div></div>
              <div class="wslot"><div class="pane" role="tabpanel" data-pc-tab-title="Wrapped Storage"><p>Wrapped storage text.</p></div></div>
            </div>
            <h2>After Wrapped</h2>
            """
        let content = CapturedContent(
            html: widget("Absolute", "absolute") + widget("Grid", "grid") + vertical + wrapped,
            baseURL: URL(string: "pctest://main.test/docs/page.html")!, title: "Stacked",
            stylesheets: [.inline("""
                .absolute { position: relative; height: 80px; overflow: hidden; }
                .absolute > .pane { position: absolute; top: 0; left: 0; right: 0; opacity: 0; }
                .grid { display: grid; } .grid > .pane { grid-area: 1 / 1; opacity: 0; }
                .pane[data-pc-expanded="shown"] { opacity: 1; }
                .vtabs { display: flex; height: 120px; overflow: hidden; }
                .vbar { width: 160px; } .vcontent { flex: 1; position: relative; height: 100%; }
                .vinner { position: absolute; inset: 0; overflow: hidden; }
                .vslot { position: absolute; top: 0; left: 0; right: 0; }
                .wtabs { display: flex; flex-direction: row; } .wtabs > ul { width: 160px; }
                """)],
            imageURLs: [])
        let url = folder.appendingPathComponent("Stacked.pdf")
        try await PDFExporter.write(content, localImages: [:], to: url,
                                    configuration: Self.configuration(), paperSize: .a4)

        let pdf = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(pdf.page(at: 0))
        func box(_ text: String) throws -> CGRect {
            try XCTUnwrap(pdf.findString(text, withOptions: []).first, text).bounds(for: page)
        }
        for id in ["Absolute", "Grid", "Vertical", "Wrapped"] {
            let order = ["Widget \(id)", "\(id) RAM", "\(id) ram text.", "\(id) GPU", "\(id) gpu text.",
                         "\(id) Storage", "\(id) storage text.", "After \(id)"]
            // PDF y grows upwards: each part sits wholly below the one before it.
            for (above, below) in zip(order, order.dropFirst()) {
                XCTAssertLessThanOrEqual(try box(below).maxY, try box(above).minY + 0.5, "\(below) overlaps \(above)")
            }
        }
    }

    func testEveryTabPanelPrintsUnderItsTitle() async throws {
        let html = """
        <h2>Choosing a model</h2>
        <ul class="nav nav-tabs" role="tablist" data-pc-tabs="">
          <li><a class="nav-link active" href="#p1" role="tab" aria-controls="p1">The Source - Model Hubs</a></li>
          <li><a class="nav-link" href="#p2" role="tab" aria-controls="p2">The Service - Cloud AI Platforms</a></li>
        </ul>
        <div class="tab-content">
          <div class="tab-pane active" id="p1" role="tabpanel" data-pc-tab-title="The Source - Model Hubs" data-pc-expanded="shown"><ul><li>Hub bullet one</li></ul></div>
          <div class="tab-pane" id="p2" role="tabpanel" data-pc-tab-title="The Service - Cloud AI Platforms"><p>Most businesses will not use models directly from a hub.</p></div>
        </div>
        """
        let content = CapturedContent(
            html: html, baseURL: URL(string: "pctest://main.test/docs/page.html")!, title: "Tabs",
            stylesheets: [.inline(".tab-content > .tab-pane { display: none; } .tab-content > .active { display: block; }"
                                  + " h3 { font-size: 11px; font-weight: normal; }")],
            imageURLs: [])
        let url = folder.appendingPathComponent("Tabs.pdf")
        try await PDFExporter.write(content, localImages: [:], to: url,
                                    configuration: Self.configuration(), paperSize: .a4)

        let pdf = try XCTUnwrap(PDFDocument(url: url))
        let text = try XCTUnwrap(pdf.string)
        var from = text.startIndex
        for part in ["The Source - Model Hubs", "Hub bullet one", "The Service - Cloud AI Platforms",
                     "Most businesses will not use models directly from a hub."] {
            let range = try XCTUnwrap(text.range(of: part, range: from..<text.endIndex), "\(part) missing or out of order: \(text)")
            from = range.upperBound
        }
        for title in ["The Source - Model Hubs", "The Service - Cloud AI Platforms"] {
            XCTAssertEqual(text.components(separatedBy: title).count - 1, 1, "\(title) once, without the tab bar: \(text)")
        }
        // A tab title the page styles small and plain prints bold, at least as large as its panel's text.
        func font(_ text: String) throws -> NSFont {
            let selection = try XCTUnwrap(pdf.findString(text, withOptions: []).first, text)
            return try XCTUnwrap(selection.attributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, text)
        }
        let title = try font("The Service - Cloud AI Platforms")
        XCTAssertGreaterThanOrEqual(title.pointSize, try font("Most businesses").pointSize - 0.1)
        XCTAssertTrue(title.fontDescriptor.symbolicTraits.contains(.bold), "\(title)")
    }

    func testVirtualisedListSpacersDoNotBecomeBlankPages() async throws {
        let url = folder.appendingPathComponent("Spacers.pdf")
        try await PDFExporter.write(Self.longContent(), localImages: [:], to: url,
                                    configuration: Self.configuration(), paperSize: .letter)
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        // 80 short paragraphs fit in a few pages; 20000px of padding alone would add about 25.
        XCTAssertLessThan(pdf.pageCount, 8)
        let size = try XCTUnwrap(pdf.page(at: 0)?.bounds(for: .mediaBox).size)
        XCTAssertEqual(size.width, 612, accuracy: 1)
    }

    func testVideoPreviewsLinkToTheSavedFileOrTheOriginal() async throws {
        // A capture folder with one saved video and its preview image.
        let video = folder.appendingPathComponent("videos/001-x clip.mp4")
        try FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not really a video".utf8).write(to: video)
        let poster = folder.appendingPathComponent("images/002-poster.png")
        try FileManager.default.createDirectory(at: poster.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FixtureURLProtocol.png.write(to: poster)
        let html = """
        <p>Before the videos.</p>
        <figure data-pc-video="0"><figcaption>Video: Saved clip</figcaption></figure>
        <figure data-pc-video="1"><img src="pctest://main.test/img/a.png" alt="Locked clip"><figcaption>Video: Locked clip</figcaption></figure>
        <p>After the videos.</p>
        """
        let content = CapturedContent(
            html: html, baseURL: URL(string: "pctest://main.test/docs/page.html")!, title: "Videos",
            stylesheets: [], imageURLs: ["pctest://main.test/img/a.png"])
        let original = URL(string: "https://www.youtube.com/watch?v=abc")!
        let url = folder.appendingPathComponent("Videos.pdf")
        try await PDFExporter.write(content, localImages: [:], to: url, configuration: Self.configuration(),
                                    paperSize: .a4, videos: [
            0: VideoLink(href: "videos/001-x clip.mp4", posterFile: "images/002-poster.png", title: "Saved clip",
                         outcome: .saved),
            1: VideoLink(href: original.absoluteString, posterFile: nil, title: "Locked clip", outcome: .protected),
        ])

        let pdf = try XCTUnwrap(PDFDocument(url: url))
        let text = try XCTUnwrap(pdf.string)
        XCTAssertTrue(text.contains("Video: Saved clip"), text)
        XCTAssertTrue(text.contains("Video: Locked clip"), text)
        XCTAssertTrue(text.contains("(protected video, linked to the original)"), text)
        let page = try XCTUnwrap(pdf.page(at: 0))
        let links = page.annotations.filter { $0.url != nil }
        XCTAssertFalse(links.contains { $0.url?.host == PDFExporter.videoMarkerHost }, "\(links.map(\.url))")

        /// The link whose box holds the caption, which must also cover the preview frame above it.
        func link(around caption: String) throws -> PDFAnnotation {
            let selection = try XCTUnwrap(pdf.findString(caption, withOptions: []).first, caption)
            let bounds = selection.bounds(for: page)
            let annotation = try XCTUnwrap(links.first { $0.bounds.contains(CGPoint(x: bounds.midX, y: bounds.midY)) },
                                           "no link around \(caption): \(links.map { ($0.bounds, $0.url) })")
            // The preview frame is at least 90 CSS px tall, above the caption (PDF y grows upwards).
            XCTAssertGreaterThan(annotation.bounds.maxY - bounds.maxY, 90 * 72 / 96 * PDFExporter.scale - 5, caption)
            return annotation
        }
        // A saved video opens the local file through an absolute file: URL.
        let local = try XCTUnwrap(try link(around: "Video: Saved clip").url)
        XCTAssertTrue(local.isFileURL, "\(local)")
        XCTAssertEqual(local.resolvingSymlinksInPath().path, video.resolvingSymlinksInPath().path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
        XCTAssertEqual(try link(around: "Video: Locked clip").url, original)
    }

    func testDataURLsForLocalImages() throws {
        let file = folder.appendingPathComponent("001-a.png")
        try FixtureURLProtocol.png.write(to: file)
        let urls = PDFExporter.dataURLs(for: ["https://x.test/a.png": file])
        XCTAssertEqual(urls["https://x.test/a.png"], "data:image/png;base64," + FixtureURLProtocol.png.base64EncodedString())
    }

    func testCleanStyleRemovesSpacersButKeepsOtherDeclarations() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(CaptureScripts.document)
        func clean(_ style: String, _ tag: String) -> String? {
            context.objectForKeyedSubscript("PageCaptureDocument")?
                .invokeMethod("cleanStyle", withArguments: [style, tag])?.toString()
        }
        XCTAssertEqual(clean("padding-top: 80px; height: 400px; color: red", "div"), "color: red")
        XCTAssertEqual(clean("min-height:9000px;padding-bottom:40px;margin:0", "ul"), "margin: 0")
        XCTAssertEqual(clean("position: absolute; top: 400px; left: 0; height: 40px; width: 100%", "div"), "width: 100%")
        XCTAssertEqual(clean("position:absolute;transform:translateY(80px);width:100%", "li"), "width: 100%")
        XCTAssertEqual(clean("position: absolute; right: 0", "span"), "position: absolute; right: 0")
        XCTAssertEqual(clean("height: 300px; width: 200px", "img"), "height: 300px; width: 200px")
    }
}
