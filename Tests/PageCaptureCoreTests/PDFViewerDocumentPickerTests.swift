import WebKit
import XCTest
@testable import PageCaptureCore

/// Drives the real picker on `Fixtures/pdfjs`: a course page → SCORM frame → PDF.js player frame,
/// served over HTTP so the player's fetch of its PDF shows in resource timing (SPEC "Documents").
@MainActor
final class PDFViewerDocumentPickerTests: XCTestCase {
    private var server: FixtureHTTPServer!
    private var bridge: PageCaptureBridge!
    private var webView: WKWebView!
    private var window: NSWindow!
    private var events: [CaptureEvent] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        server = try await FixtureHTTPServer.start()
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/pdfjs", withExtension: nil))
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL])
        for file in files where !file.hasDirectoryPath {
            let path = "/pdfjs" + file.path.dropFirst(root.path.count)
            let type = ["html": "text/html", "pdf": "application/pdf"][file.pathExtension] ?? "application/json"
            server.route(path, try Data(contentsOf: file), contentType: type)
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
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
    }

    override func tearDown() async throws {
        window?.close()
        server?.stop()
    }

    private func document(_ path: String) -> CaptureEvent {
        .picked(.document(DocumentSource(url: URL(string: server.url(path))!, kind: .pdf)))
    }

    // MARK: Tests

    func testClickInANestedPDFJSViewerPicksTheFetchedPDF() async throws {
        try await loadCourse(player: "viewer.html")
        try await clickCentre()
        XCTAssertEqual(events, [document("/pdfjs/play/content/document.pdf?v=1")])
    }

    func testReturnPicksTheViewerThatFillsTheView() async throws {
        try await loadCourse(player: "viewer.html")
        try await startPicking()
        XCTAssertEqual(bridge.pickWholePage(), document("/pdfjs/play/content/document.pdf?v=1"))
    }

    /// A viewer that covers less than half of the view is not what Return means: the page is picked.
    func testReturnPicksThePageWhenTheViewerIsSmall() async throws {
        try await loadCourse(player: "viewer.html")
        _ = try await evaluate("document.getElementById('scorm').style.height = '200px'")
        try await startPicking()
        XCTAssertEqual(bridge.pickWholePage(), .picked(.wholePage))
    }

    /// PDF.js without a PDF it fetched is an ordinary frame: picked as a frame, Return picks the page.
    func testViewerWithoutAFetchedPDFIsPickedAsBefore() async throws {
        try await loadCourse(player: "viewer-without-pdf.html")
        try await clickCentre()
        XCTAssertEqual(events, [.picked(.picked)])
        try await startPicking()
        XCTAssertEqual(bridge.pickWholePage(), .picked(.wholePage))
    }

    /// The standard viewer names its PDF in `PDFViewerApplication.url`, whatever else it fetched.
    func testStandardViewerUsesItsURL() async throws {
        try await loadCourse(player: "standard-viewer.html")
        try await clickCentre()
        XCTAssertEqual(events, [document("/pdfjs/play/content/book.pdf")])
    }

    // MARK: Helpers

    /// Loads the course page showing `player`, and waits until the player has fetched what it shows.
    private func loadCourse(player: String) async throws {
        webView.load(URLRequest(url: URL(string: server.url("/pdfjs/course.html?player=\(player)"))!))
        try await waitUntil("player loaded") {
            try await self.evaluate("""
                (() => {
                  const scorm = document.getElementById('scorm');
                  const inner = scorm && scorm.contentDocument && scorm.contentDocument.getElementById('player');
                  const doc = inner && inner.contentDocument;
                  return String(!!(doc && doc.body && doc.body.dataset.loaded === 'yes'));
                })()
                """) == "true"
        }
    }

    /// Turns the picker on and gives every frame a moment to set up (the PDF.js check included).
    private func startPicking() async throws {
        bridge.setPicking(true)
        try await Task.sleep(for: .milliseconds(300))
    }

    /// Picks with a real (trusted) click at the centre of the window, which the player frame fills.
    private func clickCentre() async throws {
        try await startPicking()
        let point = NSPoint(x: webView.bounds.midX, y: webView.bounds.midY)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(30))
        }
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
