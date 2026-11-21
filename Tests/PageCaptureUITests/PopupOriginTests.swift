import AppKit
import WebKit
import XCTest
@testable import PageCaptureUI

/// How a pop-up turns the origin its document gives into the text of its origin bar and title.
@MainActor
final class PopupOriginTests: XCTestCase {
    private typealias Popup = PopupPresenter.Popup

    private func origin(_ serialized: Any) -> Popup.OriginText {
        Popup.origin(evaluated: .success(serialized))
    }

    /// A page chooses its own title, so the host always leads and a page off https is marked.
    func testPopupTitleAlwaysShowsTheOrigin() {
        func title(_ serialized: String, _ pageTitle: String?) -> String {
            Popup.title(origin: origin(serialized), pageTitle: pageTitle)
        }
        XCTAssertEqual(title("https://accounts.example.com", "Sign in"), "accounts.example.com — Sign in")
        XCTAssertEqual(title("https://evil.example", "accounts.google.com"), "evil.example — accounts.google.com")
        XCTAssertEqual(title("https://accounts.example.com", ""), "accounts.example.com")
        XCTAssertEqual(title("https://accounts.example.com", nil), "accounts.example.com")
        XCTAssertEqual(title("http://login.example.com", "Sign in"), "Not Secure — login.example.com — Sign in")
        XCTAssertEqual(title("https://accounts.example.com:81", nil), "accounts.example.com:81")
        XCTAssertEqual(title("https://accounts.example.com:443", nil), "accounts.example.com")
        XCTAssertEqual(title("https://xn--ggle-0nda.com", nil), "xn--ggle-0nda.com", "IDN as punycode")
    }

    /// An opaque origin (sandboxed, data:) has no host to show, and an evaluation that failed (or
    /// answered something else) must never leave a host on screen.
    func testOriginWithoutAHostOrAnswerIsUnknown() {
        XCTAssertEqual(origin("null"), .unknown)
        XCTAssertEqual(origin(""), .unknown)
        XCTAssertEqual(origin(42), .unknown)
        XCTAssertEqual(origin(["https://evil.example"]), .unknown)
        XCTAssertEqual(Popup.origin(evaluated: .failure(URLError(.unknown))), .unknown)
        XCTAssertEqual(Popup.title(origin: .unknown, pageTitle: "Sign in"), "Not Secure — unknown origin — Sign in")
        XCTAssertEqual(origin("file://"), .init(text: "file", secure: false))
    }

    /// An answer asked for before the document on screen committed is about an older document, and an
    /// answer older than the one shown is out of date.
    func testStaleOriginAnswersAreIgnored() {
        var requests = Popup.OriginRequests()
        let beforeCommit = requests.next()
        let atCommit = requests.commit()
        XCTAssertFalse(requests.accept(beforeCommit), "a reply about the previous document")
        let later = requests.next()
        XCTAssertTrue(requests.accept(later))
        XCTAssertFalse(requests.accept(atCommit), "older than the reply shown")

        let next = requests.commit()
        XCTAssertFalse(requests.accept(later))
        XCTAssertTrue(requests.accept(next))
    }

    /// With the page's JavaScript off, the origin is still asked in the app's own world.
    func testPopupShowsTheOriginOfAPageWithoutJavaScript() async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let presenter = PopupPresenter(mainWebView: WKWebView())
        let popup = Popup(webView: webView, size: NSSize(width: 500, height: 400), presenter: presenter)
        defer { popup.window.close() }
        webView.loadHTMLString("<title>T</title><script>document.title = 'scripted'</script>",
                               baseURL: URL(string: "https://login.example:8443/"))
        let deadline = Date().addingTimeInterval(10)
        while popup.window.title != "login.example:8443 — T", Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(popup.window.title, "login.example:8443 — T")
    }
}
