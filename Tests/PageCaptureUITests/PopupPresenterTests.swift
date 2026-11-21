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

    /// A presenter for a main web view showing `pctest://opener.test/A`, whose pages (and its pop-ups')
    /// come from `HostSchemeHandler`.
    private func makePresenter() async throws -> (PopupPresenter, WKWebView, NSWindow) {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(HostSchemeHandler(), forURLScheme: HostSchemeHandler.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let presenter = PopupPresenter(mainWebView: webView)
        webView.uiDelegate = presenter
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderFrontRegardless()
        webView.load(URLRequest(url: URL(string: "pctest://opener.test/A")!))
        try await waitUntil("opener loaded") { webView.title == "A" && !webView.isLoading }
        return (presenter, webView, window)
    }

    private func openPopup(_ script: String, from webView: WKWebView,
                           in presenter: PopupPresenter) async throws -> PopupPresenter.Popup {
        _ = try await evaluate(script + "; 'ok'", in: webView)
        try await waitUntil("pop-up opened") { presenter.popups.count == 1 }
        return try XCTUnwrap(presenter.popups.first)
    }

    /// `webView.url` names a navigation as soon as it starts, while the old page stays on screen and
    /// usable; a page could start one to a site that never answers and look like it.
    func testPopupOriginOnlyChangesWhenANavigationCommits() async throws {
        let (presenter, main, window) = try await makePresenter()
        defer { window.close() }
        let popup = try await openPopup("window.open('pctest://site.test/B')", from: main, in: presenter)
        try await waitUntil("pop-up shows its page") { popup.window.title == "Not Secure — site.test — B" }

        _ = try await evaluate("location.href = 'pctest://accounts.google.com:81/hang'; 'ok'", in: popup.webView)
        try await waitUntil("navigation pending") { popup.webView.url?.host() == "accounts.google.com" }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(popup.window.title, "Not Secure — site.test — B")

        _ = try await evaluate("location.href = 'pctest://accounts.google.com/fail'; 'ok'", in: popup.webView)
        try await waitUntil("navigation failed") { !popup.webView.isLoading }
        XCTAssertEqual(popup.window.title, "Not Secure — site.test — B")

        _ = try await evaluate("location.href = 'pctest://other.test:81/C'; 'ok'", in: popup.webView)
        try await waitUntil("committed page shown, with its port") {
            popup.window.title == "Not Secure — other.test:81 — C"
        }
    }

    /// The title bar cuts a long title at its end, so the host is shown in a field cut at its start:
    /// the registrable domain at the end of the host always shows.
    func testPopupShowsTheEndOfALongHostAndKeepsAMinimumWidth() async throws {
        let (presenter, main, window) = try await makePresenter()
        defer { window.close() }
        let host = "accounts.google.com.secure-login.evil.example"
        let popup = try await openPopup("window.open('pctest://\(host)/B', 'p', 'width=240,height=300')",
                                        from: main, in: presenter)
        try await waitUntil("pop-up shows its page") { popup.window.title == "Not Secure — \(host) — B" }

        func textFields(in view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields)
        }
        let fields = popup.window.titlebarAccessoryViewControllers.flatMap { textFields(in: $0.view) }
        let hostField = try XCTUnwrap(fields.first { $0.stringValue == host }, "a field shows the host")
        XCTAssertEqual(hostField.lineBreakMode, .byTruncatingHead)
        XCTAssertTrue(fields.contains { $0.stringValue == "Not Secure" && !$0.isHidden })
        XCTAssertEqual(popup.window.titleVisibility, .hidden, "the title bar would cut the host at its end")

        XCTAssertGreaterThanOrEqual(NewWindowPolicy.minimumPopupSize.width, 400)
        XCTAssertEqual(popup.window.contentRect(forFrameRect: popup.window.frame).width,
                       NewWindowPolicy.minimumPopupSize.width, "a page cannot ask for a narrower pop-up")
        XCTAssertEqual(popup.window.contentMinSize.width, NewWindowPolicy.minimumPopupSize.width,
                       "nor can the user make it narrower")
        popup.window.layoutIfNeeded()
        let bar = try XCTUnwrap(hostField.superview)
        XCTAssertGreaterThan(hostField.frame.width, 200, "the host keeps most of a narrow window")
        XCTAssertLessThanOrEqual(hostField.frame.maxX, bar.bounds.maxX, "and its end is inside the bar")
    }

    /// `window.open('')` gives an about:blank page of the opener's origin, which the opener can fill in.
    func testBlankPopupWrittenByItsOpenerShowsTheOpenersOrigin() async throws {
        let (presenter, main, window) = try await makePresenter()
        defer { window.close() }
        let popup = try await openPopup("""
            const w = window.open('');
            w.document.write('<title>accounts.google.com</title><p>Sign in</p>');
            w.document.close()
            """, from: main, in: presenter)
        try await waitUntil("pop-up shows the written page") {
            popup.window.title == "Not Secure — opener.test — accounts.google.com"
        }
    }

    /// Waits until `title` has been the pop-up's title for a while, so a later change would show.
    private func waitUntilSteady(_ popup: PopupPresenter.Popup, _ title: String) async throws {
        try await waitUntil("pop-up title is \(title)") { popup.window.title == title }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(popup.window.title, title)
    }

    /// WebKit moves the back-forward list to the entry being gone back to as soon as the navigation
    /// starts. A page that goes back to a page that does not answer, then replaces itself with a page of its own,
    /// must still show its own origin.
    func testGoingBackThenReplacingThePageShowsThePagesOwnOrigin() async throws {
        let (presenter, main, window) = try await makePresenter()
        defer { window.close() }
        let popup = try await openPopup("window.open('pctest://bank.test/onceA')", from: main, in: presenter)
        try await waitUntil("pop-up shows the bank") {
            popup.window.title == "Not Secure — bank.test — onceA"
        }
        _ = try await evaluate("location.href = 'pctest://evil.test/fake'; 'ok'", in: popup.webView)
        try await waitUntil("pop-up shows the fake page") { popup.window.title == "Not Secure — evil.test — fake" }

        _ = try await evaluate("history.back(); setTimeout(() => location.replace('/fake2'), 30); 'ok'",
                               in: popup.webView)
        try await waitUntilSteady(popup, "Not Secure — evil.test — fake2")
    }

    /// The same, reloading the page instead.
    func testGoingBackThenReloadingThePageShowsThePagesOwnOrigin() async throws {
        let (presenter, main, window) = try await makePresenter()
        defer { window.close() }
        let popup = try await openPopup("window.open('pctest://bank.test/onceA')", from: main, in: presenter)
        try await waitUntil("pop-up shows the bank") {
            popup.window.title == "Not Secure — bank.test — onceA"
        }
        _ = try await evaluate("location.href = 'pctest://evil.test/fake'; 'ok'", in: popup.webView)
        try await waitUntil("pop-up shows the fake page") { popup.window.title == "Not Secure — evil.test — fake" }

        _ = try await evaluate("history.back(); setTimeout(() => location.reload(), 30); document.title = 'again'; 'ok'",
                               in: popup.webView)
        try await waitUntil("reloaded") { popup.webView.title == "fake" && !popup.webView.isLoading }
        try await waitUntilSteady(popup, "Not Secure — evil.test — fake")
    }

    /// A named window opened blank by one site, then reused by another site that writes into it,
    /// shows the site that wrote it, never the one that opened it.
    func testReusedNamedBlankPopupShowsTheSiteThatWroteIt() async throws {
        let (presenter, main, window) = try await makePresenter()
        defer { window.close() }
        let popup = try await openPopup("window.open('', 'oauth')", from: main, in: presenter)
        main.load(URLRequest(url: URL(string: "pctest://evil.test/E")!))
        try await waitUntil("main window shows the other site") { main.title == "E" && !main.isLoading }

        _ = try await evaluate("window.w = window.open('about:blank', 'oauth'); 'ok'", in: main)
        XCTAssertEqual(presenter.popups.count, 1, "the named pop-up is reused")
        try await waitUntil("blank page written") {
            try await self.evaluate("""
                try { w.document.write('<title>Sign in</title><p>accounts.google.com'); w.document.close(); 'ok' }
                catch (e) { 'not yet' }
                """, in: main) == "ok"
        }
        try await waitUntilSteady(popup, "Not Secure — evil.test — Sign in")
    }

    /// A pop-up showing another site, that its opener sends to about:blank and writes into, shows the
    /// opener's origin: the blank page is the opener's.
    func testPopupSentToBlankByItsOpenerShowsTheOpenersOrigin() async throws {
        let (presenter, main, window) = try await makePresenter()
        defer { window.close() }
        let popup = try await openPopup("window.w = window.open('pctest://site.test/B')", from: main, in: presenter)
        try await waitUntil("pop-up shows its page") { popup.window.title == "Not Secure — site.test — B" }

        _ = try await evaluate("w.location = 'about:blank'; 'ok'", in: main)
        try await waitUntil("blank page written") {
            try await self.evaluate("""
                try { w.document.write('<title>Sign in</title>'); w.document.close(); 'ok' }
                catch (e) { 'not yet' }
                """, in: main) == "ok"
        }
        try await waitUntilSteady(popup, "Not Secure — opener.test — Sign in")
    }

    /// The origin is read where the page cannot redefine it: changing `window.origin` or `location`
    /// in the page's own world does not change what the bar shows.
    func testPageCannotChangeTheOriginShownByRedefiningIt() async throws {
        let (presenter, main, window) = try await makePresenter()
        defer { window.close() }
        let popup = try await openPopup("window.open('pctest://evil.test/B')", from: main, in: presenter)
        try await waitUntil("pop-up shows its page") { popup.window.title == "Not Secure — evil.test — B" }

        _ = try await evaluate("""
            Object.defineProperty(window, 'origin', { get: () => 'https://accounts.google.com' });
            try { Object.defineProperty(location, 'origin', { get: () => 'https://accounts.google.com' }) } catch {}
            try { Object.defineProperty(self, 'location', { get: () => ({ origin: 'https://accounts.google.com' }) }) }
            catch {}
            history.pushState(null, '', '/signin');
            document.title = 'Sign in'; 'ok'
            """, in: popup.webView)
        try await waitUntilSteady(popup, "Not Secure — evil.test — Sign in")
    }

    /// A blob: page shows the origin inside its URL.
    func testBlobPopupShowsTheOriginInsideIt() async throws {
        let (presenter, main, window) = try await makePresenter()
        defer { window.close() }
        let popup = try await openPopup("window.open('pctest://site.test/B')", from: main, in: presenter)
        try await waitUntil("pop-up shows its page") { popup.window.title == "Not Secure — site.test — B" }
        _ = try await evaluate("""
            location.href = URL.createObjectURL(new Blob(['<title>Blob</title>'], { type: 'text/html' })); 'ok'
            """, in: popup.webView)
        try await waitUntilSteady(popup, "Not Secure — site.test — Blob")
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

    /// A dialog already on screen when ⌘⇧S is pressed would block the page being picked.
    func testDialogOpenWhenPickingStartsCompletesWithItsDefault() async throws {
        let (controller, window) = try await makeController(page: Self.opener)
        defer { window.close() }
        let presenter = controller.popupPresenter

        let result = start("String(confirm('Stay?'))", in: controller.webView)
        try await waitUntil("dialog shown") { presenter.openPanels.count == 1 && window.attachedSheet != nil }
        XCTAssertTrue(controller.handleKey(1, characters: "s", flags: [.command, .shift],
                                           windowNumber: window.windowNumber))
        XCTAssertEqual(controller.machine.phase, .picking)
        try await waitUntil("dialog completed", timeout: 3) { result.done }
        XCTAssertEqual(result.value, "false")
        XCTAssertTrue(presenter.openPanels.isEmpty)
        try await waitUntil("sheet gone") { window.attachedSheet == nil }
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

/// Serves `pctest://<host>/<name>` as a page titled `<name>`, with `Cache-Control: no-store`. `/hang`
/// never answers, so its navigation stays pending; `/fail` fails; `/once…` answers only the first
/// time, so going back to it stays pending.
@MainActor
private final class HostSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pctest"
    private var served: Set<URL> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let name = url.lastPathComponent
        switch name {
        case "hang":
            return
        case "fail":
            task.didFailWithError(URLError(.cannotConnectToHost))
        case _ where name.hasPrefix("once") && !served.insert(url).inserted:
            return
        default:
            let body = Data("<title>\(name)</title><p>\(url.host() ?? "")</p>".utf8)
            let headers = ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"]
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                            headerFields: headers)!)
            task.didReceive(body)
            // A `/once…` page never finishes loading, so WebKit does not keep it to go back to.
            if !name.hasPrefix("once") { task.didFinish() }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
