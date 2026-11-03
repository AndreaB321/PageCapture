import PDFKit
import WebKit
import XCTest
@testable import PageCaptureCore

/// Drives the real picker and collector in a WKWebView loaded with the fixtures: a main page with a
/// virtualised scrollable list and a cross-origin iframe holding an infinite feed.
@MainActor
final class CaptureIntegrationTests: XCTestCase {
    @MainActor private struct Harness {
        let bridge: PageCaptureBridge
        let webView: WKWebView
        let window: NSWindow
        let picks: PickLog

        var iframe: WKFrameInfo? { bridge.knownFrames.first { !$0.isMainFrame } }
    }

    @MainActor private final class PickLog {
        var targets: [CaptureTarget] = []
    }

    private static var fast: CollectionTiming {
        var timing = CollectionTiming()
        timing.settleDelay = 150
        timing.stallDelay = 300
        timing.imageTimeout = 500
        return timing
    }

    /// Loads `index.html` (main page with the cross-origin iframe) or another fixture page.
    private func makeHarness(page: String = "index.html") async throws -> Harness {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(FixtureSchemeHandler(), forURLScheme: FixtureSchemeHandler.scheme)
        let bridge = PageCaptureBridge()
        bridge.install(in: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        bridge.webView = webView
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        let picks = PickLog()
        bridge.onPick = { picks.targets.append($0) }

        webView.load(URLRequest(url: URL(string: "pctest://main.test/\(page)")!))
        let harness = Harness(bridge: bridge, webView: webView, window: window, picks: picks)
        guard page == "index.html" else {
            try await waitUntil("page loaded") {
                // Evaluating before the document has started fails.
                guard harness.bridge.knownFrames.contains(where: \.isMainFrame) else { return false }
                return try await self.evaluate("document.readyState", in: harness, frame: nil) == "complete"
            }
            return harness
        }
        try await waitUntil("page and iframe loaded") {
            guard let frame = harness.iframe else { return false }
            let main = try await self.evaluate("document.readyState", in: harness, frame: nil)
            let child = try await self.evaluate("document.readyState", in: harness, frame: frame)
            return main == "complete" && child == "complete"
        }
        return harness
    }

    // MARK: Tests

    func testFixtureIframeIsCrossOrigin() async throws {
        let harness = try await makeHarness()
        defer { harness.window.close() }
        XCTAssertEqual(harness.iframe?.securityOrigin.host, "frame.test")
        let blocked = try await evaluate(
            "String(document.getElementById('frame').contentDocument === null)", in: harness, frame: nil)
        XCTAssertEqual(blocked, "true")
    }

    func testPicksAndCapturesCrossOriginIframeFeedInOrder() async throws {
        let harness = try await makeHarness()
        defer { harness.window.close() }
        let frame = try XCTUnwrap(harness.iframe)

        try await pick(in: harness, frame: frame, selector: "#feed")
        XCTAssertEqual(harness.picks.targets, [.picked])

        let content = try await harness.bridge.collect(.picked, timing: Self.fast)
        XCTAssertEqual(entries(in: content.html, prefix: "Entry"), (0..<100).map { "Entry " + pad($0) })
        XCTAssertEqual(content.title, "Fixture Frame")
        XCTAssertEqual(content.baseURL.absoluteString, "pctest://frame.test/docs/frame.html")
        XCTAssertTrue(content.html.contains(#"href="pctest://frame.test/other/page.html""#), content.html)
        XCTAssertTrue(content.html.contains(
            #"srcset="pctest://frame.test/docs/pics/a.png 1x, pctest://frame.test/docs/pics/b.png 2x""#))
        XCTAssertFalse(content.html.contains("<script"))
        XCTAssertTrue(content.html.contains(#"<a id="js">script link</a>"#), "inline handlers and javascript: URLs are dropped")
        XCTAssertFalse(content.html.contains("data-pagecapture-ui"))
        XCTAssertEqual(content.stylesheets.first, .link(URL(string: "pctest://frame.test/docs/frame.css")!))
        XCTAssertEqual(content.stylesheets.dropFirst().first, .inline("p { height: 30px; margin: 0; }"))
        XCTAssertEqual(content.imageURLs.count, 1)
        XCTAssertTrue(content.imageURLs.first?.hasPrefix("pctest://frame.test/docs/pics/") ?? false)
    }

    func testPicksAndCapturesVirtualisedScrollableListInOrder() async throws {
        let harness = try await makeHarness()
        defer { harness.window.close() }

        try await pick(in: harness, frame: nil, selector: "#inner p")
        XCTAssertEqual(harness.picks.targets, [.picked])

        let content = try await harness.bridge.collect(.picked, timing: Self.fast)
        XCTAssertEqual(entries(in: content.html, prefix: "Row"), (0..<60).map { "Row " + pad($0) })
        XCTAssertEqual(content.title, "Fixture Main")
        XCTAssertEqual(content.imageURLs, (0..<60).map { "pctest://main.test/img/row\($0).png" })
        let scrollTop = try await evaluate("String(document.getElementById('list').scrollTop)", in: harness, frame: nil)
        XCTAssertEqual(scrollTop, "0", "scroll position is restored")
    }

    func testClickOutsideAnyTargetPicksWholePage() async throws {
        let harness = try await makeHarness()
        defer { harness.window.close() }

        try await pick(in: harness, frame: nil, selector: "h1")
        XCTAssertEqual(harness.picks.targets, [.wholePage])

        let content = try await harness.bridge.collect(.wholePage, timing: Self.fast)
        XCTAssertTrue(content.html.contains("<h1>Main heading</h1>"), content.html)
        XCTAssertTrue(content.html.contains(#"<iframe id="frame" src="pctest://frame.test/docs/frame.html""#))
        XCTAssertEqual(content.stylesheets.first, .link(URL(string: "pctest://main.test/styles/main.css")!))
        XCTAssertEqual(content.ancestors.map(\.tag), ["html", "body"])
    }

    func testStopEndsCollectionKeepingWhatWasCollected() async throws {
        let harness = try await makeHarness()
        defer { harness.window.close() }
        let frame = try XCTUnwrap(harness.iframe)
        try await pick(in: harness, frame: frame, selector: "#feed")

        var slow = Self.fast
        slow.settleDelay = 400
        let bridge = harness.bridge
        let started = Date()
        _ = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(1000))
            bridge.stopCollection()
        }
        let content = try await bridge.collect(.picked, timing: slow)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let collected = entries(in: content.html, prefix: "Entry")
        XCTAssertGreaterThanOrEqual(collected.count, 20)
        XCTAssertLessThan(collected.count, 100)
        XCTAssertEqual(collected, (0..<collected.count).map { "Entry " + pad($0) })
    }

    // MARK: Collapsed content

    /// Headers and panel texts of `Fixtures/accordion.html`, in document order.
    private static let accordionOrder = [
        "Expressive and Creative Language Generation", "Alpha panel text.", "Alpha bullet one", "Alpha bullet two",
        "Summarisation Header", "Bravo panel text.",
        "Exclusive Header One", "Charlie direct text.", "Charlie panel text.",
        "Exclusive Header Two", "Delta panel text.", "Delta bullet",
        "Exclusive Header Three", "Kilo panel text.",
        "Sliding Header One", "Echo slide text.", "Sliding Header Two", "Foxtrot slide text.",
        "Details Summary One", "Golf details text.", "Details Summary Two", "Hotel details text.",
        "Details Summary Three", "India details text.",
        "Next section",
    ]

    private static let accordionPanelTexts = [
        "Alpha panel text.", "Alpha bullet one", "Alpha bullet two", "Bravo panel text.",
        "Charlie direct text.", "Charlie panel text.", "Delta panel text.", "Delta bullet", "Kilo panel text.",
        "Echo slide text.", "Foxtrot slide text.", "Golf details text.", "Hotel details text.", "India details text.",
    ]

    /// The capture made by `testExpandsCollapsedContentBeforeCapturing`, reused by the export tests.
    private static var accordionCapture: CapturedContent?

    private func captureAccordions() async throws -> CapturedContent {
        if let content = Self.accordionCapture { return content }
        let harness = try await makeHarness(page: "accordion.html")
        defer { harness.window.close() }
        let content = try await harness.bridge.collect(.wholePage, timing: Self.fast)

        let clicked = try await evaluate("JSON.stringify(window.clicked)", in: harness, frame: nil) ?? ""
        for id in ["navlink", "menu", "submit"] {
            XCTAssertFalse(clicked.contains(#""\#(id)""#), "\(id) was clicked: \(clicked)")
        }
        let path = try await evaluate("location.pathname", in: harness, frame: nil)
        XCTAssertEqual(path, "/accordion.html", "the page did not navigate")
        let marks = try await evaluate("String(document.querySelectorAll('[data-pc-expanded]').length)",
                                       in: harness, frame: nil)
        XCTAssertEqual(marks, "0", "the page is left without capture marks")
        Self.accordionCapture = content
        return content
    }

    func testExpandsCollapsedContentBeforeCapturing() async throws {
        Self.accordionCapture = nil
        let content = try await captureAccordions()
        assertInOrder(content.html, Self.accordionOrder)
        XCTAssertTrue(content.html.contains(#"<div id="pa1" class="panel open""#), content.html)
        // Closed, so hidden by the page and left out.
        XCTAssertFalse(content.html.contains(#"id="pd2""#), "the menu stays closed")
        XCTAssertFalse(content.html.contains(#"id="pd1""#), "the link's panel stays closed")
    }

    func testMarkdownOfExpandedCaptureHasHeadersAndPanelsInOrder() async throws {
        let content = try await captureAccordions()
        let markdown = try await MarkdownExporter.markdown(fromHTML: content.html, images: [:])
        assertInOrder(markdown, Self.accordionOrder)
        XCTAssertFalse(markdown.contains("Menu item"), markdown)
    }

    func testPDFOfExpandedCaptureHasEveryPanel() async throws {
        let content = try await captureAccordions()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Accordions-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try await PDFExporter.write(content, localImages: [:], to: url,
                                    configuration: PDFExporterTests.configuration(), paperSize: .a4)
        let text = try XCTUnwrap(PDFDocument(url: url)?.string)
        for panel in Self.accordionPanelTexts {
            XCTAssertTrue(text.contains(panel), "\(panel) missing from PDF: \(text)")
        }
        XCTAssertFalse(text.contains("Menu item"), text)
    }

    // MARK: Tabs

    /// Tab titles (as marked on their panels) and panel texts of `Fixtures/tabs.html`, in document order.
    private static let tabOrder = [
        #"data-pc-tab-title="The Source - Model Hubs""#, "Hub bullet one", "Hub bullet two",
        #"data-pc-tab-title="The Service - Cloud AI Platforms""#,
        "Most businesses will not use models directly from a hub.", "Platform bullet one",
        #"data-pc-tab-title="Button Tab One""#, "Button panel one text.",
        #"data-pc-tab-title="Button Tab Two""#, "Button panel two text.",
        #"data-pc-tab-title="Plain Tab One""#, "Plain panel one text.",
        #"data-pc-tab-title="Plain Tab Two""#, "Plain panel two text.",
        #"data-pc-tab-title="Labelled Tab One""#, "Labelled panel one text.",
        #"data-pc-tab-title="Labelled Tab Two""#, "Labelled panel two text.",
        "Next section",
    ]

    /// The capture made by `testShowsEveryTabPanelBeforeCapturing`, reused by the export test.
    private static var tabCapture: CapturedContent?

    private func captureTabs() async throws -> CapturedContent {
        if let content = Self.tabCapture { return content }
        let harness = try await makeHarness(page: "tabs.html")
        defer { harness.window.close() }
        let content = try await harness.bridge.collect(.wholePage, timing: Self.fast)

        let clicked = try await evaluate("JSON.stringify(window.clicked)", in: harness, frame: nil) ?? ""
        for id in ["navlink", "l3"] {
            XCTAssertFalse(clicked.contains(#""\#(id)""#), "\(id) was clicked: \(clicked)")
        }
        let path = try await evaluate("location.pathname", in: harness, frame: nil)
        XCTAssertEqual(path, "/tabs.html", "the page did not navigate")
        let selected = try await evaluate("""
            JSON.stringify([
              document.getElementById('t-src').getAttribute('aria-selected'),
              document.getElementById('p1').classList.contains('active'),
              document.getElementById('b2').getAttribute('aria-selected'),
              document.getElementById('bp2').hidden,
              document.querySelector('a[href="#q1"]').parentElement.classList.contains('active'),
              document.getElementById('l1').getAttribute('aria-selected'),
            ])
            """, in: harness, frame: nil)
        XCTAssertEqual(selected, #"["true",true,"true",false,true,"true"]"#, "the originally selected tabs are selected again")
        let marks = try await evaluate(
            "String(document.querySelectorAll('[data-pc-expanded], [data-pc-tab-title], [data-pc-tabs]').length)",
            in: harness, frame: nil)
        XCTAssertEqual(marks, "0", "the page is left without capture marks")
        Self.tabCapture = content
        return content
    }

    func testShowsEveryTabPanelBeforeCapturing() async throws {
        Self.tabCapture = nil
        let content = try await captureTabs()
        assertInOrder(content.html, Self.tabOrder)
        XCTAssertTrue(content.html.contains(#"<ul class="nav nav-tabs" role="tablist" data-pc-tabs="">"#), content.html)
    }

    func testExportsOfTabCaptureHaveEveryPanelUnderItsTitle() async throws {
        let content = try await captureTabs()
        let markdown = try await MarkdownExporter.markdown(fromHTML: content.html, images: [:])
        assertInOrder(markdown, [
            "## Model sources", "### The Source - Model Hubs", "- Hub bullet one",
            "### The Service - Cloud AI Platforms", "Most businesses will not use models directly from a hub.",
            "## Button tabs", "### Button Tab One", "Button panel one text.", "### Button Tab Two", "Button panel two text.",
            "## Plain tabs", "### Plain Tab One", "Plain panel one text.", "### Plain Tab Two", "Plain panel two text.",
            "## Labelled tabs", "### Labelled Tab One", "Labelled panel one text.",
            "### Labelled Tab Two", "Labelled panel two text.", "## Next section",
        ])
        XCTAssertFalse(markdown.contains("Elsewhere"), markdown)
        XCTAssertFalse(markdown.contains("Labelled Menu"), markdown)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Tabs-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try await PDFExporter.write(content, localImages: [:], to: url,
                                    configuration: PDFExporterTests.configuration(), paperSize: .a4)
        let text = try XCTUnwrap(PDFDocument(url: url)?.string)
        assertInOrder(text, [
            "The Source - Model Hubs", "Hub bullet one",
            "The Service - Cloud AI Platforms", "Most businesses will not use models directly from a hub.",
            "Button Tab One", "Button panel one text.", "Button Tab Two", "Button panel two text.",
            "Plain Tab One", "Plain panel one text.", "Plain Tab Two", "Plain panel two text.",
            "Labelled Tab One", "Labelled panel one text.", "Labelled Tab Two", "Labelled panel two text.",
        ])
        XCTAssertFalse(text.contains("Elsewhere"), text)
    }

    // MARK: Hidden content

    /// What the page hides with display:none (the dropdown behind "96 languages") is left out, while
    /// the tab panel and the accordion panel the collector showed stay even though the page hides them
    /// again, as do content seen before the page hid it, visually hidden text and a picture's source.
    func testLeavesOutContentThePageHidesButKeepsPanelsTheCollectorShowed() async throws {
        let harness = try await makeHarness(page: "hidden.html")
        defer { harness.window.close() }
        let content = try await harness.bridge.collect(.wholePage, timing: Self.fast)
        let state = try await evaluate("""
            JSON.stringify([
              getComputedStyle(document.getElementById('tp2')).display,
              getComputedStyle(document.getElementById('pc')).display,
              getComputedStyle(document.getElementById('teaser')).display,
            ])
            """, in: harness, frame: nil)
        XCTAssertEqual(state, #"["none","none","none"]"#, "the page hid the panels and the teaser again")

        let markdown = try await MarkdownExporter.markdown(fromHTML: content.html, images: [:])
        for (name, text) in [("HTML", content.html), ("Markdown", markdown)] {
            for language in ["Deutsch", "Français", "Español", "example.org"] {
                XCTAssertFalse(text.contains(language), "\(name) has the hidden dropdown's \(language): \(text)")
            }
            assertInOrder(text, [
                "A matrix is a rectangular array", "Teaser seen before it was hidden.",
                "First Tab Title", "First tab panel text.", "Second Tab Title", "Second tab panel text.",
                "Accordion panel text.", "Screen reader note", "Pixel picture", "End of article.",
            ])
        }
        XCTAssertTrue(content.html.contains(#"<label for="lang-toggle" id="lang-label">96 languages</label>"#), content.html)
        XCTAssertTrue(content.html.contains(#"<source srcset="pctest://main.test/images/pixel.webp""#), content.html)
        assertInOrder(markdown, ["### First Tab Title", "First tab panel text.", "### Second Tab Title", "Second tab panel text."])
    }

    // MARK: Visual headings

    /// A sub-heading styled by the page's CSS (a bold 20px div under a 24px h2) comes out as a heading
    /// one level below the h2; a paragraph that only starts in bold stays a paragraph; the ✓ table
    /// becomes a list. The page itself is left without marks.
    func testStyledSubheadingBecomesAHeadingInMarkdown() async throws {
        let harness = try await makeHarness(page: "headings.html")
        defer { harness.window.close() }
        let content = try await harness.bridge.collect(.wholePage, timing: Self.fast)
        let marks = try await evaluate("String(document.querySelectorAll('[data-pc-heading]').length)",
                                       in: harness, frame: nil)
        XCTAssertEqual(marks, "0", "the page is left without capture marks")

        let markdown = try await MarkdownExporter.markdown(fromHTML: content.html, images: [:])
        assertInOrder(markdown, [
            "## Vetting AI tools\n\n",
            "\n\n### Step 1: The 5-Minute Enterprise Vetting\n\n**Quick check:** look at their website first.\n\n",
            #"- ✓ **Find the "Enterprise," "Business," or "Trust" page.** The absence"#,
            "\n- ✓ **Look for SOC 2 Compliance.** This should be clearly and proudly stated.\n",
            "- ✓ **Check the data policy.**",
            "\n\nAfter the quick check, the formal evaluation follows.\n",
        ])
        XCTAssertFalse(markdown.contains("#### "), markdown)
        XCTAssertFalse(markdown.contains("# **Quick"), markdown)
    }

    // MARK: Main content

    /// On a docs page whose document scrolls (fixed header, sidebar, footer), the article is the
    /// target under the mouse; capturing it scrolls the page through the article and keeps only the
    /// article: every section in order, the lazy image's real source and the expanded accordion.
    func testPicksAndCapturesArticleThatScrollsWithThePage() async throws {
        let harness = try await makeHarness(page: "docs.html")
        defer { harness.window.close() }
        _ = try await evaluate("window.scrollTo(0, 150); 'ok'", in: harness, frame: nil)
        let lazySrc = try await evaluate("String(document.getElementById('lazy').hasAttribute('src'))",
                                         in: harness, frame: nil)
        XCTAssertEqual(lazySrc, "false", "the image has no source before it is scrolled into view")

        let highlight = try await highlighted(in: harness, hovering: "#s3 p")
        let article = try await rect(of: "#article", in: harness)
        XCTAssertEqual(highlight, article, "the article is highlighted")

        try await pick(in: harness, frame: nil, selector: "#s3 p")
        XCTAssertEqual(harness.picks.targets, [.picked])

        let content = try await harness.bridge.collect(.picked, timing: Self.fast)
        XCTAssertTrue(content.html.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(#"<section id="s1">"#),
                      "the capture is the article's content: \(content.html)")
        assertInOrder(content.html, [
            "Section One", "Section one text.", "Section Two", "Section two text.", "Accordion header",
            "Accordion panel text.", "Section Three", "Section three text.", "Section Four", "Section four text.",
            "Section Five", "Section five text.", #"src="pctest://main.test/pics/lazy-real.png""#,
            "Section Six", "Section six text.",
        ])
        for outside in ["Site header text", "Nav link", "Site footer text"] {
            XCTAssertFalse(content.html.contains(outside), "\(outside) is outside the article: \(content.html)")
        }
        let scrollY = try await evaluate("String(window.scrollY)", in: harness, frame: nil)
        XCTAssertEqual(scrollY, "150", "the page's scroll position is restored")
    }

    /// A scrolling area inside the article is the innermost target and is picked on its own; a click
    /// on the page outside the main content still picks the whole page.
    func testScrollingAreaInsideArticleAndPageMarginKeepTheirTargets() async throws {
        let harness = try await makeHarness(page: "docs.html")
        defer { harness.window.close() }

        let highlight = try await highlighted(in: harness, hovering: "#code p")
        let code = try await rect(of: "#code", in: harness)
        XCTAssertEqual(highlight, code, "the scrolling area is highlighted")
        try await pick(in: harness, frame: nil, selector: "#code p")
        XCTAssertEqual(harness.picks.targets, [.picked])
        let content = try await harness.bridge.collect(.picked, timing: Self.fast)
        XCTAssertEqual(content.html, (1...5).map { "<p>Code line \($0)</p>" }.joined(), "only the scrolling area")

        try await pick(in: harness, frame: nil, selector: "body")
        XCTAssertEqual(harness.picks.targets, [.picked, .wholePage])
    }

    /// A Wikipedia-style `<main>` (Vector 2022) that also holds the page's tool bars and, in a column
    /// beside the article, its appearance settings: the highlight and the capture cover the title and
    /// the article (text, figure, table, sections, a note aside in a section that is not the longest)
    /// and leave the tool bars and the column out.
    func testArticlePickLeavesOutTheToolBarsAndTheSettingsColumnBesideIt() async throws {
        let harness = try await makeHarness(page: "wiki.html")
        defer { harness.window.close() }

        let hovered = try await highlighted(in: harness, hovering: "#lead")
        let highlight = try XCTUnwrap(hovered, "something is highlighted")
        let column = try await rect(of: "#column", in: harness)
        let title = try await rect(of: "#firstHeading", in: harness)
        let body = try await rect(of: "#bodyContent", in: harness)
        let (h, c, t, b) = (numbers(highlight), numbers(column), numbers(title), numbers(body))
        XCTAssertGreaterThan(c[2], 0, "the settings column is laid out")
        XCTAssertLessThanOrEqual(h[0] + h[2], c[0], "the highlight ends before the settings column: \(highlight) vs \(c)")
        XCTAssertLessThanOrEqual(h[0], b[0], "the highlight covers the article's left edge")
        XCTAssertLessThanOrEqual(h[1], t[1], "the highlight covers the title")
        XCTAssertGreaterThanOrEqual(h[1] + h[3], b[1] + b[3], "the highlight covers the article's end")

        try await pick(in: harness, frame: nil, selector: "#lead")
        XCTAssertEqual(harness.picks.targets, [.picked])
        let content = try await harness.bridge.collect(.picked, timing: Self.fast)
        assertInOrder(content.html, [
            "Matrix (mathematics)", "In mathematics, a matrix is a rectangular array", "<figure", "An m-by-n matrix.",
            "<table", "Row one, column two", "Definition", "arranged in rows and columns of entries",
            "A note in the text.", "Notation",
            "square brackets", "Basic operations", "entrywise",
        ])
        for furniture in ["Appearance", "Small", "Standard", "Read", "View history", "Talk"] {
            XCTAssertFalse(content.html.contains(furniture), "\(furniture) is page furniture: \(content.html)")
        }
    }

    // MARK: Ancestor shells

    /// A docs article whose column is centred and spaced by rules on `<html>` and on its parent: the
    /// HTML file wraps the content in the article and its ancestors, so at full width a paragraph and
    /// a self-centred figure share one centred column, spaced as on the page, without the sidebar.
    func testHTMLOfArticleKeepsTheColumnLayoutItsAncestorsGiveIt() async throws {
        let harness = try await makeHarness(page: "column.html")
        defer { harness.window.close() }
        try await pick(in: harness, frame: nil, selector: "#p2")
        XCTAssertEqual(harness.picks.targets, [.picked])
        let content = try await harness.bridge.collect(.picked, timing: Self.fast)

        XCTAssertEqual(content.ancestors, [
            ElementShell(tag: "html", attributes: ["class": "theme-x", "lang": "en"]),
            ElementShell(tag: "body", attributes: ["class": "page"]),
            ElementShell(tag: "div", attributes: ["class": "layout", "data-keep": "yes"]),
            ElementShell(tag: "article", attributes: ["id": "col", "class": "col"]),
        ], "handlers, javascript: URLs and src are left out")

        let (folder, html) = try await exportHTML(content, name: "Column")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        XCTAssertFalse(html.contains("Sidebar link"))
        let layout = try await measure(folder.appendingPathComponent("Column.html"), """
            const rect = (id) => document.getElementById(id).getBoundingClientRect();
            const p1 = rect('p1'); // as wide as the column
            return JSON.stringify({
              p1: p1.left, fig: rect('fig').left,
              leftMargin: p1.left, rightMargin: document.documentElement.clientWidth - p1.right,
              width: p1.width, p2Top: getComputedStyle(document.getElementById('p2')).marginTop,
              text: document.body.innerText,
            });
            """)
        let p1 = try XCTUnwrap(layout["p1"] as? Double), fig = try XCTUnwrap(layout["fig"] as? Double)
        XCTAssertEqual(p1, fig, accuracy: 1, "the paragraph and the figure share the column's left edge")
        let left = try XCTUnwrap(layout["leftMargin"] as? Double)
        let right = try XCTUnwrap(layout["rightMargin"] as? Double)
        XCTAssertEqual(left, right, accuracy: 2, "the column is centred")
        XCTAssertEqual(layout["width"] as? Double, 600)
        XCTAssertEqual(layout["p2Top"] as? String, "20px", "the column's `* + *` spacing applies")
        XCTAssertFalse((layout["text"] as? String ?? "").contains("Sidebar"), "no sidebar")
    }

    /// A scrolling area inside viewport-high boxes that clip: in the HTML file none of those boxes
    /// clips it, and its last line is inside the document and visible.
    func testHTMLOfScrollingAreaInClippingAppShellShowsAllOfIt() async throws {
        let harness = try await makeHarness(page: "app-scroll.html")
        defer { harness.window.close() }
        try await pick(in: harness, frame: nil, selector: "#line3")
        XCTAssertEqual(harness.picks.targets, [.picked])
        let content = try await harness.bridge.collect(.picked, timing: Self.fast)
        XCTAssertEqual(content.ancestors.map(\.tag), ["html", "body", "div", "div", "div"])
        XCTAssertTrue(content.html.contains("Line 50"))

        let (folder, _) = try await exportHTML(content, name: "App")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let layout = try await measure(folder.appendingPathComponent("App.html"), """
            const last = document.getElementById('line50');
            const r = last.getBoundingClientRect();
            const clippedBy = [];
            for (let a = last.parentElement; a; a = a.parentElement) {
              const s = getComputedStyle(a);
              const b = a.getBoundingClientRect();
              if ((s.overflowY !== 'visible' || s.overflowX !== 'visible') &&
                  (r.bottom > b.bottom + 1 || r.top < b.top - 1)) {
                clippedBy.push(a.id || a.className || a.localName);
              }
            }
            return JSON.stringify({ bottom: r.bottom + scrollY, scrollHeight: document.scrollingElement.scrollHeight,
              height: r.height, clippedBy });
            """)
        let bottom = try XCTUnwrap(layout["bottom"] as? Double)
        let scrollHeight = try XCTUnwrap(layout["scrollHeight"] as? Double)
        XCTAssertLessThanOrEqual(bottom, scrollHeight + 1, "the last line is within the document")
        XCTAssertEqual(layout["height"] as? Double, 40)
        XCTAssertEqual(layout["clippedBy"] as? [String], [], "no box clips the last line")
    }

    /// Exports `content` as HTML only into a new temporary folder; returns the capture folder and the file's text.
    private func exportHTML(_ content: CapturedContent, name: String) async throws -> (URL, String) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureIntegrationTests-\(UUID().uuidString)")
            .appendingPathComponent(name)
        _ = try await CaptureExporter.export(
            content, formats: [.html], to: folder, webViewConfiguration: PDFExporterTests.configuration,
            sessionConfiguration: FixtureURLProtocol.configuration())
        let html = try String(contentsOf: folder.appendingPathComponent("\(name).html"), encoding: .utf8)
        return (folder, html)
    }

    /// Opens `file` in a 1200×800 web view and returns the JSON object that `body` (a function body) returns.
    private func measure(_ file: URL, _ body: String) async throws -> [String: Any] {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let delegate = LoadWaiter()
        view.navigationDelegate = delegate
        view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        try await delegate.wait()
        let json = try await view.evaluateJavaScript("(() => {\n\(body)\n})()")
        let data = Data(try XCTUnwrap(json as? String).utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Helpers

    /// Turns the picker on, moves the mouse over `selector` in the main frame and returns the
    /// highlight's rectangle (see `rect(of:in:)`), or nil when nothing is highlighted.
    private func highlighted(in harness: Harness, hovering selector: String) async throws -> String? {
        harness.bridge.setPicking(true)
        defer { harness.bridge.setPicking(false) }
        try await Task.sleep(for: .milliseconds(100))
        _ = try await evaluate("""
            document.querySelector('\(selector)').dispatchEvent(new MouseEvent('mousemove', { bubbles: true })); 'ok'
            """, in: harness, frame: nil)
        return try await evaluate("""
            (() => {
              const o = document.querySelector('[data-pagecapture-ui]');
              if (!o || o.style.display === 'none') return null;
              const r = o.getBoundingClientRect();
              return [r.left, r.top, r.width, r.height].map(Math.round).join(',');
            })()
            """, in: harness, frame: nil)
    }

    /// "left,top,width,height" of `selector` in the main frame's viewport, rounded.
    private func rect(of selector: String, in harness: Harness) async throws -> String? {
        try await evaluate("""
            (() => {
              const r = document.querySelector('\(selector)').getBoundingClientRect();
              return [r.left, r.top, r.width, r.height].map(Math.round).join(',');
            })()
            """, in: harness, frame: nil)
    }

    /// The numbers of a "left,top,width,height" rectangle (see `rect(of:in:)`).
    private func numbers(_ rect: String?) -> [Double] {
        let values = (rect ?? "").split(separator: ",").compactMap { Double($0) }
        return values.count == 4 ? values : [0, 0, 0, 0]
    }

    /// Fails unless each of `parts` occurs in `text` after the previous one.
    private func assertInOrder(_ text: String, _ parts: [String], file: StaticString = #filePath, line: UInt = #line) {
        var from = text.startIndex
        for part in parts {
            guard let range = text.range(of: part, range: from..<text.endIndex) else {
                XCTFail("\(part) missing or out of order in:\n\(text)", file: file, line: line)
                return
            }
            from = range.upperBound
        }
    }

    /// Turns the picker on everywhere, then clicks `selector` in `frame` (nil = main frame).
    private func pick(in harness: Harness, frame: WKFrameInfo?, selector: String) async throws {
        harness.bridge.setPicking(true)
        let before = harness.picks.targets.count
        // Give the setPicking evaluations a moment to land in every frame.
        try await Task.sleep(for: .milliseconds(100))
        _ = try await evaluate("""
            (() => {
              const el = document.querySelector('\(selector)');
              el.dispatchEvent(new MouseEvent('mousemove', { bubbles: true }));
              el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
              return 'ok';
            })()
            """, in: harness, frame: frame)
        try await waitUntil("pick message") { harness.picks.targets.count > before }
        harness.bridge.setPicking(false)
    }

    private func evaluate(_ script: String, in harness: Harness, frame: WKFrameInfo?) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            harness.webView.evaluateJavaScript(script, in: frame, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10,
                           _ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for \(what)")
        throw CancellationError()
    }

    private func pad(_ n: Int) -> String {
        String(repeating: "0", count: max(0, 3 - String(n).count)) + String(n)
    }

    /// The "<prefix> NNN" labels in `html`, in order.
    private func entries(in html: String, prefix: String) -> [String] {
        html.matches(of: try! Regex("\(prefix) \\d{3}")).map { String(html[$0.range]) }
    }
}
