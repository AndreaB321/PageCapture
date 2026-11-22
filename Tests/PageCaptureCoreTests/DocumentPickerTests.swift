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
        window.orderFrontRegardless()
        events = []
        bridge.onPick = { [unowned self] in events.append(.picked($0)) }
        bridge.onDocumentUnavailable = { [unowned self] in events.append(.documentUnavailable($0)) }
        webView.load(URLRequest(url: URL(string: "pctest://main.test/embedded-documents.html")!))
        try await waitUntil("page loaded") {
            guard self.bridge.knownFrames.contains(where: \.isMainFrame) else { return false }
            return try await self.evaluate("document.readyState") == "complete"
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
        _ = try await evaluate("""
            (() => {
              const el = \(hit(selector));
              el.dispatchEvent(new MouseEvent('mousemove', { bubbles: true }));
              el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
              return 'ok';
            })()
            """)
        try await waitUntil("pick message") { !self.events.isEmpty }
        bridge.setPicking(false)
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
}
