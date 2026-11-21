import AppKit
import PageCaptureCore
import WebKit
import XCTest
@testable import PageCaptureUI

@MainActor
final class PopupPresenterTests: XCTestCase {
    // MARK: Decision

    /// A link the user clicks (`target="_blank"`) loads in the main window.
    func testUserActivatedLinkLoadsInPlace() {
        XCTAssertEqual(NewWindowPolicy.decision(navigationType: .linkActivated, fromPopup: false), .loadInPlace)
    }

    /// WebKit hides the `popup` feature, so any window a script opens may be a sign-in pop-up that
    /// needs `window.opener`.
    func testEveryWindowAScriptOpensIsAPopup() {
        for type: WKNavigationType in [.other, .formSubmitted, .formResubmitted, .backForward, .reload] {
            XCTAssertEqual(NewWindowPolicy.decision(navigationType: type, fromPopup: false), .openPopup, "\(type)")
        }
    }

    /// Loading in place from a pop-up would replace the sign-in page the opener is waiting on.
    func testEveryNewWindowFromAPopupOpensAnotherPopup() {
        for type: WKNavigationType in [.linkActivated, .other] {
            XCTAssertEqual(NewWindowPolicy.decision(navigationType: type, fromPopup: true), .openPopup)
        }
    }

    func testPopupSizeComesFromTheFeaturesWithinLimits() {
        let screen = NSSize(width: 1440, height: 900)
        XCTAssertEqual(NewWindowPolicy.popupSize(features: WindowFeatureValues(width: 400, height: 300), fitting: screen),
                       NSSize(width: 400, height: 300))
        XCTAssertEqual(NewWindowPolicy.popupSize(features: WindowFeatureValues(), fitting: screen),
                       NSSize(width: 900, height: 700))
        XCTAssertEqual(NewWindowPolicy.popupSize(features: WindowFeatureValues(), fitting: NSSize(width: 800, height: 600)),
                       NSSize(width: 800, height: 600))
        XCTAssertEqual(NewWindowPolicy.popupSize(features: WindowFeatureValues(width: 400), fitting: screen),
                       NSSize(width: 400, height: NewWindowPolicy.defaultPopupSize.height))
        XCTAssertEqual(NewWindowPolicy.popupSize(features: WindowFeatureValues(width: 10, height: 5000), fitting: screen),
                       NSSize(width: NewWindowPolicy.minimumPopupSize.width, height: 900))
    }

    // MARK: Title

    /// A page chooses its own title, so the host always leads and a page off https is marked.
    func testPopupTitleAlwaysShowsTheOrigin() {
        let title = PopupPresenter.Popup.title
        XCTAssertEqual(title(URL(string: "https://accounts.example.com/signin"), "Sign in"),
                       "accounts.example.com — Sign in")
        XCTAssertEqual(title(URL(string: "https://evil.example/"), "accounts.google.com"),
                       "evil.example — accounts.google.com")
        XCTAssertEqual(title(URL(string: "https://accounts.example.com/"), ""), "accounts.example.com")
        XCTAssertEqual(title(URL(string: "https://accounts.example.com/"), nil), "accounts.example.com")
        XCTAssertEqual(title(URL(string: "http://login.example.com/"), "Sign in"),
                       "Not Secure — login.example.com — Sign in")
        XCTAssertEqual(title(URL(string: "about:blank"), nil), "Not Secure — about")
        XCTAssertEqual(title(nil, nil), "Not Secure — about")
    }

    // MARK: Windows

