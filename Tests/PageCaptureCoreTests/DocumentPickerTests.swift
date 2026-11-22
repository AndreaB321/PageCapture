import WebKit
import XCTest
@testable import PageCaptureCore

/// Drives the real picker on `Fixtures/embedded-documents.html`: frames, `<embed>`s and `<object>`s
/// that show documents (SPEC "Documents"). The documents themselves do not load (there is no
/// network): the picker works from the elements' URLs.
@MainActor
final class DocumentPickerTests: XCTestCase {
    private var bridge: PageCaptureBridge!
    private var webView: WKWebView!
    private var window: NSWindow!
    private var events: [CaptureEvent] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(FixtureSchemeHandler(), forURLScheme: FixtureSchemeHandler.scheme)
        // The documents' http(s) URLs are never fetched (no network in tests).
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "DocumentPickerTests.noNetwork",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#)
        configuration.userContentController.add(try XCTUnwrap(rules))
        bridge = PageCaptureBridge()
        bridge.install(in: configuration)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        bridge.webView = webView
        window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.acceptsMouseMovedEvents = true
        window.orderFrontRegardless()
        events = []
        bridge.onPick = { [unowned self] in events.append(.picked($0)) }
        bridge.onDocumentUnavailable = { [unowned self] in events.append(.documentUnavailable($0)) }
        try await load("embedded-documents.html")
    }

    private func load(_ fixture: String) async throws {
        webView.load(URLRequest(url: URL(string: "pctest://main.test/\(fixture)")!))
        try await waitUntil("\(fixture) loaded") {
            guard self.bridge.knownFrames.contains(where: \.isMainFrame) else { return false }
            return try await self.evaluate("document.readyState + location.pathname") == "complete/\(fixture)"
        }
    }

    override func tearDown() async throws {
        window?.close()
    }

    // MARK: Tests

    func testFrameShowingAPDFIsADocument() async throws {
        try await pick("#pdf")
        XCTAssertEqual(events, [.picked(.document(DocumentSource(url: URL(string: "https://documents.test/text.pdf")!, kind: .pdf)))])
    }

    func testEmbedIsADocumentByItsType() async throws {
        try await pick("#embed")
        XCTAssertEqual(events, [.picked(.document(DocumentSource(url: URL(string: "https://documents.test/report")!, kind: .pdf)))])
    }

    func testObjectIsADocumentByItsDataURL() async throws {
        try await pick("#object")
        XCTAssertEqual(events, [.picked(.document(DocumentSource(url: URL(string: "https://documents.test/document.docx")!, kind: .docx)))])
    }

    func testOfficeViewerIsTheDocumentItShows() async throws {
        try await pick("#viewer")
        XCTAssertEqual(events, [.picked(.document(DocumentSource(url: URL(string: "https://documents.test/slides.pptx")!, kind: .pptx)))])
    }

    func testViewerWithoutTheOriginalsURLIsCapturedAsAPage() async throws {
        try await pick("#viewer-without-src")
        XCTAssertEqual(events, [.documentUnavailable(.noURLInViewer)])
        // The frame shows nothing here (it is blocked), so what surrounds it is collected: the page.
        let content = try await bridge.collect(.picked, timing: Self.fast)
        XCTAssertTrue(content.html.contains("Documents page"), content.html)
    }

    func testLegacyWordFileIsReportedAsUnsupported() async throws {
        try await pick("#doc")
        XCTAssertEqual(events, [.documentUnavailable(.unsupportedType("doc"))])
    }

    /// Only documents are covered: an ordinary frame and an image `<embed>` keep their clicks.
    func testOrdinaryFramesAndImagesAreNotShielded() async throws {
        bridge.setPicking(true)
        defer { bridge.setPicking(false) }
        try await Task.sleep(for: .milliseconds(100))
        let vpage = try await evaluate(hit("#page") + ".id")
        XCTAssertEqual(vpage, "page")
        let vimage = try await evaluate(hit("#image") + ".id")
        XCTAssertEqual(vimage, "image")
        let vshield = try await evaluate(hit("#pdf") + ".getAttribute('data-pagecapture-ui')")
        XCTAssertEqual(vshield, "shield")
    }

    /// The shield of an `<object>` or `<embed>` whose URL and type are not a document's is not added:
    /// its HTML content is picked as a frame is.
    func testObjectShowingAnHTMLPageIsNotShielded() async throws {
        bridge.setPicking(true)
        defer { bridge.setPicking(false) }
        try await Task.sleep(for: .milliseconds(100))
        let v = try await evaluate(hit("#html-object") + ".id")
        XCTAssertEqual(v, "html-object")
    }

    /// A page that clicks the shield itself (from a MutationObserver, as soon as it appears) picks nothing.
    func testPageCannotPickForTheUser() async throws {
        try await load("self-picking-page.html")
        bridge.setPicking(true)
        defer { bridge.setPicking(false) }
        try await Task.sleep(for: .milliseconds(500))
        let seen = try await evaluate("String(window.shieldsSeen)")
        XCTAssertEqual(seen, "1", "the page saw the shield and clicked it")
        XCTAssertEqual(events, [])
        // The user's own click still picks.
        try await realClick(hit("#embed"))
        try await waitUntil("pick message") { !self.events.isEmpty }
        XCTAssertEqual(events, [.picked(.document(DocumentSource(url: URL(string: "https://documents.test/report.pdf")!, kind: .pdf)))])
    }

    /// Embeds the user cannot see are not targets: no shield, and a click picks what is under them.
    func testInvisibleEmbedsAreNotShielded() async throws {
        try await load("invisible-embeds.html")
        bridge.setPicking(true)
        defer { bridge.setPicking(false) }
        try await Task.sleep(for: .milliseconds(100))
        let shields = try await evaluate("String(document.querySelectorAll('[data-pagecapture-ui=shield]').length)")
        XCTAssertEqual(shields, "0")
        try await realClick("document.querySelector('h1')")
        try await waitUntil("pick message") { !self.events.isEmpty }
        // What is under the embeds (the page's <main>), not a document.
        XCTAssertEqual(events, [.picked(.picked)])
    }

    func testShieldsGoWhenPickingEnds() async throws {
        bridge.setPicking(true)
        try await Task.sleep(for: .milliseconds(100))
        bridge.setPicking(false)
        try await Task.sleep(for: .milliseconds(100))
        let v0 = try await evaluate("String(document.querySelectorAll('[data-pagecapture-ui]').length)")
        XCTAssertEqual(v0, "0")
        let vpdf = try await evaluate(hit("#pdf") + ".id")
        XCTAssertEqual(vpdf, "pdf")
    }

    // MARK: Helpers

    private static var fast: CollectionTiming {
        var timing = CollectionTiming()
        timing.settleDelay = 100
        timing.stallDelay = 200
        timing.imageTimeout = 300
        return timing
    }

    /// What the mouse would hit at the centre of `selector` in the main frame.
    private func hit(_ selector: String) -> String {
        """
        (() => {
          const r = document.querySelector('\(selector)').getBoundingClientRect();
          return document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        })()
        """
    }

    /// Turns the picker on and clicks the centre of `selector` in the main frame, as the mouse would.
    private func pick(_ selector: String) async throws {
        bridge.setPicking(true)
        try await Task.sleep(for: .milliseconds(100))
        try await realClick(hit(selector))
        try await waitUntil("pick message") { !self.events.isEmpty }
        bridge.setPicking(false)
    }

    /// A real (trusted) click at the centre of the element `expression` evaluates to, sent to the window.
    private func realClick(_ expression: String) async throws {
        let centre = try await evaluate("""
            (() => {
              const r = \(expression).getBoundingClientRect();
              return (r.left + r.width / 2) + ',' + (r.top + r.height / 2);
            })()
            """)
        let parts = try XCTUnwrap(centre).split(separator: ",").compactMap { Double($0) }
        let point = NSPoint(x: parts[0], y: webView.bounds.height - parts[1])
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func evaluate(_ script: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: .page) { result in
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

    // MARK: Whole page

    /// `…/blob/main/paper.pdf` served as `text/html` is a page, whatever its URL looks like.
    func testPageServedAsHTMLIsNotADocumentWhateverItsURL() async throws {
        let server = try await FixtureHTTPServer.start()
        defer { server.stop() }
        server.route("/blob/main/paper.pdf", Data("<html><body>Not a PDF</body></html>".utf8), contentType: "text/html")
        let page = PageCaptureBridge()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        page.webView = view
        let delegate = ResponseNoter(bridge: page)
        view.navigationDelegate = delegate
        let url = try XCTUnwrap(URL(string: server.url("/blob/main/paper.pdf")))
        view.load(URLRequest(url: url))
        try await waitUntil("page loaded") { !view.isLoading && view.url == url }
        XCTAssertEqual(page.pickWholePage(), .picked(.wholePage))
        withExtendedLifetime(delegate) {}
    }

    /// The same URL served as a PDF is still a document.
    func testPageServedAsPDFIsADocument() async throws {
        let server = try await FixtureHTTPServer.start()
        defer { server.stop() }
        server.route("/blob/main/paper.pdf", Data("%PDF-1.4\n%%EOF\n".utf8), contentType: "application/pdf")
        let page = PageCaptureBridge()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        page.webView = view
        let delegate = ResponseNoter(bridge: page)
        view.navigationDelegate = delegate
        let url = try XCTUnwrap(URL(string: server.url("/blob/main/paper.pdf")))
        view.load(URLRequest(url: url))
        try await waitUntil("page loaded") { !view.isLoading && view.url == url }
        XCTAssertEqual(page.pickWholePage(), .picked(.document(DocumentSource(url: url, kind: .pdf))))
        withExtendedLifetime(delegate) {}
    }
}

/// Gives the bridge the main frame's response, as the app's navigation delegate does.
@MainActor
private final class ResponseNoter: NSObject, WKNavigationDelegate {
    let bridge: PageCaptureBridge
    init(bridge: PageCaptureBridge) { self.bridge = bridge }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame { bridge.noteMainFrameResponse(navigationResponse.response) }
        return .allow
    }
}
