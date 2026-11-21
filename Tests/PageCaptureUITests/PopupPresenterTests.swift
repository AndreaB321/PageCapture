import AppKit
import WebKit
import XCTest
@testable import PageCaptureUI

@MainActor
final class PopupPresenterTests: XCTestCase {
    // MARK: Decision

    private let page = URL(string: "https://example.com/next")

    func testNewWindowWithoutFeaturesLoadsInPlace() {
        XCTAssertEqual(NewWindowPolicy.decision(url: page, features: WindowFeatureValues(), fromPopup: false),
                       .loadInPlace)
        // Older WebKit reports the bars of a window opened without features as visible.
        let visible = WindowFeatureValues(menuBar: true, statusBar: true, toolbars: true, resizing: true)
        XCTAssertEqual(NewWindowPolicy.decision(url: page, features: visible, fromPopup: false), .loadInPlace)
    }

    func testWindowFeaturesOpenAPopup() {
        let sized = WindowFeatureValues(width: 400, height: 300)
        XCTAssertEqual(NewWindowPolicy.decision(url: page, features: sized, fromPopup: false), .openPopup)
        let positioned = WindowFeatureValues(x: 10, y: 10)
        XCTAssertEqual(NewWindowPolicy.decision(url: page, features: positioned, fromPopup: false), .openPopup)
        let noToolbar = WindowFeatureValues(toolbars: false)
        XCTAssertEqual(NewWindowPolicy.decision(url: page, features: noToolbar, fromPopup: false), .openPopup)
    }

    /// The opener fills in a blank window by script, so it needs a web view of its own.
    func testBlankWindowOpensAPopup() {
        for url in [nil, URL(string: "about:blank")] {
            XCTAssertEqual(NewWindowPolicy.decision(url: url, features: WindowFeatureValues(), fromPopup: false),
                           .openPopup)
        }
    }

    /// Loading in place from a pop-up would replace the sign-in page the opener is waiting on.
    func testEveryNewWindowFromAPopupOpensAnotherPopup() {
        XCTAssertEqual(NewWindowPolicy.decision(url: page, features: WindowFeatureValues(), fromPopup: true),
                       .openPopup)
    }

    func testPopupSizeComesFromTheFeaturesWithinLimits() {
        let screen = NSSize(width: 1440, height: 900)
        XCTAssertEqual(NewWindowPolicy.popupSize(features: WindowFeatureValues(width: 400, height: 300), fitting: screen),
                       NSSize(width: 400, height: 300))
        XCTAssertEqual(NewWindowPolicy.popupSize(features: WindowFeatureValues(), fitting: screen),
                       NewWindowPolicy.defaultPopupSize)
        XCTAssertEqual(NewWindowPolicy.popupSize(features: WindowFeatureValues(width: 400), fitting: screen),
                       NSSize(width: 400, height: NewWindowPolicy.defaultPopupSize.height))
        XCTAssertEqual(NewWindowPolicy.popupSize(features: WindowFeatureValues(width: 10, height: 5000), fitting: screen),
                       NSSize(width: NewWindowPolicy.minimumPopupSize.width, height: 900))
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

    func testWindowOpenWithoutFeaturesLoadsInTheMainWebView() async throws {
        let (controller, window) = try await makeController(page: Self.opener)
        defer { window.close() }

        _ = try await evaluate("window.open('b.html'); 'ok'", in: controller.webView)
        try await waitUntil("second page loaded in place") { controller.webView.title == "B" }
        XCTAssertTrue(controller.popupPresenter.popups.isEmpty)
        XCTAssertTrue(controller.webView.canGoBack)
        controller.webView.goBack()
        try await waitUntil("back on the first page") { controller.webView.title == "A" }
    }

    func testTargetBlankLinkLoadsInTheMainWebView() async throws {
        let (controller, window) = try await makeController(page: Self.opener)
        defer { window.close() }

        _ = try await evaluate("document.getElementById('blank').click(); 'ok'", in: controller.webView)
        try await waitUntil("second page loaded in place") { controller.webView.title == "B" }
        XCTAssertTrue(controller.popupPresenter.popups.isEmpty)
        XCTAssertTrue(controller.webView.canGoBack)
    }

    // MARK: Helpers

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