    /// A controller whose web view sits in a window, with `html` loaded from a file in a temporary folder.
    private func makeController(page html: String) async throws -> (CaptureController, NSWindow) {
        _ = NSApplication.shared
        let controller = CaptureController(dataStore: .nonPersistent())
        // Tests cannot click, so let script open windows without a user gesture.
        controller.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.webView
        window.orderFrontRegardless()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PopupPresenterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let page = folder.appendingPathComponent("a.html")
        try html.write(to: page, atomically: true, encoding: .utf8)
        try "<title>B</title><p>Second page</p>"
            .write(to: folder.appendingPathComponent("b.html"), atomically: true, encoding: .utf8)
        controller.webView.loadFileURL(page, allowingReadAccessTo: folder)
        try await waitUntil("first page loaded") {
            controller.webView.title == "A" && !controller.webView.isLoading
        }
        return (controller, window)
    }

    private static let opener = """
        <title>A</title>
        <a id="blank" href="b.html" target="_blank">New window</a>
        <script>window.addEventListener('message', e => { window.received = e.data; });</script>
        """

    func testPopupOpensInItsOwnWindowSharesTheOpenerAndClosesItself() async throws {
        let (controller, window) = try await makeController(page: Self.opener)
        defer { window.close() }
        let presenter = controller.popupPresenter

        _ = try await evaluate("window.popup = window.open('', 'signin', 'width=400,height=300'); 'ok'",
                               in: controller.webView)
        try await waitUntil("pop-up opened") { presenter.popups.count == 1 }
        weak let popupWebView = presenter.popups.first?.webView
        weak let popupWindow = presenter.popups.first?.window
        // Scoped, so the test's own reference does not keep the pop-up alive.
        do {
            let popup = try XCTUnwrap(presenter.popups.first)
            XCTAssertTrue(popup.webView !== controller.webView)
            XCTAssertTrue(popup.webView.configuration.websiteDataStore
                === controller.webView.configuration.websiteDataStore)
            XCTAssertEqual(popup.window.contentRect(forFrameRect: popup.window.frame).size,
                           NSSize(width: 400, height: 300))
            XCTAssertTrue(popup.window.isVisible)
            XCTAssertEqual(controller.webView.title, "A", "the main page stayed")

            // What a sign-in pop-up does: report to its opener, then close itself.
            _ = try await evaluate("window.opener.postMessage('signed-in', '*'); window.close(); 'ok'",
                                   in: popup.webView)
        }
        try await waitUntil("opener received the message") {
            try await self.evaluate("String(window.received)", in: controller.webView) == "signed-in"
        }
        try await waitUntil("pop-up closed") { presenter.popups.isEmpty }
        try await waitUntil("pop-up released") { popupWebView == nil && popupWindow == nil }
    }

    func testClosingThePopupWindowReleasesIt() async throws {
        let (controller, window) = try await makeController(page: Self.opener)
        defer { window.close() }
        let presenter = controller.popupPresenter

        _ = try await evaluate("window.open('', 'signin', 'width=400,height=300'); 'ok'", in: controller.webView)
        try await waitUntil("pop-up opened") { presenter.popups.count == 1 }
        weak let popupWebView = presenter.popups.first?.webView
        presenter.popups.first?.window.performClose(nil)
        try await waitUntil("pop-up closed") { presenter.popups.isEmpty }
        try await waitUntil("pop-up released") { popupWebView == nil }
    }

    func testClosingTheMainWindowClosesPopups() async throws {
        let (controller, window) = try await makeController(page: Self.opener)
        let presenter = controller.popupPresenter

        _ = try await evaluate("window.open('', 'signin', 'width=400,height=300'); 'ok'", in: controller.webView)
        try await waitUntil("pop-up opened") { presenter.popups.count == 1 }
        weak let popupWindow = presenter.popups.first?.window
        window.close()
        try await waitUntil("pop-up closed") { presenter.popups.isEmpty }
        try await waitUntil("pop-up window released") { popupWindow == nil }
    }

