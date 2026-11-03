import PDFKit
import WebKit
import XCTest
@testable import PageCaptureCore

/// Runs the real export pipeline (downloads, Markdown, PDF) on a fixture capture into a temp folder.
@MainActor
final class CaptureExporterTests: XCTestCase {
    private var parent: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: parent)
    }

    func testExportsBothFormatsWithImagesIntoNamedFolder() async throws {
        var content = PDFExporterTests.longContent()
        content.html += #"<p><img src="pctest://main.test/img/missing.png" alt="gone"></p>"#
        content.imageURLs.append("pctest://main.test/img/missing.png")
        let folder = parent.appendingPathComponent("My Capture")

        let result = try await CaptureExporter.export(
            content, formats: [.pdf, .markdown], to: folder,
            webViewConfiguration: PDFExporterTests.configuration,
            sessionConfiguration: FixtureURLProtocol.configuration(), paperSize: .a4)

        let fm = FileManager.default
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path).sorted(), ["My Capture.md", "My Capture.pdf", "images"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.appendingPathComponent("images").path), ["001-a.png"])
        XCTAssertEqual(result.pdf, folder.appendingPathComponent("My Capture.pdf"))
        XCTAssertEqual(result.failedImages, ["pctest://main.test/img/missing.png"])
        XCTAssertTrue(result.summary.hasSuffix("(1 image could not be downloaded)"), result.summary)

        let markdown = try String(contentsOf: folder.appendingPathComponent("My Capture.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("![pixel](images/001-a.png)"), markdown)
        XCTAssertTrue(markdown.contains("![gone](pctest://main.test/img/missing.png)"), markdown)
        XCTAssertTrue(markdown.contains("[the target link](https://example.com/target)"), markdown)

        let pdf = try XCTUnwrap(PDFDocument(url: folder.appendingPathComponent("My Capture.pdf")))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("Paragraph 079") == true)
    }

    /// A page with an external stylesheet (an `@import`, a font, a background image), tab panels,
    /// a saved video and scripts the capture should not have kept.
    static func htmlContent() -> CapturedContent {
        let page = "pctest://main.test/docs/page.html"
        let html = """
        <h2 class="brand">Brand heading</h2><p class="imported">Imported rule</p><div class="hero">Hero</div>
        <p><img src="pctest://main.test/img/a.png" alt="pixel" onload="alert(1)"></p>
        <script>document.body.append('INJECTED')</script>
        <iframe src="https://example.com/embed" title="remote frame"></iframe>
        <p><a href="javascript:alert(1)" onclick="alert(2)">bad link</a> <a href="https://example.com/target">good link</a></p>
        <ul class="nav nav-tabs" role="tablist" data-pc-tabs="">
          <li><a class="nav-link active" href="#p1" role="tab">First tab</a></li>
          <li><a class="nav-link" href="#p2" role="tab">Second tab</a></li>
        </ul>
        <div class="tab-content">
          <div class="tab-pane active" id="p1" data-pc-tab-title="First tab" data-pc-expanded="shown"><p>First panel text</p></div>
          <div class="tab-pane" id="p2" data-pc-tab-title="Second tab"><p>Second panel text</p></div>
        </div>
        <figure data-pc-video="0"><img src="https://images.test/img/poster.png" alt="Clip"><figcaption>Video: Clip</figcaption></figure>
        """
        return CapturedContent(
            html: html, baseURL: URL(string: page)!, title: "Styled",
            stylesheets: [.link(URL(string: "pctest://main.test/styles/site.css")!),
                          .inline(".inline-rule { background: url(../img/inline.png) }")],
            imageURLs: ["pctest://main.test/img/a.png", "https://images.test/img/poster.png"],
            videos: [CapturedVideo(index: 0, kind: .file, url: "https://images.test/media/clip.mp4", pageURL: page,
                                   frameOrigin: page, posterURL: "https://images.test/img/poster.png", title: "Clip")])
    }

    func testHTMLIsOneSelfContainedFileThatLooksLikeThePage() async throws {
        FixtureURLProtocol.reset()
        let folder = parent.appendingPathComponent("Styled")
        let result = try await CaptureExporter.export(
            Self.htmlContent(), formats: [.html], to: folder,
            webViewConfiguration: PDFExporterTests.configuration,
            sessionConfiguration: FixtureURLProtocol.configuration())

        let fm = FileManager.default
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path).sorted(), ["Styled.html", "images", "videos"])
        XCTAssertEqual(result.html, folder.appendingPathComponent("Styled.html"))
        XCTAssertEqual(result.videos[0]?.href, "videos/001-Clip.mp4")
        let html = try String(contentsOf: folder.appendingPathComponent("Styled.html"), encoding: .utf8)
        XCTAssertTrue(html.hasPrefix("<!doctype html>"), String(html.prefix(40)))
        for banned in ["<script", "<link", "<base", "@page", "javascript:", "INJECTED", "@import"] {
            XCTAssertFalse(html.localizedCaseInsensitiveContains(banned), "\(banned) in the HTML")
        }
        XCTAssertNil(html.range(of: #"\son[a-z]+="#, options: .regularExpression), "event handler in the HTML")
        XCTAssertNotNil(html.range(of: #"<iframe[^>]*\ssandbox="""#, options: .regularExpression), "remote frame sandboxed")
        let sources = try NSRegularExpression(pattern: #"<img[^>]*\ssrc="([^"]*)""#)
            .matches(in: html, range: NSRange(html.startIndex..., in: html))
            .map { String(html[Range($0.range(at: 1), in: html)!]) }
        XCTAssertEqual(sources.count, 2)
        XCTAssertTrue(sources.allSatisfy { $0.hasPrefix("data:image/png;base64,") }, "\(sources.map { $0.prefix(30) })")
        XCTAssertTrue(html.contains(#"url("data:font/woff2;base64,\#(FixtureURLProtocol.font.base64EncodedString())")"#),
                      "font embedded")
        XCTAssertTrue(html.contains(#"url("data:image/png;base64,"#), "background embedded")
        XCTAssertTrue(html.contains(#"href="https://example.com/target""#), "links stay absolute")
        XCTAssertTrue(html.contains(#"<a class="pc-video" href="videos/001-Clip.mp4">"#), "video links to its file")
        for text in ["First tab", "First panel text", "Second tab", "Second panel text"] {
            XCTAssertTrue(html.contains(text), text)
        }
        let sheet = try XCTUnwrap(FixtureURLProtocol.requests.first { $0.url.lastPathComponent == "site.css" })
        XCTAssertEqual(sheet.referer, "pctest://main.test/docs/page.html")

        // Opened from disk, it looks like the page: the external rules apply and every tab panel shows.
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = LoadWaiter()
        view.navigationDelegate = delegate
        view.loadFileURL(folder.appendingPathComponent("Styled.html"), allowingReadAccessTo: folder)
        try await delegate.wait()
        func value(_ script: String) async throws -> String {
            let result = try await view.evaluateJavaScript(script)
            return try XCTUnwrap(result as? String, script)
        }
        let brand = try await value("getComputedStyle(document.querySelector('.brand')).color")
        let imported = try await value("getComputedStyle(document.querySelector('.imported')).color")
        let hero = try await value("getComputedStyle(document.querySelector('.hero')).backgroundImage")
        let secondPanel = try await value("String(document.querySelector('#p2').offsetHeight > 0)")
        let tabBar = try await value("getComputedStyle(document.querySelector('[data-pc-tabs]')).display")
        XCTAssertEqual(brand, "rgb(1, 2, 3)")
        XCTAssertEqual(imported, "rgb(4, 5, 6)")
        XCTAssertTrue(hero.hasPrefix(#"url("data:image/png;base64,"#), hero)
        XCTAssertEqual(secondPanel, "true")
        XCTAssertEqual(tabBar, "none")
    }

    /// A docs page captured whole: the site's header with its search, the docs tree, an "On this page"
    /// list, the article and a footer.
    static func docsPageContent() -> CapturedContent {
        let tree = (2012...2026).reversed().map { #"<li><a href="/archive/\#($0)">Archived Release Notes \#($0)</a></li>"# }
            .joined()
        let paragraphs = (1...8).map {
            "<p>Event detection paragraph \($0) explains how alerts are correlated across agents, tests and the network paths they share.</p>"
        }.joined()
        let html = """
        <header class="site-header"><a href="/">Example Product Documentation</a>
          <div role="search"><input placeholder="Search…"><kbd>Ctrl k</kbd></div></header>
        <div class="layout">
          <nav aria-label="Docs" class="sidebar"><ul><li><a href="/new">What's New</a></li><li><a href="/log">Changelog</a></li>
            <li><a href="/docs">Product Documentation</a></li><li><a href="/start">Getting Started</a></li>\(tree)</ul></nav>
          <main><article><h1 class="title">Event Detection</h1>\(paragraphs)</article></main>
          <aside class="toc"><nav><p>On this page</p><ul><li><a href="#how">How it works</a></li></ul></nav></aside>
        </div>
        <footer>Copyright Example Corp</footer>
        """
        return CapturedContent(
            html: html, baseURL: URL(string: "pctest://main.test/docs/event-detection")!, title: "Event Detection",
            stylesheets: [.inline("article .title { color: rgb(7, 8, 9) } .sidebar { width: 300px }")],
            imageURLs: [])
    }

    /// The HTML leaves the site's chrome out as the Markdown does: at full width the site's CSS shows it.
    func testHTMLLeavesOutTheSitesHeaderNavigationAndFooter() async throws {
        let folder = parent.appendingPathComponent("Docs")
        _ = try await CaptureExporter.export(
            Self.docsPageContent(), formats: [.html], to: folder,
            webViewConfiguration: PDFExporterTests.configuration,
            sessionConfiguration: FixtureURLProtocol.configuration())
        let html = try String(contentsOf: folder.appendingPathComponent("Docs.html"), encoding: .utf8)
        for kept in ["Event Detection", "Event detection paragraph 1 ", "Event detection paragraph 8 "] {
            XCTAssertTrue(html.contains(kept), kept)
        }
        for dropped in ["Example Product Documentation", "Search…", "Ctrl k", "What's New", "Changelog",
                        "Archived Release Notes", "On this page", "How it works", "Copyright"] {
            XCTAssertFalse(html.contains(dropped), "\(dropped) in the HTML")
        }

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let delegate = LoadWaiter()
        view.navigationDelegate = delegate
        view.loadFileURL(folder.appendingPathComponent("Docs.html"), allowingReadAccessTo: folder)
        try await delegate.wait()
        let color = try await view.evaluateJavaScript("getComputedStyle(document.querySelector('article .title')).color")
        XCTAssertEqual(color as? String, "rgb(7, 8, 9)")
    }

    /// A page whose content is all in its header keeps it.
    func testHTMLKeepsAHeaderHoldingMostOfTheText() async throws {
        let folder = parent.appendingPathComponent("Wrapped")
        let content = CapturedContent(
            html: "<header><h1>Release notes</h1><p>Everything this page says is inside its header element.</p></header>",
            baseURL: URL(string: "pctest://main.test/")!, title: "", stylesheets: [], imageURLs: [])
        _ = try await CaptureExporter.export(
            content, formats: [.html], to: folder, webViewConfiguration: PDFExporterTests.configuration,
            sessionConfiguration: FixtureURLProtocol.configuration())
        let html = try String(contentsOf: folder.appendingPathComponent("Wrapped.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("Everything this page says is inside its header element."), html)
    }

    func testAllThreeFormatsShareTheFolderName() async throws {
        var content = PDFExporterTests.longContent()
        content.html += #"<p><img src="pctest://main.test/img/missing.png" alt="gone"></p>"#
        content.imageURLs.append("pctest://main.test/img/missing.png")
        let folder = parent.appendingPathComponent("Everything")
        let result = try await CaptureExporter.export(
            content, formats: [.html, .pdf, .markdown], to: folder,
            webViewConfiguration: PDFExporterTests.configuration,
            sessionConfiguration: FixtureURLProtocol.configuration(), paperSize: .a4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
                       ["Everything.html", "Everything.md", "Everything.pdf", "images"])
        XCTAssertNotNil(result.html)
        XCTAssertNotNil(result.pdf)
        XCTAssertNotNil(result.markdown)
        let html = try String(contentsOf: folder.appendingPathComponent("Everything.html"), encoding: .utf8)
        XCTAssertTrue(html.contains(#"src="pctest://main.test/img/missing.png""#), "an image that failed keeps its URL")
    }

    func testImageURLWithPipeIsReferencedByItsOriginalString() async throws {
        // URL(string:) re-encodes `|` as `%7C`; the map key must stay the page's own string.
        let src = "pctest://main.test/img/a.png?fit=crop|center"
        let content = CapturedContent(html: #"<p><img src="\#(src)" alt="pipe"></p>"#,
                                      baseURL: URL(string: "pctest://main.test/page")!, title: "T",
                                      stylesheets: [], imageURLs: [src])
        let folder = parent.appendingPathComponent("Pipe")

        let result = try await CaptureExporter.export(
            content, formats: [.markdown], to: folder,
            webViewConfiguration: PDFExporterTests.configuration,
            sessionConfiguration: FixtureURLProtocol.configuration(), paperSize: .a4)

        XCTAssertEqual(result.failedImages, [])
        let markdown = try String(contentsOf: folder.appendingPathComponent("Pipe.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("![pipe](images/001-a.png)"), markdown)
    }

    func testAVIFSourceIsReferencedAsPNG() async throws {
        let src = "pctest://main.test/img/hero.avif"
        let content = CapturedContent(html: #"<p><img src="\#(src)" alt="hero"></p>"#,
                                      baseURL: URL(string: "pctest://main.test/page")!, title: "T",
                                      stylesheets: [], imageURLs: [src])
        let folder = parent.appendingPathComponent("Avif")

        _ = try await CaptureExporter.export(
            content, formats: [.markdown], to: folder,
            webViewConfiguration: PDFExporterTests.configuration,
            sessionConfiguration: FixtureURLProtocol.configuration(), paperSize: .a4)

        let markdown = try String(contentsOf: folder.appendingPathComponent("Avif.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("![hero](images/001-hero.png)"), markdown)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("images").path),
                       ["001-hero.png"])
    }

    func testMarkdownOnlyWritesNoPDF() async throws {
        let folder = parent.appendingPathComponent("Notes")
        let content = CapturedContent(html: "<p>Hi</p>", baseURL: URL(string: "pctest://main.test/")!, title: "",
                                      stylesheets: [], imageURLs: [])
        let result = try await CaptureExporter.export(
            content, formats: [.markdown], to: folder, webViewConfiguration: PDFExporterTests.configuration,
            sessionConfiguration: FixtureURLProtocol.configuration())
        XCTAssertNil(result.pdf)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Notes.md"])
        XCTAssertEqual(result.summary, "Saved to \(folder.path)")
    }

    func testCancelledExportStopsBeforeWritingTheOutputs() async throws {
        let folder = parent.appendingPathComponent("Quit")
        let content = CapturedContent(html: "<p>Hi</p>", baseURL: URL(string: "pctest://main.test/")!, title: "",
                                      stylesheets: [], imageURLs: [])
        let task = Task {
            try await CaptureExporter.export(
                content, formats: [.pdf, .markdown], to: folder, webViewConfiguration: PDFExporterTests.configuration,
                sessionConfiguration: FixtureURLProtocol.configuration())
        }
        task.cancel()
        do {
            let result = try await task.value
            XCTFail("expected CancellationError, got \(result)")
        } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testVideosAreDownloadedAndCounted() async throws {
        let folder = parent.appendingPathComponent("Clips")
        let page = "pctest://main.test/"
        let content = CapturedContent(
            html: #"<figure data-pc-video="0"></figure><figure data-pc-video="1"></figure>"#,
            baseURL: URL(string: page)!, title: "", stylesheets: [], imageURLs: [],
            videos: [
                CapturedVideo(index: 0, kind: .drm, url: "https://example.com/drm", pageURL: page, frameOrigin: page),
                CapturedVideo(index: 1, kind: .unknown, url: page, pageURL: page, frameOrigin: page),
            ])
        let result = try await CaptureExporter.export(
            content, formats: [.markdown], to: folder, webViewConfiguration: PDFExporterTests.configuration,
            sessionConfiguration: FixtureURLProtocol.configuration())
        XCTAssertEqual(result.videos[0]?.outcome, .protected)
        XCTAssertEqual(result.videos[1]?.outcome, .failed("No video source was found"))
        XCTAssertEqual(result.summary, "Saved to \(folder.path) (1 video protected (linked), 1 failed)")
    }

    func testSummaryCountsVideosAndImages() {
        let link = { (outcome: VideoLink.Outcome) in VideoLink(href: "", posterFile: nil, title: "", outcome: outcome) }
        let result = ExportResult(
            folder: URL(fileURLWithPath: "/tmp/C"), failedImages: ["a"],
            videos: [0: link(.saved), 1: link(.saved), 2: link(.saved), 3: link(.protected), 4: link(.failed("x"))])
        XCTAssertEqual(result.summary,
                       "Saved to /tmp/C (3 videos saved, 1 protected (linked), 1 failed; 1 image could not be downloaded)")
    }
}

/// Waits for a web view's navigation to finish.
@MainActor
final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func wait() async throws {
        if finished { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
