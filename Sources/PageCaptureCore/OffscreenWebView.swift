import AppKit
import WebKit

/// A WKWebView in an off-screen borderless window, for the exporters: loads an HTML string and runs
/// page-world JavaScript. Close it when done.
@MainActor
final class OffscreenWebView: NSObject, WKNavigationDelegate {
    enum Failure: Error {
        case unexpectedResult(String)
    }

    let webView: WKWebView
    private let window: NSWindow
    private var navigation: CheckedContinuation<Void, Error>?

    init(configuration: WKWebViewConfiguration, size: CGSize = CGSize(width: 1024, height: 768)) {
        let frame = NSRect(origin: .zero, size: size)
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(contentRect: frame.offsetBy(dx: -30_000, dy: -30_000), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    /// Loads `html` with `baseURL` (the document's URL and origin) and waits for the load to finish.
    func load(html: String, baseURL: URL?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    /// Runs `body` as an async function in the page world, with `arguments` as its parameters.
    func call<T: Sendable>(_ body: String, arguments: [String: Any] = [:], as type: T.Type) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success(let value as T): continuation.resume(returning: value)
                case .success(let value): continuation.resume(throwing: Failure.unexpectedResult(String(describing: value)))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Evaluates a script source (e.g. one of `CaptureScripts`) in the page world.
    func run(_ source: String) async throws {
        _ = try await webView.evaluateJavaScript(source + "\n;undefined")
    }

    func close() {
        webView.navigationDelegate = nil
        webView.stopLoading()
        window.contentView = nil
        window.close()
    }

    private func finishNavigation(_ error: Error?) {
        guard let continuation = navigation else { return }
        navigation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(error)
    }
}