    /// `window.open(url)` with no features may be an OAuth pop-up: it gets a window of its own, of the
    /// default size, linked to its opener, and the main page stays.
    func testScriptWindowOpenWithoutFeaturesOpensAPopup() async throws {
        let (controller, window) = try await makeController(page: Self.opener)
        defer { window.close() }
        let presenter = controller.popupPresenter

        _ = try await evaluate("window.open('b.html'); 'ok'", in: controller.webView)
        try await waitUntil("pop-up opened") { presenter.popups.count == 1 }
        let popup = try XCTUnwrap(presenter.popups.first)
        try await waitUntil("pop-up page loaded") { popup.webView.title == "B" }
        XCTAssertEqual(controller.webView.title, "A", "the main page stayed")
        XCTAssertFalse(controller.webView.canGoBack)
        let hasOpener = try await evaluate("String(window.opener !== null)", in: popup.webView)
        XCTAssertEqual(hasOpener, "true")
        let screen = try XCTUnwrap((window.screen ?? NSScreen.main)?.visibleFrame.size)
        XCTAssertEqual(popup.window.contentRect(forFrameRect: popup.window.frame).size,
                       NewWindowPolicy.popupSize(features: WindowFeatureValues(), fitting: screen))
    }

    /// The pop-up's window shows where its page comes from, and follows the page's title changes.
    func testPopupWindowTitleShowsTheOriginAndFollowsThePage() async throws {
        let (controller, window) = try await makeController(page: Self.opener)
        defer { window.close() }
        let presenter = controller.popupPresenter

        _ = try await evaluate("window.open('b.html'); 'ok'", in: controller.webView)
        try await waitUntil("pop-up opened") { presenter.popups.count == 1 }
        let popup = try XCTUnwrap(presenter.popups.first)
        try await waitUntil("title shows the page") { popup.window.title == "Not Secure — file — B" }
        _ = try await evaluate("document.title = 'accounts.google.com'; 'ok'", in: popup.webView)
        try await waitUntil("title follows the page") {
            popup.window.title == "Not Secure — file — accounts.google.com"
        }
    }

    /// A script `click()` on a link is reported as link-activated, like a real click, so this drives
    /// the in-place path end to end.
    func testTargetBlankLinkLoadsInTheMainWebView() async throws {
        let (controller, window) = try await makeController(page: Self.opener)
        defer { window.close() }

        _ = try await evaluate("document.getElementById('blank').click(); 'ok'", in: controller.webView)
        try await waitUntil("second page loaded in place") { controller.webView.title == "B" }
        XCTAssertTrue(controller.popupPresenter.popups.isEmpty)
        XCTAssertTrue(controller.webView.canGoBack)
    }

    // MARK: Keys

    /// Esc and Return act on the picker only when typed in the main window with no sheet on it.
    func testEscapeAndReturnOnlyPickInTheMainWindowWithoutASheet() async throws {
        let (controller, window) = try await makeController(page: Self.opener)
        defer { window.close() }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderFrontRegardless()
        defer { other.close() }

        XCTAssertTrue(controller.handleKey(1, characters: "s", flags: [.command, .shift],
                                           windowNumber: other.windowNumber), "⌘⇧S works from any window")
        XCTAssertEqual(controller.machine.phase, .picking)
        XCTAssertFalse(controller.handleKey(36, characters: "\r", flags: [], windowNumber: other.windowNumber))
        XCTAssertFalse(controller.handleKey(53, characters: nil, flags: [], windowNumber: other.windowNumber))
        XCTAssertFalse(controller.handleKey(36, characters: "\r", flags: [], windowNumber: 0))
        XCTAssertEqual(controller.machine.phase, .picking)

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet, completionHandler: nil)
        try await waitUntil("sheet attached") { window.attachedSheet === sheet }
        XCTAssertFalse(controller.handleKey(36, characters: "\r", flags: [], windowNumber: window.windowNumber))
        XCTAssertEqual(controller.machine.phase, .picking)
        window.endSheet(sheet)
        try await waitUntil("sheet gone") { window.attachedSheet == nil }

        XCTAssertTrue(controller.handleKey(53, characters: nil, flags: [], windowNumber: window.windowNumber))
        XCTAssertEqual(controller.machine.phase, .idle)
    }

    // MARK: JavaScript panels

    /// A panel would hold up a capture, so while one runs they complete at once with their defaults.
    func testPanelsCompleteAtOnceDuringACapture() async throws {
        let (controller, window) = try await makeController(page: Self.opener)
        defer { window.close() }
        controller.send(.shortcut)
        XCTAssertEqual(controller.machine.phase, .picking)

        let result = start("alert('a'); String(confirm('b')) + ',' + String(prompt('c', 'd'))", in: controller.webView)
        try await waitUntil("panels completed", timeout: 3) { result.done }
        XCTAssertEqual(result.value, "false,null")
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(controller.popupPresenter.openPanels.isEmpty)
    }

    /// From the second panel on, the user can turn off the page's panels; a new page shows them again.
    func testUserCanTurnOffRepeatedPanelsUntilTheNextPage() async throws {
        let (controller, window) = try await makeController(page: Self.opener)
        defer { window.close() }
        let presenter = controller.popupPresenter

        let first = start("alert('1'); 'ok'", in: controller.webView)
        try await waitUntil("first panel shown") { presenter.openPanels.count == 1 && window.attachedSheet != nil }
        let firstAlert = try XCTUnwrap(presenter.openPanels.first).alert
        XCTAssertFalse(firstAlert.showsSuppressionButton)
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        try await waitUntil("first panel answered") { first.done }

        let second = start("alert('2'); 'ok'", in: controller.webView)
        try await waitUntil("second panel shown") { presenter.openPanels.count == 1 && window.attachedSheet != nil }
        let alert = try XCTUnwrap(presenter.openPanels.first).alert
        XCTAssertTrue(alert.showsSuppressionButton)
        alert.suppressionButton?.state = .on
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        try await waitUntil("second panel answered") { second.done }

        let third = start("alert('3'); String(confirm('4'))", in: controller.webView)
        try await waitUntil("further panels completed", timeout: 3) { third.done }
        XCTAssertEqual(third.value, "false")
        XCTAssertNil(window.attachedSheet)

        _ = try await evaluate("location.href = 'b.html'; 'ok'", in: controller.webView)
        try await waitUntil("next page loaded") { controller.webView.title == "B" }
        let next = start("alert('5'); 'ok'", in: controller.webView)
        try await waitUntil("panel shown on the next page") { presenter.openPanels.count == 1 }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        try await waitUntil("panel answered") { next.done }
    }

    /// WebKit requires every panel's completion handler to be called, also when its pop-up closes first.
    func testClosingAPopupCompletesItsOpenPanel() async throws {
        let (controller, window) = try await makeController(page: Self.opener)
        defer { window.close() }
        let presenter = controller.popupPresenter

        _ = try await evaluate("window.open('', 'signin', 'width=400,height=300'); 'ok'", in: controller.webView)
        try await waitUntil("pop-up opened") { presenter.popups.count == 1 }
        let popup = try XCTUnwrap(presenter.popups.first)
        let result = start("String(confirm('Leave?'))", in: popup.webView)
        try await waitUntil("panel shown") { presenter.openPanels.count == 1 && popup.window.attachedSheet != nil }
        popup.window.close()
        try await waitUntil("panel completed", timeout: 3) { result.done }
        XCTAssertEqual(result.value, "false")
        XCTAssertTrue(presenter.openPanels.isEmpty)
        XCTAssertTrue(presenter.popups.isEmpty)
    }

    // MARK: Helpers

    @MainActor private final class Evaluation {
        var done = false
        var value: String?
    }

    /// Starts `script` without waiting for it, for scripts that wait on a panel.
    private func start(_ script: String, in webView: WKWebView) -> Evaluation {
        let evaluation = Evaluation()
        webView.evaluateJavaScript(script, in: nil, in: .page) { result in
            evaluation.value = try? result.get() as? String
            evaluation.done = true
        }
        return evaluation
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> String? {
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
